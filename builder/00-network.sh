#!/usr/bin/env bash
# 00-network.sh - create the isolated libvirt network and the dir storage pool.
# Idempotent: safe to re-run. Refuses to touch an existing net/pool that differs
# from lab.conf rather than silently redefining it.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

need_cmd virsh

# ---------------------------------------------------------------------------
# Storage pool: a plain 'dir' pool at $LAB_STORAGE_DIR.
# ---------------------------------------------------------------------------
setup_pool() {
  log "storage pool '$LAB_STORAGE_POOL' -> $LAB_STORAGE_DIR"
  if pool_exists "$LAB_STORAGE_POOL"; then
    local cur
    cur="$(virsh pool-dumpxml "$LAB_STORAGE_POOL" | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1)"
    if [ "$cur" != "$LAB_STORAGE_DIR" ]; then
      die "pool '$LAB_STORAGE_POOL' already exists but points at '$cur', not '$LAB_STORAGE_DIR'.
       Edit LAB_STORAGE_POOL/LAB_STORAGE_DIR in lab.conf to match, or remove the old pool."
    fi
    ok "pool already defined and consistent"
  else
    # The pool dir is usually root-owned (default /var/lib/libvirt/images/...).
    as_root install -d -m 0755 "$LAB_STORAGE_DIR"
    run virsh pool-define-as "$LAB_STORAGE_POOL" dir --target "$LAB_STORAGE_DIR"
    run virsh pool-build "$LAB_STORAGE_POOL" || true
    ok "pool defined"
  fi
  virsh pool-autostart "$LAB_STORAGE_POOL" >/dev/null 2>&1 || true
  virsh pool-start "$LAB_STORAGE_POOL" >/dev/null 2>&1 || true
  # A user-writable download/scratch dir inside the repo (gitignored).
  mkdir -p "$DOWNLOAD_DIR"
}

# ---------------------------------------------------------------------------
# Isolated network: NO <forward> element at all.
#   With no forward, libvirt does not route the bridge to any other interface,
#   so guests cannot reach the host LAN or the internet. The host still sits on
#   the bridge at $LAB_HOST_IP, which is what lets you drive the guests.
# A DHCP range is declared for completeness, but every guest is given a STATIC
# address by the component scripts: some host firewalls and VPN kill switches
# drop the DHCP bootstrap broadcast on libvirt bridges, so leases are unreliable.
# ---------------------------------------------------------------------------
setup_network() {
  local prefix="${LAB_SUBNET##*/}"
  local netmask base
  netmask="$(prefix2netmask "$prefix")"
  base="$(net_prefix3 "$LAB_HOST_IP")"

  log "isolated network '$LAB_NET_NAME' (bridge $LAB_BRIDGE, host $LAB_HOST_IP/$prefix, no forward)"
  if net_exists "$LAB_NET_NAME"; then
    local curbr curip
    curbr="$(virsh net-dumpxml "$LAB_NET_NAME" | sed -n "s:.*<bridge name='\([^']*\)'.*:\1:p" | head -1)"
    curip="$(virsh net-dumpxml "$LAB_NET_NAME" | sed -n "s:.*<ip address='\([^']*\)'.*:\1:p" | head -1)"
    if [ "$curbr" != "$LAB_BRIDGE" ] || [ "$curip" != "$LAB_HOST_IP" ]; then
      die "network '$LAB_NET_NAME' already exists with bridge=$curbr ip=$curip,
       which differs from lab.conf (bridge=$LAB_BRIDGE ip=$LAB_HOST_IP).
       Remove it (reset.sh) or reconcile lab.conf before continuing."
    fi
    if grep -q "<forward" <<<"$(virsh net-dumpxml "$LAB_NET_NAME")"; then
      die "network '$LAB_NET_NAME' has a <forward> element - it is NOT isolated. Refusing to use it."
    fi
    ok "network already defined, isolated and consistent"
  else
    local xml; xml="$(mktemp --suffix=.xml)"
    cat > "$xml" <<EOF
<network>
  <name>${LAB_NET_NAME}</name>
  <bridge name='${LAB_BRIDGE}' stp='on' delay='0'/>
  <domain name='${LAB_NET_NAME}.lan' localOnly='yes'/>
  <ip address='${LAB_HOST_IP}' netmask='${netmask}'>
    <dhcp>
      <range start='${base}.100' end='${base}.200'/>
    </dhcp>
  </ip>
</network>
EOF
    run virsh net-define "$xml"
    rm -f "$xml"
    ok "network defined (no forward = isolated)"
  fi
  virsh net-autostart "$LAB_NET_NAME" >/dev/null 2>&1 || true
  virsh net-start "$LAB_NET_NAME" >/dev/null 2>&1 || true

  # Hard self-check: an isolated network must never carry a forward element.
  # (here-string, not a pipe: under pipefail, `virsh | grep -q` would SIGPIPE
  # virsh on a match and the `if` would read a real <forward> as absent - a
  # false "isolated" pass on exactly the dangerous case.)
  if grep -q "<forward" <<<"$(virsh net-dumpxml "$LAB_NET_NAME")"; then
    die "ISOLATION CHECK FAILED: '$LAB_NET_NAME' has a <forward> element."
  fi
  ok "isolation check passed: '$LAB_NET_NAME' has no <forward> element"
}

setup_pool
setup_network
ok "network + storage ready"
