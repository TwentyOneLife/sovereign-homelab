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
# The trace goes to stderr so `$(run ...)`/`$(as_root ...)` capture only the
# command's real output, never the "$ ..."/"# ..." banner (a stdout banner
# silently poisons string compares like fs = "LVM2_member").
run() { printf '    %s$ %s%s\n' "$_c_blue" "$*" "$_c_reset" >&2; "$@"; }

# fetch <url> <dest>: robust download. Resumes a partial (-C -) and retries
# transient failures including a mid-stream reset (SourceForge and other mirrors
# do this; plain `--retry` does not cover curl exit 56, `--retry-all-errors` does).
dl_fetch() {
  need_cmd curl
  run curl -fL --retry 5 --retry-all-errors --retry-delay 3 \
      --connect-timeout 30 -C - -o "$2" "$1"
}

# --- privilege --------------------------------------------------------------
# as_root: run a single command as root only where genuinely needed.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "this step needs root and sudo is not installed"
    printf '    %s# %s%s\n' "$_c_yellow" "$*" "$_c_reset" >&2
    sudo "$@"
  fi
}

# --- prerequisite checks ----------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1 (see builder/README.md)"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# osinfo_pick <preferred> [fallback...]: the first os short-id this host's
# virt-install actually knows. A distro's own release often postdates its
# shipped osinfo-db (Debian bookworm has no 'debian12'), and an explicit unknown
# --osinfo name is a hard error, so pick a known one instead of hardcoding.
osinfo_pick() {
  local known; known="$(virt-install --osinfo list 2>/dev/null)"
  local n; for n in "$@"; do grep -qx "$n" <<<"$known" && { echo "$n"; return; }; done
  echo generic
}

# --- virsh / libvirt wrappers ----------------------------------------------
V="virsh"
# NOTE: match on a captured string via here-string, never `cmd | grep -q`.
# Under `set -o pipefail`, grep -q closes the pipe on first match and virsh dies
# with SIGPIPE (141), which pipefail then reports as failure - so the predicate
# would wrongly return false even on a match. The here-string avoids the pipe.
vm_exists()   { $V dominfo "$1"   >/dev/null 2>&1; }
vm_running()  { grep -q running               <<<"$($V domstate "$1" 2>/dev/null)"; }
net_exists()  { $V net-info "$1"  >/dev/null 2>&1; }
net_active()  { grep -qiE '^Active:[[:space:]]+yes' <<<"$($V net-info "$1" 2>/dev/null)"; }
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
  grep -q "GOODSIG" <<<"$out" || die "gpg: no good signature on $(basename "$signed")"
  local clean_fpr; clean_fpr="$(echo "$fpr" | tr -d ' ')"
  if ! grep -qi "VALIDSIG.*$clean_fpr" <<<"$out"; then
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

# nbd_teardown_dm: deactivate/remove any device-mapper (LVM) nodes stacked on
# $NBD_DEV. Metasploitable's disk is LVM; udev auto-activates its VG and the
# resulting dm nodes keep the nbd device busy, so a later --disconnect silently
# fails and the NEXT image cannot attach (partprobe gets EBUSY and the kernel
# keeps the old partition table). Prefer a clean LVM deactivate, then mop up dm.
nbd_teardown_dm() {
  local dev; dev="$(basename "$NBD_DEV")"
  if as_root sh -c 'command -v vgchange >/dev/null 2>&1'; then
    local vg
    for vg in $(as_root pvs --noheadings -o pv_name,vg_name 2>/dev/null \
                  | awk -v d="$NBD_DEV" '$1 ~ d {print $2}' | sort -u); do
      as_root vgchange -an "$vg" >/dev/null 2>&1 || true
    done
  fi
  local dm
  for dm in $(as_root dmsetup ls 2>/dev/null | awk 'NF && $1!="No"{print $1}'); do
    if grep -qE "\(${dev}(p[0-9]+)?\)" <<<"$(as_root dmsetup deps -o devname "$dm" 2>/dev/null)"; then
      as_root dmsetup remove --retry "$dm" >/dev/null 2>&1 || true
    fi
  done
}

