#!/usr/bin/env python3
"""Publish a non-swap kind; the allowlist must block it."""
import json, os, time
from websocket import create_connection

RELAY = os.environ.get("RELAY", "ws://10.13.37.61:7777")
# The pubkey must be a real curve point or the relay rejects the event at parse, before the kind
# check; secp256k1's generator x-coordinate is a valid x-only key. kind=1 then reaches the allowlist.
GX = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
ws = create_connection(RELAY, timeout=10)
ws.send(json.dumps(["EVENT", {"id": "00" * 32, "pubkey": GX, "created_at": int(time.time()),
                              "kind": 1, "tags": [], "content": "spam", "sig": "22" * 64}]))
print("relay replied:", ws.recv())
ws.close()
