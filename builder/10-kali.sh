#!/usr/bin/env bash
# 10-kali.sh - download + verify the official Kali QEMU image, customize it
# offline (static lab IP + keymap), and import it as the attacker VM.
# Two NICs: eth0 on the isolated lab net (static), eth1 on the NAT 'default'
# net for updates only (detach during exercises - see README).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

need_cmd virsh; need_cmd qemu-img; need_cmd virt-install; need_cmd gpg

# Idempotent: if the VM is already defined, do nothing (avoids re-hashing the
# 3.9 GB archive and, crucially, never attaches qemu-nbd to a disk in use).
if vm_exists kali; then ok "VM 'kali' already defined - nothing to do"; exit 0; fi

command -v 7z >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1 || die "need 7z or 7za (Debian/Ubuntu: apt install p7zip-full)"
SEVENZ="$(command -v 7z || command -v 7za)"

# Kali Archive Automatic Signing Key (2025). Pinned; cross-checked to kali.org/docs.
KALI_KEY_FPR="827C 8569 F251 8CC6 77FE CA1A ED65 462E C8D5 E4C5"
KALI_KEYRING_URL="https://archive.kali.org/archive-keyring.gpg"

IMG_BASE="kali-linux-${KALI_RELEASE}-qemu-amd64"
DL_URL="https://cdimage.kali.org/kali-${KALI_RELEASE}/${IMG_BASE}.7z"
SUMS_URL="https://cdimage.kali.org/kali-${KALI_RELEASE}/SHA256SUMS"
SUMS_SIG_URL="https://cdimage.kali.org/kali-${KALI_RELEASE}/SHA256SUMS.gpg"

ARCHIVE="$DOWNLOAD_DIR/${IMG_BASE}.7z"
SUMS="$DOWNLOAD_DIR/SHA256SUMS"
SUMS_SIG="$DOWNLOAD_DIR/SHA256SUMS.gpg"
POOL_DISK="$LAB_STORAGE_DIR/${IMG_BASE}.qcow2"

fetch() { # url dest
  [ -s "$2" ] && { log "have $(basename "$2"), skipping download"; return; }
  need_cmd curl
  dl_fetch "$1" "$2"
}

download_and_verify() {
  mkdir -p "$DOWNLOAD_DIR"
  fetch "$DL_URL"       "$ARCHIVE"
  fetch "$SUMS_URL"     "$SUMS"
  fetch "$SUMS_SIG_URL" "$SUMS_SIG"

  # Import the pinned Kali signing key into an ephemeral keyring, verify the
  # SHA256SUMS signature, then check the archive hash against that signed file.
  local gnupg; gnupg="$(mktemp -d)"; export GNUPGHOME="$gnupg"
  log "importing Kali archive signing key"
  if [ -f "$DOWNLOAD_DIR/archive-keyring.gpg" ] || fetch "$KALI_KEYRING_URL" "$DOWNLOAD_DIR/archive-keyring.gpg"; then
    gpg --import "$DOWNLOAD_DIR/archive-keyring.gpg" 2>/dev/null || true
  fi
  gpg --list-keys "$(echo "$KALI_KEY_FPR" | tr -d ' ')" >/dev/null 2>&1 \
    || die "Kali signing key not in keyring - import it from kali.org/docs and re-run"
  verify_gpg "$SUMS_SIG" "$SUMS" "$KALI_KEY_FPR"
  unset GNUPGHOME; rm -rf "$gnupg"
  verify_sha256_from "$SUMS" "$ARCHIVE"
}

extract_and_place() {
  if [ -f "$POOL_DISK" ]; then ok "disk already in pool: $POOL_DISK"; return; fi
  local qcow
  qcow="$DOWNLOAD_DIR/${IMG_BASE}.qcow2"
  if [ ! -f "$qcow" ]; then
    log "extracting $(basename "$ARCHIVE")"
    run "$SEVENZ" x -y -o"$DOWNLOAD_DIR" "$ARCHIVE" >/dev/null
    qcow="$(find "$DOWNLOAD_DIR" -name "${IMG_BASE}*.qcow2" | head -1)"
    [ -n "$qcow" ] || die "no qcow2 found after extracting $ARCHIVE"
  fi
  log "placing disk into pool"
  as_root cp --reflink=auto "$qcow" "$POOL_DISK"
  run virsh pool-refresh "$LAB_STORAGE_POOL" >/dev/null || true
}

