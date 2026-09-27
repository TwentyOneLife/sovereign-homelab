#!/usr/bin/env bash
# 20-targets-linux.sh - the two Linux targets:
#   msf2 : Metasploitable 2 (VMDK -> qcow2, SATA + e1000, static IP)
#   blue : Debian genericcloud, customized offline into a hardening target
#
# Offline customization uses qemu-nbd, which needs root (nbd module + mount).
# Those steps are wrapped in as_root and printed as '# ...' so you can see them.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

need_cmd virsh; need_cmd qemu-img; need_cmd virt-install; need_cmd qemu-nbd

PREFIX="${LAB_SUBNET##*/}"
NETMASK="$(prefix2netmask "$PREFIX")"

# ===========================================================================
# Metasploitable 2
# ===========================================================================
# SourceForge/Rapid7 zip. No upstream GPG signature exists; the hash below is
# the community-known value (also recorded in this lab's build notes).
MSF2_SHA256="2ae8788e95273eee87bd379a250d86ec52f286fa7fe84773a3a8f6524085a1ff"
MSF2_URL="https://sourceforge.net/projects/metasploitable/files/Metasploitable2/metasploitable-linux-2.0.0.zip/download"
MSF2_ZIP="$DOWNLOAD_DIR/metasploitable-linux-2.0.0.zip"
MSF2_DISK="$LAB_STORAGE_DIR/msf2.qcow2"

build_msf2() {
  if vm_exists msf2; then ok "VM 'msf2' already defined"; return; fi
  need_cmd unzip
  mkdir -p "$DOWNLOAD_DIR"
  if [ ! -s "$MSF2_ZIP" ]; then dl_fetch "$MSF2_URL" "$MSF2_ZIP"; fi
  verify_sha256 "$MSF2_ZIP" "$MSF2_SHA256"

  if [ ! -f "$MSF2_DISK" ]; then
    local vmdk
    vmdk="$(find "$DOWNLOAD_DIR" -iname 'Metasploitable.vmdk' 2>/dev/null | head -1)"
    if [ -z "$vmdk" ]; then
      log "extracting Metasploitable 2"
      run unzip -o -q "$MSF2_ZIP" -d "$DOWNLOAD_DIR"
      vmdk="$(find "$DOWNLOAD_DIR" -iname 'Metasploitable.vmdk' | head -1)"
    fi
    [ -n "$vmdk" ] || die "Metasploitable.vmdk not found after unzip"
    log "converting VMDK -> qcow2"
    local tmp="$DOWNLOAD_DIR/msf2.qcow2"
    run qemu-img convert -O qcow2 "$vmdk" "$tmp"
    as_root cp --reflink=auto "$tmp" "$MSF2_DISK"
    run virsh pool-refresh "$LAB_STORAGE_POOL" >/dev/null || true
  fi

  # Static IP via /etc/network/interfaces (also stops the image's stray dhclient
  # from clobbering the address on a running box).
  log "offline-customizing msf2 (static $MSF2_IP)"
  nbd_up "$MSF2_DISK"; trap nbd_down EXIT
  write_root "etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
  address ${MSF2_IP}
  netmask ${NETMASK}
EOF
  # Best-effort console keymap for this pre-systemd OS (attacked over the net anyway).
  if [ -f "$NBD_MNT/etc/default/console-setup" ]; then
    as_root sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"${LAB_KEYMAP}\"/" "$NBD_MNT/etc/default/console-setup" || true
  fi
  nbd_down; trap - EXIT

  log "defining VM 'msf2' (i440fx, SATA disk, e1000 NIC - old kernel has no virtio)"
  run virt-install --connect "$LIBVIRT_DEFAULT_URI" --name msf2 \
    --memory 1024 --vcpus 1 \
    --machine pc \
    --disk path="$MSF2_DISK",bus=sata,format=qcow2 \
    --network network="$LAB_NET_NAME",model=e1000,mac="$(mac_for_ip "$MSF2_IP")" \
    --osinfo detect=on,name=ubuntu8.04 \
    --graphics spice --video qxl \
    --import --noautoconsole
  ok "VM 'msf2' created (login msfadmin/msfadmin; static $MSF2_IP)"
  warn "msf2 ignores ACPI reboot: use 'virsh destroy msf2 && virsh start msf2' for a real restart."
}

