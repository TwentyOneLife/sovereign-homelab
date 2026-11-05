#!/usr/bin/env bash
# Open many simultaneous TCP connections to exhaust the relay's connection slots. With the cap on,
# new connections past the limit are dropped; with it off, the relay keeps accepting until the host
# runs out of sockets. Ctrl-C to stop; watch the relay stay responsive to a normal client either way.
set -u
HOST="${1:-10.13.37.61}"; PORT="${2:-7777}"; COUNT="${3:-2000}"
echo "opening $COUNT connections to $HOST:$PORT ..."
for i in $(seq 1 "$COUNT"); do
  (exec 3<>"/dev/tcp/$HOST/$PORT"; sleep 120) &
done
echo "held open; run a normal client against the relay to see whether it still answers."
wait
