#!/usr/bin/env python3
"""A MITM / hostile Nostr relay for module 13.

It speaks just enough NIP-01 to carry a swap (store, REQ-replay, EVENT-fanout), but it is adversarial:
for every genuine event it relays, it also injects a FORGED copy, and it can DROP a fraction of what
passes through. The point is to show the swap protocol does not trust the relay.

  - FORGE (default on): each event is re-broadcast with its `content` tampered (one byte flipped). The
    receiver recomputes the event id and checks the Schnorr signature *before* anything else
    (sovereign-swap src/routing.rs: `event.verify()` gates `receive()`), so a tampered copy is dropped
    at the event layer. Even a copy re-signed under the relay's own key would carry an envelope whose
    ML-DSA + Schnorr + AES-GCM auth fails. A forged message cannot impersonate a party, alter an offer,
    or redirect funds.
  - DROP (default 0.0): withhold a fraction of events. A withheld swap message cannot cause loss; the
    swap simply fails to progress and both sides refund after their timelocks. A high rate stalls the
    swap into that refund path, which is the safe outcome.

Env: RELAY_BIND (default 0.0.0.0:7777), FORGE (1/0, default 1), DROP (0.0-1.0, default 0.0).

A test tool for our own isolated lab only. It holds nothing and proves nothing about value; it probes
message-plane integrity.
"""
import asyncio
import json
import os
import random

import websockets

FORGE = os.environ.get("FORGE", "1") == "1"
DROP = float(os.environ.get("DROP", "0.0"))

clients = set()
store = []
forged = 0


def forge(ev):
    """Return a tampered copy: flip the first hex char of `content`. The event id no longer matches
    the content, so the receiver's signature/id check rejects it."""
    f = dict(ev)
    c = f.get("content", "")
    f["content"] = (("1" if c[0] != "1" else "0") + c[1:]) if c else "deadbeef"
    return f


async def fanout(msg):
    data = json.dumps(msg)
    for c in list(clients):
        try:
            await c.send(data)
        except Exception:
            clients.discard(c)


async def handler(ws):
    clients.add(ws)
    try:
        async for raw in ws:
            try:
                v = json.loads(raw)
            except Exception:
                continue
            if not isinstance(v, list) or not v:
                continue
            if v[0] == "REQ":
                sub = v[1] if len(v) > 1 else "s"
                for ev in store:
                    await ws.send(json.dumps(["EVENT", sub, ev]))
                await ws.send(json.dumps(["EOSE", sub]))
            elif v[0] == "EVENT":
                ev = v[1]
                store.append(ev)
                await ws.send(json.dumps(["OK", ev.get("id", ""), True, ""]))  # mimic an honest relay
                if random.random() >= DROP:
                    await fanout(["EVENT", "s", ev])  # the genuine event
                if FORGE:
                    global forged
                    forged += 1
                    print(f"[hostile-relay] forged #{forged} (will be rejected)", flush=True)
                    await fanout(["EVENT", "s", forge(ev)])  # the forged copy, which must be rejected
    finally:
        clients.discard(ws)


async def main():
    host, port = os.environ.get("RELAY_BIND", "0.0.0.0:7777").split(":")
    async with websockets.serve(handler, host, int(port), max_size=8 * 1024 * 1024):
        print(f"[hostile-relay] up on {host}:{port}  FORGE={FORGE} DROP={DROP}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
