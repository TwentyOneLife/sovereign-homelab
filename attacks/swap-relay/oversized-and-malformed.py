#!/usr/bin/env python3
"""Send an oversized frame and malformed JSON; the relay must reject them and stay up."""
import json, os, time
from websocket import create_connection, ABNF

RELAY = os.environ.get("RELAY", "ws://10.13.37.61:7777")
ws = create_connection(RELAY, timeout=10, max_size=None)
# A frame far above the relay's event-size cap.
ws.send(json.dumps(["EVENT", {"content": "A" * (2 * 1024 * 1024), "kind": 4859}]))
# Junk that is not JSON.
ws.send("this is not json")
# A valid-looking REQ afterwards proves the connection survived.
ws.send(json.dumps(["REQ", "probe", {"kinds": [4859]}]))
ws.settimeout(3)
survived = False
try:
    while True:
        msg = json.loads(ws.recv())
        if msg[0] == "EOSE":
            survived = True
            break
except Exception:
    pass
print("relay survived oversized+malformed and answered REQ" if survived else "no EOSE (relay may have closed)")
ws.close()