customize_offline() {
  local lab_mac; lab_mac="$(mac_for_ip "$KALI_IP")"
  local prefix="${LAB_SUBNET##*/}"
  log "offline-customizing Kali (static $KALI_IP/$prefix on eth0, keymap $LAB_KEYMAP)"
  nbd_up "$POOL_DISK"
  trap nbd_down EXIT

  # NetworkManager keyfile: static, no gateway, matched by the lab NIC's MAC.
  write_root "etc/NetworkManager/system-connections/hacklab.nmconnection" <<EOF
[connection]
id=hacklab
type=ethernet
autoconnect=true
autoconnect-priority=100

[ethernet]
mac-address=${lab_mac^^}

[ipv4]
method=manual
address1=${KALI_IP}/${prefix}
never-default=true
may-fail=false

[ipv6]
method=disabled
EOF
  as_root chmod 600 "$NBD_MNT/etc/NetworkManager/system-connections/hacklab.nmconnection"

  # Keymap (console); the graphical desktop layout is picked at desktop login.
  write_root "etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${LAB_KEYMAP}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
  write_root "etc/vconsole.conf" <<EOF
KEYMAP=${LAB_KEYMAP}
EOF

  # branded login banner (backlink to TwentyOne.Life)
  brand_motd | write_root "etc/motd"

  nbd_down; trap - EXIT
  ok "Kali image customized"
}

define_vm() {
  if vm_exists kali; then ok "VM 'kali' already defined"; return; fi
  local lab_mac; lab_mac="$(mac_for_ip "$KALI_IP")"

  # NAT 'default' net gives Kali internet for updates. Only attach it if we can
  # actually bring it up: virt-install refuses to define against an inactive net,
  # so a silently-failed start would otherwise abort the whole VM define.
  local nat_args=()
  if net_exists default; then
    virsh net-autostart default >/dev/null 2>&1 || true
    net_active default || virsh net-start default >/dev/null 2>&1 || true
    if net_active default; then
      nat_args=(--network network=default,model=virtio,mac="$KALI_NAT_MAC")
    else
      warn "libvirt 'default' NAT network is present but could not be started:"
      warn "    $(virsh net-start default 2>&1 | tail -1)"
      warn "Defining Kali WITHOUT an internet NIC. Fix 'default' (often a host-LAN"
      warn "subnet clash with 192.168.122.0/24), then: virsh net-start default and"
      warn "re-attach, or re-run this script after removing the kali VM."
    fi
  else
    warn "libvirt 'default' NAT network not found - Kali will have no update NIC."
    warn "create it with: virsh net-start default (or virsh net-define /usr/share/libvirt/networks/default.xml)"
  fi

  log "defining VM 'kali'"
  run virt-install --connect "$LIBVIRT_DEFAULT_URI" --name kali \
    --memory 6144 --vcpus 4 --cpu host-passthrough \
    --machine q35 \
    --disk path="$POOL_DISK",bus=virtio,format=qcow2 \
    --network network="$LAB_NET_NAME",model=virtio,mac="$lab_mac" \
    "${nat_args[@]}" \
    --osinfo debiantesting \
    --graphics spice --video qxl --channel spicevmc \
    --import --noautoconsole
  ok "VM 'kali' created (login ${KALI_USER}/${KALI_PASS}; static $KALI_IP)"
  log "detach the NAT NIC during exercises:"
  echo "    virsh detach-interface kali network --mac $KALI_NAT_MAC --live"
}

download_and_verify
extract_and_place
customize_offline
define_vm
ok "kali done"
