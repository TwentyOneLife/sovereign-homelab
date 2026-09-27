#!/usr/bin/env bash
# setup.sh - orchestrator for the Sovereign Homelab builder.
# Reads lab.conf, checks prerequisites, and runs the component scripts in order.
#
#   ./setup.sh --all                 build everything, in order
#   ./setup.sh network kali web      build only the named components
#   ./setup.sh --all --yes           skip confirmation prompts
#   ./setup.sh --check               only run the prerequisite check
#
# Components (in build order): network kali linux web windows
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

ASSUME_YES=0
DO_CHECK_ONLY=0
declare -a COMPONENTS=()
ALL_ORDER=(network kali linux web windows)

usage() { awk 'NR==1{next} /^#/{s=$0; sub(/^# ?/,"",s); print s; next} {exit}' "$0"; exit "${1:-0}"; }

# map a component name to its script
script_for() {
  case "$1" in
    network)        echo "00-network.sh" ;;
    kali)           echo "10-kali.sh" ;;
    linux|targets)  echo "20-targets-linux.sh" ;;
    web)            echo "30-web.sh" ;;
    windows|win)    echo "50-windows.sh" ;;
    *) die "unknown component: $1 (valid: ${ALL_ORDER[*]})" ;;
  esac
}

# --- parse args -------------------------------------------------------------
[ $# -eq 0 ] && usage 1
while [ $# -gt 0 ]; do
  case "$1" in
    --all)   COMPONENTS=("${ALL_ORDER[@]}") ;;
    --yes|-y) ASSUME_YES=1 ;;
    --check) DO_CHECK_ONLY=1 ;;
    -h|--help) usage 0 ;;
    -*) die "unknown flag: $1" ;;
    *) COMPONENTS+=("$1") ;;
  esac
  shift
done
export ASSUME_YES

# --- prerequisite check -----------------------------------------------------
check_prereqs() {
  log "checking prerequisites"
  local miss=0
  for c in virsh qemu-img virt-install; do have_cmd "$c" || { warn "missing: $c"; miss=1; }; done
  for c in xorriso gpg sha256sum sha512sum openssl unzip curl ssh-keygen; do have_cmd "$c" || { warn "missing (needed by some components): $c"; }; done
  have_cmd 7z || have_cmd 7za || warn "missing (needed for kali): 7z / 7za (p7zip-full)"
  have_cmd docker || warn "missing (needed for web): docker"
  # lvm2 lives in /usr/sbin and these scripts run unprivileged, so command -v
  # (have_cmd) misses it - check the sbin path too. Needed to mount the LVM
  # Metasploitable image; without it, target customization silently mis-targets.
  { [ -x /usr/sbin/vgchange ] || have_cmd vgchange; } || warn "missing (needed for the Metasploitable LVM image): lvm2"
  # KVM sanity
  [ -e /dev/kvm ] || warn "/dev/kvm not present - is hardware virtualization enabled and kvm loaded?"
  virsh version >/dev/null 2>&1 || { warn "cannot talk to libvirt (is libvirtd running, are you in the 'libvirt'/'kvm' groups?)"; miss=1; }
  [ "$miss" -eq 0 ] || die "core prerequisites missing - see builder/README.md to install them"
  ok "prerequisites OK"
}

check_prereqs
[ "$DO_CHECK_ONLY" -eq 1 ] && exit 0
[ ${#COMPONENTS[@]} -gt 0 ] || usage 1

printf '\n%s=== Sovereign Homelab builder ===%s\n' "$_c_green" "$_c_reset"
echo "  network : $LAB_NET_NAME ($LAB_SUBNET, host $LAB_HOST_IP, isolated)"
echo "  pool    : $LAB_STORAGE_POOL -> $LAB_STORAGE_DIR"
echo "  keymap  : $LAB_KEYMAP"
echo "  build   : ${COMPONENTS[*]}"
echo
confirm "Proceed?" || die "aborted"

for comp in "${COMPONENTS[@]}"; do
  s="$(script_for "$comp")"
  printf '\n%s----- %s (%s) -----%s\n' "$_c_green" "$comp" "$s" "$_c_reset"
  bash "$BUILDER_DIR/$s"
done

printf '\n%sAll requested components built.%s\n' "$_c_green" "$_c_reset"
echo "Next: start the course at module 00, snapshot each VM as 'clean-baseline' when ready (see reset.sh)."