# nbd_free: tear down dm, disconnect, and CONFIRM the device is really free.
# A disconnected nbd device reports size 0; anything else means it is still
# busy (usually a lingering dm node) and must be a hard error, not silence.
nbd_free() {
  nbd_teardown_dm
  as_root sync
  as_root qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  # lsblk right-pads the value; keep only digits so the compare is numeric.
  local sz; sz="$(lsblk -bdno SIZE "$NBD_DEV" 2>/dev/null | tr -dc '0-9')"
  [ -z "$sz" ] || [ "$sz" = 0 ] || die "$NBD_DEV still busy after disconnect (size=$sz). Inspect: lsblk $NBD_DEV ; sudo dmsetup ls"
}

nbd_up() {
  local img="$1"
  [ -f "$img" ] || die "nbd_up: image not found: $img"
  need_cmd qemu-nbd
  as_root modprobe nbd max_part=8 2>/dev/null || true
  # start from a known-clean device (defend against leftovers from an aborted run)
  nbd_free
  log "attaching $(basename "$img") to $NBD_DEV"
  as_root qemu-nbd --connect="$NBD_DEV" "$img"
  sleep 2
  as_root partprobe "$NBD_DEV" 2>/dev/null || warn "partprobe $NBD_DEV failed (device busy?)"
  as_root udevadm settle 2>/dev/null || true
  # udev activates LVM asynchronously - too late for us, and the Metasploitable
  # root lives on an LV. Activate any LVM PV on the image now, synchronously.
  local p
  for p in $(lsblk -rno NAME "$NBD_DEV" 2>/dev/null | tail -n +2); do
    if [ "$(as_root blkid -s TYPE -o value "/dev/$p" 2>/dev/null)" = "LVM2_member" ]; then
      as_root pvscan --cache -aay "/dev/$p" >/dev/null 2>&1 || true
    fi
  done
  as_root udevadm settle 2>/dev/null || true
  local part; part="$(nbd_root_part)"
  [ -n "$part" ] || { nbd_free; die "no Linux root partition found on $img"; }
  NBD_MNT="$(mktemp -d)"
  log "mounting root partition $part at $NBD_MNT"
  as_root mount "$part" "$NBD_MNT"
}

nbd_down() {
  [ -n "$NBD_MNT" ] && as_root umount "$NBD_MNT" 2>/dev/null || true
  [ -n "$NBD_MNT" ] && rmdir "$NBD_MNT" 2>/dev/null || true
  NBD_MNT=""
  nbd_free
}

# nbd_root_part: largest ext2/3/4 filesystem on $NBD_DEV (layouts differ per
# image; Metasploitable's root is an LVM LV, others are a plain partition).
# -p gives full device paths, so an LV comes back as /dev/mapper/<vg>-<lv>.
nbd_root_part() {
  local best="" bestsz=0 name fs sz
  while read -r name fs sz; do
    # lsblk FSTYPE comes from udev and can be empty right after connect;
    # fall back to a direct blkid probe (needs root on the device).
    [ -z "$fs" ] && fs="$(as_root blkid -s TYPE -o value "$name" 2>/dev/null || true)"
    case "$fs" in
      ext2|ext3|ext4)
        [ -n "$sz" ] || sz=0
        if [ "$sz" -gt "$bestsz" ]; then bestsz="$sz"; best="$name"; fi ;;
    esac
  done < <(lsblk -brnpo NAME,FSTYPE,SIZE "$NBD_DEV" 2>/dev/null | tail -n +2)
  echo "$best"
}

# write_root <relative/path> : write stdin into the mounted guest root (as root).
write_root() {
  local dest="$NBD_MNT/$1"
  as_root mkdir -p "$(dirname "$dest")"
  as_root tee "$dest" >/dev/null
}

# Branded login banner, emitted to stdout. Pipe into write_root "etc/motd" during
# offline customization so every machine this builder makes carries the backlink.
# Uses BRAND_GITHUB / BRAND_SITE from lab.conf, so a fork rebrands by editing that.
brand_motd() {
  cat <<EOF

------------------------------------------------------------------
  Sovereign Homelab - part of TwentyOne.Life
  "Secure your homelab, secure your node."

  GitHub:  ${BRAND_GITHUB}
  Course:  ${BRAND_GITHUB}/sovereign-homelab
  About:   ${BRAND_SITE}
------------------------------------------------------------------

EOF
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
