#!/usr/bin/env bash
# 73-mitm-swap.sh - run a full BTC/xBTC swap through a HOSTILE relay (attacks/swap-relay/hostile-relay.py)
# and show the swap is not broken by it. The hostile relay forwards genuine events but also injects a
# forged copy of each (and can drop a fraction, via DROP=). The swap driver is sovereign-swap's lab_e2e
# test, pointed at the hostile relay instead of the honest one.
#
# Expected (FORGE=1, DROP=0): the swap still settles - forged events fail the receiver's event
# signature/id check and are dropped, so a MITM cannot impersonate, alter an offer, or redirect funds.
# With a high DROP the swap stalls and both sides refund (the safe outcome, not a loss); that path needs
# many blocks and is not asserted here.
#
# Prereqs: verified node binaries in dev/build/nodes (fetch-nodes.sh), macvlan up (70-swap-relay.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../lab.conf"
[ -f "$HERE/../lab.local.conf" ] && source "$HERE/../lab.local.conf" || true

SRC="${SWAP_SRC:-$HERE/../../sovereign-swap}"
NODES_DIR="${NODES_DIR:-$HERE/../../../../build/nodes}"
NET="hacklab-mv"
HOSTILE_IP="${HOSTILE_RELAY_IP:-10.13.37.62}"
E2E_IP="${SWAP_E2E_IP:-10.13.37.64}"
RUST_IMG="rust:1-slim-bookworm"
FORGE="${FORGE:-1}"; DROP="${DROP:-0.0}"

[ -d "$SRC" ] || { echo "sovereign-swap source not found at $SRC; set SWAP_SRC" >&2; exit 1; }
NODES_DIR="$(cd "$NODES_DIR" && pwd)"
BTC_BIN="$(ls "$NODES_DIR"/core/*/bin/bitcoind 2>/dev/null | head -1 || true)"
XBTC_BIN="$(ls "$NODES_DIR"/knots/*/bin/bitcoind 2>/dev/null | head -1 || true)"
[ -x "$BTC_BIN" ] && [ -x "$XBTC_BIN" ] || { echo "node binaries missing under $NODES_DIR" >&2; exit 1; }
BTC_IN="/nodes/${BTC_BIN#"$NODES_DIR"/}"; XBTC_IN="/nodes/${XBTC_BIN#"$NODES_DIR"/}"
docker network inspect "$NET" >/dev/null 2>&1 || { echo "macvlan $NET missing (run 70-swap-relay.sh first)" >&2; exit 1; }

echo "[*] mitm: building the hostile relay image"
tmp="$(mktemp -d)"; cp "$HERE/../attacks/swap-relay/hostile-relay.py" "$tmp/"
cat > "$tmp/Dockerfile" <<DOCKER
FROM python:3-slim
RUN pip install --no-cache-dir websockets >/dev/null
COPY hostile-relay.py /hostile-relay.py
ENTRYPOINT ["python3","/hostile-relay.py"]
DOCKER
docker build -q -t hostile-relay:lab "$tmp" >/dev/null; rm -rf "$tmp"

echo "[*] mitm: starting hostile relay at $HOSTILE_IP:7777 (FORGE=$FORGE DROP=$DROP)"
docker rm -f hostile-relay >/dev/null 2>&1 || true
docker run -d --name hostile-relay --network "$NET" --ip "$HOSTILE_IP" \
  -e RELAY_BIND="0.0.0.0:7777" -e FORGE="$FORGE" -e DROP="$DROP" hostile-relay:lab >/dev/null
sleep 2
docker logs hostile-relay 2>&1 | tail -1

cleanup() { docker rm -f hostile-relay >/dev/null 2>&1 || true; }
trap cleanup EXIT

VOLS="-v $SRC:/src -w /src -v sovereign-swap-cargo:/usr/local/cargo/registry -v sovereign-swap-target:/target -e CARGO_TARGET_DIR=/target"
echo "[*] mitm: (1/2) compiling lab_e2e (host network)"
# shellcheck disable=SC2086
docker run --rm --network host $VOLS "$RUST_IMG" sh -c 'cargo test --locked --release --test lab_e2e --no-run' >/dev/null

echo "[*] mitm: (2/2) running the swap through the hostile relay ws://$HOSTILE_IP:7777/"
# shellcheck disable=SC2086
docker run --rm --network "$NET" --ip "$E2E_IP" $VOLS \
  -v "$NODES_DIR":/nodes:ro \
  -e RELAY="ws://$HOSTILE_IP:7777/" -e BTC_BITCOIND="$BTC_IN" -e XBTC_BITCOIND="$XBTC_IN" \
  "$RUST_IMG" sh -c 'cargo test --locked --release --offline --test lab_e2e -- --nocapture --test-threads=1'

echo "[*] mitm: forged events injected by the relay = $(docker logs hostile-relay 2>&1 | grep -c 'forged #' || true) (all dropped by the receiver). A 'LAB_E2E_OK' above means the MITM did not break the swap."
