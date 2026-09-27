#!/usr/bin/env bash
# 60-node.sh - stand up the flagship target: a Bitcoin Core node in regtest with a
# DELIBERATELY exposed, weakly-authenticated RPC and a funded wallet. This is the
# "secure your sovereign node" module's target (docs/12-secure-your-node.md).
#
# It runs as a Docker macvlan container on the isolated lab bridge, so it gets a real
# IP on the lab network and is reachable by Kali (like the DVWA/Juice Shop targets),
# but has no route off the lab. regtest coins have NO value; this is a safe teaching target.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../lab.conf"
[ -f "$HERE/../lab.local.conf" ] && source "$HERE/../lab.local.conf" || true

NET="hacklab-mv"                 # the docker macvlan network on the lab bridge (see 30-web.sh)
IMAGE="ruimarinho/bitcoin-core:latest"
RPCPORT=18443                    # regtest RPC port

echo "[*] node: ensuring image $IMAGE"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"

echo "[*] node: ensuring macvlan network $NET on $LAB_BRIDGE"
docker network inspect "$NET" >/dev/null 2>&1 || \
  docker network create -d macvlan \
    --subnet="$LAB_SUBNET" --gateway="$LAB_HOST_IP" --ip-range=10.13.37.32/28 \
    -o parent="$LAB_BRIDGE" "$NET"

echo "[*] node: (re)starting weak regtest node at $NODE_IP"
docker rm -f node >/dev/null 2>&1 || true
docker run -d --name node --network "$NET" --ip "$NODE_IP" --restart unless-stopped \
  "$IMAGE" \
  -regtest=1 -server=1 -txindex=1 \
  -rpcbind=0.0.0.0 -rpcallowip=0.0.0.0/0 \
  -rpcuser="$NODE_RPC_USER" -rpcpassword="$NODE_RPC_PASS" \
  -fallbackfee=0.0002 >/dev/null

# wait for RPC
BCLI(){ docker exec node bitcoin-cli -regtest -rpcuser="$NODE_RPC_USER" -rpcpassword="$NODE_RPC_PASS" "$@"; }
echo -n "[*] node: waiting for RPC "
for _ in $(seq 1 30); do BCLI getblockchaininfo >/dev/null 2>&1 && break; echo -n .; sleep 1; done; echo

echo "[*] node: creating and funding the 'sovereign' wallet (regtest, fake coins)"
BCLI createwallet "sovereign" >/dev/null 2>&1 || BCLI loadwallet "sovereign" >/dev/null 2>&1 || true
ADDR="$(BCLI -rpcwallet=sovereign getnewaddress)"
BLOCKS="$(BCLI getblockcount)"
if [ "$BLOCKS" -lt 101 ]; then BCLI generatetoaddress 101 "$ADDR" >/dev/null; fi
BAL="$(BCLI -rpcwallet=sovereign getbalance)"

cat <<EOF

[+] node ready.
    IP            : $NODE_IP        (Bitcoin Core, regtest)
    RPC (EXPOSED) : http://$NODE_IP:$RPCPORT   user=$NODE_RPC_USER pass=$NODE_RPC_PASS   <-- deliberately weak
    wallet        : sovereign, balance ~$BAL (regtest, no real value)
    module        : docs/12-secure-your-node.md  (find it, drain it, then harden it)

    Brand: $BRAND_SITE  |  $BRAND_GITHUB
EOF
