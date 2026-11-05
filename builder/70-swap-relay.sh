#!/usr/bin/env bash
# 70-swap-relay.sh - stand up the module-13 target: the sovereign-swap relay, a hardened Nostr relay
# for swap messages (TwentyOneLife/sovereign-swap). It runs as a Docker macvlan container on the
# isolated lab bridge, reachable by Kali, with no route off the lab. The relay holds no funds and
# no keys; the module attacks its AVAILABILITY, not any value.
#
# MODE selects the controls, so you can attack with them off then on and compare:
#   MODE=hardened (default) - the shipped defaults (kind allowlist, size cap, rate limit, caps).
#   MODE=open               - the controls relaxed to near-nothing, to see the attacks bite.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../lab.conf"
[ -f "$HERE/../lab.local.conf" ] && source "$HERE/../lab.local.conf" || true

MODE="${MODE:-hardened}"
NET="hacklab-mv"
SRC="${SWAP_SRC:-$HERE/../../sovereign-swap}"   # path to a sovereign-swap checkout
IMAGE="sovereign-swap-relay:lab"

[ -d "$SRC" ] || { echo "sovereign-swap source not found at $SRC; set SWAP_SRC=/path/to/sovereign-swap" >&2; exit 1; }

echo "[*] swap-relay: building the relay binary from $SRC"
docker run --rm -v "$SRC":/src -w /src rust:1-slim-bookworm \
  sh -c 'cargo build --release --bin sovereign-swap-relay' >/dev/null

# A tiny runtime image carrying just the binary.
BIN="$SRC/target/release/sovereign-swap-relay"
[ -x "$BIN" ] || { echo "build did not produce $BIN" >&2; exit 1; }
tmp="$(mktemp -d)"; cp "$BIN" "$tmp/"; cat > "$tmp/Dockerfile" <<DOCKER
FROM debian:bookworm-slim
COPY sovereign-swap-relay /usr/local/bin/
EXPOSE $SWAP_RELAY_PORT
ENTRYPOINT ["/usr/local/bin/sovereign-swap-relay"]
DOCKER
docker build -q -t "$IMAGE" "$tmp" >/dev/null; rm -rf "$tmp"

if [ "$MODE" = "open" ]; then
  LIMITS=(-e RELAY_MAX_EVENT_BYTES=67108864 -e RELAY_MAX_CONNECTIONS=100000 -e RELAY_MAX_EVENTS_PER_MIN=100000000 -e RELAY_STORE_CAP=100000000)
  echo "[*] swap-relay: MODE=open - controls relaxed (attacks should bite)"
else
  LIMITS=()  # the shipped hardened defaults
  echo "[*] swap-relay: MODE=hardened - shipped controls on"
fi

docker network inspect "$NET" >/dev/null 2>&1 || { echo "run 30-web.sh first (macvlan $NET missing)" >&2; exit 1; }
echo "[*] swap-relay: (re)starting at $SWAP_RELAY_IP:$SWAP_RELAY_PORT"
docker rm -f swap-relay >/dev/null 2>&1 || true
docker run -d --name swap-relay --network "$NET" --ip "$SWAP_RELAY_IP" --restart unless-stopped \
  -e RELAY_BIND="0.0.0.0:$SWAP_RELAY_PORT" "${LIMITS[@]}" "$IMAGE" >/dev/null
echo "[*] swap-relay: up. ws://$SWAP_RELAY_IP:$SWAP_RELAY_PORT/  (MODE=$MODE)"
