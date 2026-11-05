#!/usr/bin/env bash
# 74-privacy.sh - what can a passive relay observer learn from a swap? Starts attacks/swap-relay/
# passive-observer.py subscribed to the honest relay, runs a real swap (72-swap-e2e.sh) in its capture
# window, and prints the observer's verdict. Expected: PASS - every event's content is opaque
# ciphertext, so the observer sees no amount, address, or identity, only throwaway routing keys.
#
# Prereqs: honest relay up at $SWAP_RELAY_IP (70-swap-relay.sh), verified node binaries (fetch-nodes.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../lab.conf"
[ -f "$HERE/../lab.local.conf" ] && source "$HERE/../lab.local.conf" || true

NET="hacklab-mv"
OBS_IP="${OBSERVER_IP:-10.13.37.63}"
RELAY_URL="ws://${SWAP_RELAY_IP}:${SWAP_RELAY_PORT}/"
DURATION="${DURATION:-30}"

docker network inspect "$NET" >/dev/null 2>&1 || { echo "macvlan $NET missing (run 70-swap-relay.sh first)" >&2; exit 1; }

echo "[*] privacy: building the observer image"
tmp="$(mktemp -d)"; cp "$HERE/../attacks/swap-relay/passive-observer.py" "$tmp/"
cat > "$tmp/Dockerfile" <<DOCKER
FROM python:3-slim
RUN pip install --no-cache-dir websocket-client >/dev/null
COPY passive-observer.py /passive-observer.py
ENTRYPOINT ["python3","/passive-observer.py"]
DOCKER
docker build -q -t swap-observer:lab "$tmp" >/dev/null; rm -rf "$tmp"

cleanup() { docker rm -f swap-observer >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[*] privacy: starting passive observer at $OBS_IP (subscribes to $RELAY_URL for ${DURATION}s)"
docker rm -f swap-observer >/dev/null 2>&1 || true
docker run -d --name swap-observer --network "$NET" --ip "$OBS_IP" \
  -e RELAY="$RELAY_URL" -e DURATION="$DURATION" swap-observer:lab >/dev/null
sleep 2  # let the REQ subscription register before the swap publishes

echo "[*] privacy: running a swap in the capture window"
SWAP_E2E_IP="${SWAP_E2E_IP:-10.13.37.64}" bash "$HERE/72-swap-e2e.sh" 2>&1 | grep -E "LAB_E2E_OK|FAILED|stuck" || true

echo "[*] privacy: waiting for the observer to finish its window"
docker wait swap-observer >/dev/null 2>&1 || true
echo "----- observer report -----"
docker logs swap-observer 2>&1
echo "---------------------------"
