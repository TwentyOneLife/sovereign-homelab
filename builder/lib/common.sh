# shellcheck shell=bash
# Sovereign Homelab - shared helpers for the builder scripts.
# Sourced by every component script; not meant to be run on its own.

# --- locate the builder tree and the repo root -----------------------------
# BUILDER_DIR = .../sovereign-homelab/builder ; REPO_DIR = its parent.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_DIR="$(cd "$LIB_DIR/.." && pwd)"
REPO_DIR="$(cd "$BUILDER_DIR/.." && pwd)"

# Downloads and intermediate files live in the repo (gitignored, user-writable).
# Final VM disks are placed into the libvirt pool dir ($LAB_STORAGE_DIR) later.
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BUILDER_DIR/downloads}"

# --- configuration ----------------------------------------------------------
# lab.conf is the single source of truth; lab.local.conf (gitignored) overrides.
load_config() {
  local conf="$REPO_DIR/lab.conf"
  [ -f "$conf" ] || die "config not found: $conf"
  # shellcheck disable=SC1090
  . "$conf"
  if [ -f "$REPO_DIR/lab.local.conf" ]; then
    # shellcheck disable=SC1091
    . "$REPO_DIR/lab.local.conf"
  fi
  : "${LAB_KEYMAP:=us}"
  export LIBVIRT_DEFAULT_URI="qemu:///system"
}

# --- logging ----------------------------------------------------------------
_c_reset=$'\033[0m'; _c_blue=$'\033[1;34m'; _c_yellow=$'\033[1;33m'; _c_red=$'\033[1;31m'; _c_green=$'\033[1;32m'
log()  { printf '%s[*]%s %s\n'  "$_c_blue"   "$_c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n'  "$_c_green"  "$_c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$_c_yellow" "$_c_reset" "$*" >&2; }
die()  { printf '%s[x]%s %s\n'  "$_c_red"    "$_c_reset" "$*" >&2; exit 1; }

# run: echo a command, then execute it. Keeps the build auditable.
run() { printf '    %s$ %s%s\n' "$_c_blue" "$*" "$_c_reset"; "$@"; }

# --- privilege --------------------------------------------------------------
# as_root: run a single command as root only where genuinely needed.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "this step needs root and sudo is not installed"
    printf '    %s# %s%s\n' "$_c_yellow" "$*" "$_c_reset"
    sudo "$@"
  fi
}

# --- prerequisite checks ----------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1 (see builder/README.md)"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- virsh / libvirt wrappers ----------------------------------------------
V="virsh"
vm_exists()   { $V dominfo "$1"   >/dev/null 2>&1; }
vm_running()  { $V domstate "$1" 2>/dev/null | grep -q running; }
net_exists()  { $V net-info "$1"  >/dev/null 2>&1; }
pool_exists() { $V pool-info "$1" >/dev/null 2>&1; }

# --- verification helpers ---------------------------------------------------
# verify_sha256 <file> <expected-hex>
verify_sha256() {
  local file="$1" want="$2" got
  [ -f "$file" ] || die "verify_sha256: file not found: $file"
  log "sha256 verifying $(basename "$file")"
  got="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    die "sha256 MISMATCH for $file
       expected $want
       got      $got"
  fi
  ok "sha256 OK: $(basename "$file")"
}

# verify_sha256_from <sumsfile> <file>
# Uses a SHA256SUMS file that lists <hash>  <basename>.
verify_sha256_from() {
  local sums="$1" file="$2"
  [ -f "$sums" ] || die "verify_sha256_from: sums file not found: $sums"
  local want
  want="$(awk -v f="$(basename "$file")" '$2 ~ f {print $1}' "$sums" | head -1)"
  [ -n "$want" ] || die "no sha256 line for $(basename "$file") in $(basename "$sums")"
  verify_sha256 "$file" "$want"
}

# verify_gpg <detached-sig> <signed-file> <expected-fpr>
# Verifies with an ephemeral keyring seeded from the vendor key the caller imports.
# Confirms the good signature was made by <expected-fpr> (pin it, do not trust the sig's own claim).
verify_gpg() {
  local sig="$1" signed="$2" fpr="$3" out
  need_cmd gpg
  log "gpg verifying $(basename "$signed") against $(basename "$sig")"
  out="$(gpg --status-fd 1 --verify "$sig" "$signed" 2>/dev/null || true)"
  echo "$out" | grep -q "GOODSIG" || die "gpg: no good signature on $(basename "$signed")"
  local clean_fpr; clean_fpr="$(echo "$fpr" | tr -d ' ')"
  if ! echo "$out" | grep -qi "VALIDSIG.*$clean_fpr"; then
    die "gpg: signature is not from the pinned key $fpr
       import the vendor key first, then re-run"
  fi
  ok "gpg OK: signed by $fpr"
}

