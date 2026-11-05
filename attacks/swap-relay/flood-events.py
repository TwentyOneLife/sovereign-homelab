#!/usr/bin/env python3
"""Flood the relay with valid events and report how many are accepted vs rate-limited."""
import json, os, sys, time
from websocket import create_connection

RELAY = os.environ.get("RELAY", "ws://10.13.37.61:7777")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 500

# A pre-signed kind-4859 event is not needed to measure throttling: the relay rate-limits before it
# verifies, so a syntactically valid EVENT frame is enough to exercise the limiter. We send a
# minimal (and intentionally unverifiable) event; expect either "rate-limited" or a verify failure.
event = {"id": "00" * 32, "pubkey": "11" * 32, "created_at": int(time.time()),
         "kind": 4859, "tags": [], "content": "", "sig": "22" * 64}
ws = create_connection(RELAY, timeout=10)
accepted = limited = other = 0
start = time.time()
for _ in range(N):
    ws.send(json.dumps(["EVENT", event]))
    try:
        reply = json.loads(ws.recv())
        if reply[0] == "OK" and reply[2]:
            accepted += 1
        elif "rate-limited" in (reply[3] if len(reply) > 3 else ""):
            limited += 1
        else:
            other += 1
    except Exception:
        break
dt = time.time() - start
print(f"sent {N} in {dt:.1f}s: accepted={accepted} rate_limited={limited} other_rejected={other}")
ws.close()