# ===========================================================================
# blue - Debian 12 genericcloud hardening target
# ===========================================================================
DEB_IMG="debian-12-genericcloud-amd64.qcow2"
DEB_BASEURL="https://cloud.debian.org/images/cloud/bookworm/latest"
DEB_QCOW="$DOWNLOAD_DIR/$DEB_IMG"
DEB_SUMS="$DOWNLOAD_DIR/SHA512SUMS.debian"
DEB_SUMS_SIG="$DOWNLOAD_DIR/SHA512SUMS.debian.sign"
BLUE_DISK="$LAB_STORAGE_DIR/blue.qcow2"
# Optional: set to the Debian cloud signing key fingerprint to GPG-verify the
# checksums file too (see README). Empty = sha512 only, with a warning.
DEBIAN_CLOUD_KEY_FPR="${DEBIAN_CLOUD_KEY_FPR:-}"

build_blue() {
  if vm_exists blue; then ok "VM 'blue' already defined"; return; fi
  need_cmd openssl
  mkdir -p "$DOWNLOAD_DIR"
  if [ ! -s "$DEB_QCOW" ]; then dl_fetch "$DEB_BASEURL/$DEB_IMG" "$DEB_QCOW"; fi
  if [ ! -s "$DEB_SUMS" ]; then dl_fetch "$DEB_BASEURL/SHA512SUMS" "$DEB_SUMS"; fi

  # GPG-verify the checksums file if a key fingerprint was pinned; otherwise warn.
  if [ -n "$DEBIAN_CLOUD_KEY_FPR" ]; then
    [ -s "$DEB_SUMS_SIG" ] || { dl_fetch "$DEB_BASEURL/SHA512SUMS.sign" "$DEB_SUMS_SIG"; }
    verify_gpg "$DEB_SUMS_SIG" "$DEB_SUMS" "$DEBIAN_CLOUD_KEY_FPR"
  else
    warn "DEBIAN_CLOUD_KEY_FPR not set: verifying the sha512 only (no signature check on SHA512SUMS)."
    warn "See README to pin the Debian cloud signing key for full provenance."
  fi
  # sha512 of the image against the (now possibly signed) checksums file.
  local want got
  want="$(awk -v f="$DEB_IMG" '$2 ~ f {print $1}' "$DEB_SUMS" | head -1)"
  [ -n "$want" ] || die "no sha512 line for $DEB_IMG in SHA512SUMS"
  log "sha512 verifying $DEB_IMG"
  got="$(sha512sum "$DEB_QCOW" | awk '{print $1}')"
  [ "$got" = "$want" ] || die "sha512 MISMATCH for $DEB_IMG"
  ok "sha512 OK: $DEB_IMG"

  if [ ! -f "$BLUE_DISK" ]; then
    as_root cp --reflink=auto "$DEB_QCOW" "$BLUE_DISK"
    as_root qemu-img resize "$BLUE_DISK" 20G
    run virsh pool-refresh "$LAB_STORAGE_POOL" >/dev/null || true
  fi

  # Offline customization (the qemu-nbd approach that actually worked here):
  # passwords, static IP via systemd-networkd, ssh, host keys, scenario flag.
  local hash; hash="$(openssl passwd -6 "$BLUE_PASS")"
  log "offline-customizing blue (users, static $BLUE_IP, ssh, flag)"
  nbd_up "$BLUE_DISK"; trap nbd_down EXIT

  # grow the root fs into the resized disk (best effort; needs cloud-guest-utils)
  if have_cmd growpart; then
    local rp; rp="$(nbd_root_part)"
    as_root umount "$NBD_MNT" 2>/dev/null || true
    as_root growpart "$NBD_DEV" "${rp##*p}" 2>/dev/null || true
    as_root partprobe "$NBD_DEV" 2>/dev/null || true
    as_root e2fsck -fy "$rp" >/dev/null 2>&1 || true
    as_root resize2fs "$rp" >/dev/null 2>&1 || true
    as_root mount "$rp" "$NBD_MNT"
  fi

  # root password
  as_root sed -i "s|^root:[^:]*:|root:${hash}:|" "$NBD_MNT/etc/shadow"
  # analyst user in sudo
  as_root chroot "$NBD_MNT" useradd -m -s /bin/bash -G sudo analyst 2>/dev/null || true
  echo "analyst:${hash}" | as_root chroot "$NBD_MNT" chpasswd -e 2>/dev/null \
    || as_root sed -i "/^analyst:/s|^analyst:[^:]*:|analyst:${hash}:|" "$NBD_MNT/etc/shadow"

  # static network via systemd-networkd; disable cloud-init networking
  write_root "etc/systemd/network/10-lab.network" <<EOF
[Match]
Name=en*

[Network]
Address=${BLUE_IP}/${PREFIX}
EOF
  write_root "etc/cloud/cloud.cfg.d/99-disable-net.cfg" <<EOF
network: {config: disabled}
EOF
  as_root ln -sf /lib/systemd/system/systemd-networkd.service \
    "$NBD_MNT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || true

  # ssh: password + root login (lab only); generate host keys now (cloud image
  # ships without them and has no datasource to create them at first boot)
  as_root sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin yes|; s|^#\?PasswordAuthentication.*|PasswordAuthentication yes|' \
    "$NBD_MNT/etc/ssh/sshd_config" 2>/dev/null || true
  # Generate host keys on the HOST side, straight into the image's /etc/ssh.
  # `chroot ssh-keygen -A` fails silently here because no /dev is bind-mounted
  # in the chroot, so it cannot read /dev/urandom - leaving blue with no host
  # keys, so sshd fails to start and 'ssh to blue' (module 06) is impossible.
  need_cmd ssh-keygen
  local kt
  for kt in rsa ecdsa ed25519; do
    [ -f "$NBD_MNT/etc/ssh/ssh_host_${kt}_key" ] || \
      as_root ssh-keygen -q -t "$kt" -N "" -C "" -f "$NBD_MNT/etc/ssh/ssh_host_${kt}_key" </dev/null
  done

  # hostname: the modules and README call this box 'blue'. Without it the prompt
  # and `hostname` output read 'localhost' and blue.hacklab.lan never resolves.
  write_root "etc/hostname" <<< "blue"
  as_root sh -c "grep -qE '[[:space:]]blue([[:space:]]|\$)' '$NBD_MNT/etc/hosts' 2>/dev/null || printf '127.0.1.1\tblue\n' >> '$NBD_MNT/etc/hosts'"

  # keymap + scenario flag
  write_root "etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${LAB_KEYMAP}"
XKBVARIANT=""
XKBOPTIONS=""
EOF
  write_root "etc/vconsole.conf" <<EOF
KEYMAP=${LAB_KEYMAP}
EOF
  write_root "root/lab/flag.txt" <<EOF
FLAG-BLUE{harden-me-then-reattack}
EOF

  # branded login banner (backlink to TwentyOne.Life)
  brand_motd | write_root "etc/motd"

  nbd_down; trap - EXIT

  log "defining VM 'blue'"
  run virt-install --connect "$LIBVIRT_DEFAULT_URI" --name blue \
    --memory 2048 --vcpus 2 --cpu host-passthrough \
    --machine q35 \
    --disk path="$BLUE_DISK",bus=virtio,format=qcow2 \
    --network network="$LAB_NET_NAME",model=virtio,mac="$(mac_for_ip "$BLUE_IP")" \
    --osinfo "$(osinfo_pick debian12 debian11 debiantesting)" \
    --graphics spice --video virtio \
    --import --noautoconsole
  ok "VM 'blue' created (login root or ${BLUE_USER} / ${BLUE_PASS}; static $BLUE_IP)"
}

build_msf2
build_blue
ok "linux targets done"
