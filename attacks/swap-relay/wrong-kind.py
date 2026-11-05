#!/usr/bin/env python3
"""Publish a non-swap kind; the allowlist must block it."""
import json, os, time
from websocket import create_connection

RELAY = os.environ.get("RELAY", "ws://10.13.37.61:7777")
ws = create_connection(RELAY, timeout=10)
ws.send(json.dumps(["EVENT", {"id": "00" * 32, "pubkey": "11" * 32, "created_at": int(time.time()),
                              "kind": 1, "tags": [], "content": "spam", "sig": "22" * 64}]))
print("relay replied:", ws.recv())
ws.close()
