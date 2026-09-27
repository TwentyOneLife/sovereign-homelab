#!/usr/bin/env bash
# 30-web.sh - DVWA + OWASP Juice Shop as Docker containers on a macvlan attached
# to the lab bridge, so they get real IPs on the isolated subnet.
#
# Note: a macvlan blocks container <-> parent-host traffic BY DESIGN, so the
# host cannot curl or ping these containers. Kali (a bridge peer) can. The DVWA
# DB init below therefore runs from a throwaway container ON the macvlan.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

need_cmd docker
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (add your user to the 'docker' group, or run with sudo)"
net_exists "$LAB_NET_NAME" || die "lab network '$LAB_NET_NAME' not found - run 00-network.sh first"
virsh net-start "$LAB_NET_NAME" >/dev/null 2>&1 || true

MV="hacklab-mv"
DVWA_IMG="vulnerables/web-dvwa"
JUICE_IMG="bkimminich/juice-shop"

create_macvlan() {
  if docker network inspect "$MV" >/dev/null 2>&1; then ok "docker macvlan '$MV' exists"; return; fi
  log "creating docker macvlan '$MV' on $LAB_BRIDGE"
  run docker network create -d macvlan \
    --subnet="$LAB_SUBNET" --gateway="$LAB_HOST_IP" \
    -o parent="$LAB_BRIDGE" "$MV"
}

run_container() { # name image ip [extra run args...]
  local name="$1" image="$2" ip="$3"; shift 3
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    ok "container '$name' exists (docker rm -f $name to rebuild)"; return
  fi
  log "pulling $image (host-side; the container itself gets no internet)"
  run docker pull "$image"
  log "starting '$name' at $ip"
  run docker run -d --name "$name" --network "$MV" --ip "$ip" \
    --restart unless-stopped "$@" "$image"
}

init_dvwa_db() {
  # Reach DVWA from a peer on the macvlan (the host can't). Grab the CSRF
  # user_token from setup.php, then POST create_db.
  # -i attaches stdin so the heredoc reaches sh; --entrypoint overrides curl.
  log "initialising DVWA database (via an on-macvlan helper container)"
  docker run --rm -i --entrypoint sh --network "$MV" curlimages/curl:latest -s "$DVWA_IP" <<'SH' || warn "DVWA auto-init failed; open http://$DVWA_IP/setup.php and click 'Create / Reset Database'."
set -e
IP="$1"; base="http://$IP"
jar=$(mktemp)
# wait for DVWA to answer
for i in $(seq 1 30); do curl -s -o /dev/null "$base/setup.php" && break || sleep 2; done
tok=$(curl -s -c "$jar" "$base/setup.php" | tr '"' "'" | sed -n "s/.*user_token'[^']*value='\([0-9a-f]*\)'.*/\1/p" | head -1)
[ -n "$tok" ] || { echo "no user_token"; exit 1; }
curl -s -b "$jar" -o /dev/null \
  --data-urlencode "create_db=Create / Reset Database" \
  --data-urlencode "user_token=$tok" "$base/setup.php"
echo "DVWA db initialised"
SH
}

create_macvlan
run_container dvwa      "$DVWA_IMG"  "$DVWA_IP"
run_container juiceshop "$JUICE_IMG" "$JUICE_IP"
init_dvwa_db

ok "web targets up:"
echo "    DVWA        http://$DVWA_IP/        (admin/password)  - reach from Kali"
echo "    Juice Shop  http://$JUICE_IP:3000/  (self-register)   - reach from Kali"
warn "after a host reboot: ensure '$LAB_NET_NAME' is up, then 'docker start dvwa juiceshop' (bridge must exist before docker starts them)."
