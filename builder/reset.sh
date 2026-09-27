#!/usr/bin/env bash
# reset.sh - snapshot / revert helpers and a clean teardown of the whole lab.
#
#   ./reset.sh snapshot [vm ...]     take a 'clean-baseline' snapshot (all lab VMs if none named)
#   ./reset.sh snapshot vm NAME      take a named snapshot of one VM
#   ./reset.sh revert   vm [NAME]    revert a VM to a snapshot (default clean-baseline)
#   ./reset.sh list     [vm]         list snapshots
#   ./reset.sh teardown              remove ALL lab VMs, containers, network and pool
#   ./reset.sh teardown --yes        teardown without prompts (also offers to wipe disks)
#
# Linux VMs use internal snapshots (fast, revert cleanly). Windows/UEFI VMs use
# EXTERNAL disk snapshots, because the UEFI pflash blocks internal ones; those
# must be shut off before you revert.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

need_cmd virsh
usage() { awk 'NR==1{next} /^#/{s=$0; sub(/^# ?/,"",s); print s; next} {exit}' "$0"; exit "${1:-0}"; }

is_uefi() { grep -qE "firmware='efi'|pflash" <<<"$(virsh dumpxml "$1" 2>/dev/null)"; }

# lab_vms: every defined domain whose XML references the lab network. Picks up
# any future VM on the lab net (e.g. 'node') without editing this list.
lab_vms() {
  local vm
  while read -r vm; do
    [ -n "$vm" ] || continue
    if grep -q "network='$LAB_NET_NAME'\|<source network='$LAB_NET_NAME'" <<<"$(virsh dumpxml "$vm" 2>/dev/null)"; then
      echo "$vm"
    fi
  done < <(virsh list --all --name)
}

ensure_off() {
  if vm_running "$1"; then
    log "shutting down $1"
    virsh shutdown "$1" >/dev/null 2>&1 || true
    local i=0; while vm_running "$1" && [ "$i" -lt 30 ]; do sleep 2; i=$((i+1)); done
    vm_running "$1" && { warn "$1 did not shut down gracefully; forcing off"; virsh destroy "$1" >/dev/null 2>&1 || true; }
  fi
}

do_snapshot() {
  local vm="$1" name="${2:-clean-baseline}"
  vm_exists "$vm" || die "no such VM: $vm"
  ensure_off "$vm"
  if is_uefi "$vm"; then
    log "external disk snapshot '$name' of $vm (UEFI)"
    run virsh snapshot-create-as "$vm" "$name" "sovereign-homelab baseline" --disk-only --atomic
  else
    log "internal snapshot '$name' of $vm"
    run virsh snapshot-create-as "$vm" "$name" "sovereign-homelab baseline"
  fi
  ok "snapshot '$name' created for $vm"
}

do_revert() {
  local vm="$1" name="${2:-clean-baseline}"
  vm_exists "$vm" || die "no such VM: $vm"
  is_uefi "$vm" && ensure_off "$vm"
  log "reverting $vm to '$name'"
  run virsh snapshot-revert "$vm" "$name"
  ok "$vm reverted to '$name'"
}

do_teardown() {
  warn "This removes ALL lab VMs, the web containers, the '$LAB_NET_NAME' network and the '$LAB_STORAGE_POOL' pool."
  confirm "Really tear down the whole lab?" || die "aborted"

  # containers + macvlan
  if have_cmd docker && docker info >/dev/null 2>&1; then
    docker rm -f dvwa juiceshop >/dev/null 2>&1 || true
    docker network rm hacklab-mv >/dev/null 2>&1 || true
    ok "removed web containers + macvlan"
  fi

  # VMs
  local vm
  for vm in $(lab_vms); do
    log "removing VM $vm"
    virsh destroy "$vm" >/dev/null 2>&1 || true
    # --nvram drops the UEFI varstore; --snapshots-metadata drops snapshot records
    virsh undefine "$vm" --nvram --snapshots-metadata >/dev/null 2>&1 \
      || virsh undefine "$vm" --snapshots-metadata >/dev/null 2>&1 \
      || virsh undefine "$vm" >/dev/null 2>&1 || true
  done
  ok "VMs removed"

  # network
  virsh net-destroy "$LAB_NET_NAME" >/dev/null 2>&1 || true
  virsh net-undefine "$LAB_NET_NAME" >/dev/null 2>&1 || true
  ok "network '$LAB_NET_NAME' removed"

  # pool (definition only; disks handled below)
  virsh pool-destroy "$LAB_STORAGE_POOL" >/dev/null 2>&1 || true
  virsh pool-undefine "$LAB_STORAGE_POOL" >/dev/null 2>&1 || true
  ok "pool '$LAB_STORAGE_POOL' removed"

  if confirm "Also delete the VM disks in $LAB_STORAGE_DIR? (downloads/ are kept)"; then
    as_root rm -rf "${LAB_STORAGE_DIR:?}/"* 2>/dev/null || true
    ok "VM disks deleted"
  else
    warn "left VM disks in $LAB_STORAGE_DIR"
  fi
  ok "teardown complete"
}

# --- dispatch ---------------------------------------------------------------
[ $# -ge 1 ] || usage 1
cmd="$1"; shift || true
# pull a trailing --yes anywhere
args=(); for a in "$@"; do [ "$a" = "--yes" ] || [ "$a" = "-y" ] && ASSUME_YES=1 || args+=("$a"); done
set -- "${args[@]:-}"
export ASSUME_YES="${ASSUME_YES:-0}"

case "$cmd" in
  snapshot)
    if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
      # one VM (+ optional name), or several VM names
      if [ $# -eq 2 ]; then do_snapshot "$1" "$2"; else for v in "$@"; do do_snapshot "$v"; done; fi
    else
      for v in $(lab_vms); do do_snapshot "$v"; done
    fi ;;
  revert)   [ -n "${1:-}" ] || usage 1; do_revert "$1" "${2:-}" ;;
  list)     if [ -n "${1:-}" ]; then virsh snapshot-list "$1"; else for v in $(lab_vms); do echo "== $v =="; virsh snapshot-list "$v"; done; fi ;;
  teardown) do_teardown ;;
  -h|--help) usage 0 ;;
  *) die "unknown command: $cmd (snapshot|revert|list|teardown)" ;;
esac
