#!/usr/bin/env python3
"""Flood the relay with valid events and report how many are accepted vs rate-limited."""
import json, os, sys, time
from websocket import create_connection

RELAY = os.environ.get("RELAY", "ws://10.13.37.61:7777")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 500

# A pre-signed event is not needed to measure throttling: the relay checks the per-connection rate
# limit before it verifies the signature, so an EVENT that merely PARSES is enough to exercise the
# limiter. The one field the relay validates at parse is the pubkey, which must be a real curve
# point; we use secp256k1's generator x-coordinate (a valid x-only key). The id and sig stay bogus,
# so a frame that passes the limiter then fails verification ("bad id or signature"), while frames
# past the per-minute allowance come back "rate-limited". Hardened => most rate-limited; open => none.
GX = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
event = {"id": "00" * 32, "pubkey": GX, "created_at": int(time.time()),
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