# --- MAC addressing ---------------------------------------------------------
# Deterministic per-host MAC from the last octet of its lab IP, so NetworkManager
# keyfile matching and detach-interface --mac are stable across rebuilds.
# 52:54:00 is the QEMU/KVM OUI. 13:37 is the lab marker.
mac_for_ip() {
  local ip="$1" last
  last="${ip##*.}"
  printf '52:54:00:13:37:%02x' "$last"
}
# Kali's second (NAT) NIC gets a fixed, distinct MAC.
KALI_NAT_MAC="52:54:00:13:37:fe"

# --- offline image customization via qemu-nbd -------------------------------
# nbd_up <qcow2>  : connect the image, mount its root fs. Sets NBD_DEV and NBD_MNT.
# nbd_down        : unmount and disconnect. Always pair them (trap on the caller).
NBD_DEV="/dev/nbd0"
NBD_MNT=""
nbd_up() {
  local img="$1"
  [ -f "$img" ] || die "nbd_up: image not found: $img"
  need_cmd qemu-nbd
  as_root modprobe nbd max_part=8 2>/dev/null || true
  as_root qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  log "attaching $(basename "$img") to $NBD_DEV"
  as_root qemu-nbd --connect="$NBD_DEV" "$img"
  # settle + rescan the partition table
  sleep 2
  as_root partprobe "$NBD_DEV" 2>/dev/null || true
  as_root udevadm settle 2>/dev/null || true
  local part; part="$(nbd_root_part)"
  [ -n "$part" ] || { as_root qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true; die "no Linux root partition found on $img"; }
  NBD_MNT="$(mktemp -d)"
  log "mounting root partition $part at $NBD_MNT"
  as_root mount "$part" "$NBD_MNT"
}
nbd_down() {
  [ -n "$NBD_MNT" ] && as_root umount "$NBD_MNT" 2>/dev/null || true
  [ -n "$NBD_MNT" ] && rmdir "$NBD_MNT" 2>/dev/null || true
  NBD_MNT=""
  as_root sync
  as_root qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
}
# nbd_root_part: largest ext2/3/4 partition on $NBD_DEV (layouts differ per image).
nbd_root_part() {
  local best="" bestsz=0 name fs sz
  while read -r name fs sz; do
    # lsblk FSTYPE comes from udev and can be empty right after connect;
    # fall back to a direct blkid probe (needs root on the nbd device).
    [ -z "$fs" ] && fs="$(as_root blkid -s TYPE -o value "/dev/$name" 2>/dev/null || true)"
    case "$fs" in
      ext2|ext3|ext4)
        [ -n "$sz" ] || sz=0
        if [ "$sz" -gt "$bestsz" ]; then bestsz="$sz"; best="/dev/$name"; fi ;;
    esac
  done < <(lsblk -brno NAME,FSTYPE,SIZE "$NBD_DEV" 2>/dev/null | tail -n +2)
  echo "$best"
}

# write_root <relative/path> : write stdin into the mounted guest root (as root).
write_root() {
  local dest="$NBD_MNT/$1"
  as_root mkdir -p "$(dirname "$dest")"
  as_root tee "$dest" >/dev/null
}

# --- misc helpers -----------------------------------------------------------
# prefix2netmask 24 -> 255.255.255.0
prefix2netmask() {
  local p="$1" mask=() i
  for i in 0 1 2 3; do
    if [ "$p" -ge 8 ]; then mask[i]=255; p=$((p-8))
    elif [ "$p" -gt 0 ]; then mask[i]=$((256 - 2**(8-p))); p=0
    else mask[i]=0; fi
  done
  printf '%s.%s.%s.%s' "${mask[0]}" "${mask[1]}" "${mask[2]}" "${mask[3]}"
}
# net_prefix3 10.13.37.1 -> 10.13.37
net_prefix3() { echo "${1%.*}"; }

# confirm <prompt> : honours the global ASSUME_YES (set by --yes).
confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local ans
  read -r -p "$1 [y/N] " ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
