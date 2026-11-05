#!/usr/bin/env bash
# 75-daemon-fuzz.sh - adversarial test of the sovereign-swap client daemon's local API (module 14).
# Builds the daemon, runs it loopback-only inside a lab container, and fuzzes its API from inside that
# container (the malicious-local-process / CSRF case). Leaves the container up at $DAEMON_IP so the
# caller can then prove from Kali that the port is NOT reachable off the host (loopback-only). Clean up
# with: docker rm -f swap-daemon
#
# Prereqs: a sovereign-swap checkout; macvlan up (70-swap-relay.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../lab.conf"
[ -f "$HERE/../lab.local.conf" ] && source "$HERE/../lab.local.conf" || true

SRC="${SWAP_SRC:-$HERE/../../sovereign-swap}"
NET="hacklab-mv"
DAEMON_IP="${DAEMON_IP:-10.13.37.65}"
RUST_IMG="rust:1-slim-bookworm"
[ -d "$SRC" ] || { echo "sovereign-swap source not found at $SRC" >&2; exit 1; }
docker network inspect "$NET" >/dev/null 2>&1 || { echo "macvlan $NET missing (run 70-swap-relay.sh first)" >&2; exit 1; }

echo "[*] daemon-fuzz: building the daemon binary"
docker run --rm --network host -v "$SRC":/src -w /src \
  -v sovereign-swap-cargo:/usr/local/cargo/registry -v sovereign-swap-target:/target -e CARGO_TARGET_DIR=/target \
  "$RUST_IMG" sh -c 'cargo build --locked --release --bin sovereign-swap-daemon' >/dev/null
# The target volume is inside docker; copy the binary out through a throwaway container.
tmp="$(mktemp -d)"
docker run --rm -v sovereign-swap-target:/target -v "$tmp":/out "$RUST_IMG" \
  sh -c 'cp /target/release/sovereign-swap-daemon /out/'
cp "$HERE/../attacks/daemon/api-fuzz.py" "$tmp/"
cat > "$tmp/Dockerfile" <<DOCKER
FROM debian:bookworm-slim
RUN apt-get -qq update && apt-get -qq install -y python3 >/dev/null && rm -rf /var/lib/apt/lists/*
COPY sovereign-swap-daemon /usr/local/bin/
COPY api-fuzz.py /api-fuzz.py
ENV SWAP_DATA_DIR=/data SWAP_API_BIND=127.0.0.1:8787
ENTRYPOINT ["sovereign-swap-daemon"]
DOCKER
docker build -q -t swap-daemon:lab "$tmp" >/dev/null; rm -rf "$tmp"

echo "[*] daemon-fuzz: starting the daemon (loopback-only) at container $DAEMON_IP"
docker rm -f swap-daemon >/dev/null 2>&1 || true
docker run -d --name swap-daemon --network "$NET" --ip "$DAEMON_IP" swap-daemon:lab >/dev/null
# Wait for the token file (written on first run) to confirm the daemon is up.
for _ in $(seq 1 20); do
  docker exec swap-daemon sh -c 'test -s /data/token' 2>/dev/null && break
  sleep 0.5
done

echo "[*] daemon-fuzz: fuzzing the API from inside the container (localhost)"
docker exec swap-daemon sh -c 'API_TOKEN=$(cat /data/token) python3 /api-fuzz.py'
rc=$?

echo
echo "[*] daemon-fuzz: local fuzz exit=$rc. Container left up at $DAEMON_IP:8787 for the Kali"
echo "    reachability check (loopback-only means it must be REFUSED from another host)."
echo "    When done:  docker rm -f swap-daemon"
exit $rc
