#!/usr/bin/env bash
# 72-swap-e2e.sh - carry a REAL BTC/xBTC swap over the lab relay. Runs sovereign-swap's `lab_e2e`
# integration test: two engines discover each other and swap over ws://$SWAP_RELAY_IP:7777, settling
# on two regtest nodes (Bitcoin Core + Knots BLAKE2b) spawned as child processes INSIDE the runner
# container (bound to localhost, no node port exposed). The only lab-net traffic is the WebSocket to
# the relay, so the isolation gate is untouched.
#
# Two docker runs, because the lab net has no internet:
#   1. host network  - `cargo test --no-run` compiles the test (fetches crates), warming the shared
#                      cargo/target volumes.
#   2. lab macvlan   - the same test runs --offline against the relay; nodes come up inside.
#
# Prereqs: the relay is up (70-swap-relay.sh) and the verified node binaries exist (dev/build/nodes,
# produced by sovereign-swap/scripts/fetch-nodes.sh). Set NODES_DIR to override their location.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../lab.conf"
[ -f "$HERE/../lab.local.conf" ] && source "$HERE/../lab.local.conf" || true

SRC="${SWAP_SRC:-$HERE/../../sovereign-swap}"
NODES_DIR="${NODES_DIR:-$HERE/../../../../build/nodes}"
NET="hacklab-mv"
E2E_IP="${SWAP_E2E_IP:-10.13.37.64}"
RUST_IMG="rust:1-slim-bookworm"
RELAY_URL="ws://${SWAP_RELAY_IP}:${SWAP_RELAY_PORT}/"

[ -d "$SRC" ] || { echo "sovereign-swap source not found at $SRC; set SWAP_SRC" >&2; exit 1; }
NODES_DIR="$(cd "$NODES_DIR" && pwd)"
BTC_BIN="$(ls "$NODES_DIR"/core/*/bin/bitcoind 2>/dev/null | head -1 || true)"
XBTC_BIN="$(ls "$NODES_DIR"/knots/*/bin/bitcoind 2>/dev/null | head -1 || true)"
[ -x "$BTC_BIN" ] && [ -x "$XBTC_BIN" ] || {
  echo "node binaries missing under $NODES_DIR (run sovereign-swap/scripts/fetch-nodes.sh)" >&2; exit 1; }
# Paths as the runner container will see them (NODES_DIR mounted at /nodes).
BTC_IN="/nodes/${BTC_BIN#"$NODES_DIR"/}"
XBTC_IN="/nodes/${XBTC_BIN#"$NODES_DIR"/}"

docker network inspect "$NET" >/dev/null 2>&1 || { echo "macvlan $NET missing (run 30-web.sh / 70-swap-relay.sh first)" >&2; exit 1; }

VOLS="-v $SRC:/src -w /src -v sovereign-swap-cargo:/usr/local/cargo/registry -v sovereign-swap-target:/target -e CARGO_TARGET_DIR=/target"

echo "[*] swap-e2e: (1/2) compiling the lab_e2e test (host network, internet)"
# shellcheck disable=SC2086
docker run --rm --network host $VOLS "$RUST_IMG" \
  sh -c 'cargo test --locked --release --test lab_e2e --no-run' >/dev/null

echo "[*] swap-e2e: (2/2) running the swap over $RELAY_URL (lab macvlan $E2E_IP, no internet)"
# shellcheck disable=SC2086
docker run --rm --network "$NET" --ip "$E2E_IP" $VOLS \
  -v "$NODES_DIR":/nodes:ro \
  -e RELAY="$RELAY_URL" -e BTC_BITCOIND="$BTC_IN" -e XBTC_BITCOIND="$XBTC_IN" \
  "$RUST_IMG" \
  sh -c 'cargo test --locked --release --offline --test lab_e2e -- --nocapture --test-threads=1'

echo "[*] swap-e2e: done. A line 'LAB_E2E_OK: swap settled ...' above means the relay carried a real swap."
