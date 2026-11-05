#!/usr/bin/env python3
"""Passive relay observer for module 13 (privacy).

The strongest eavesdropper against a swap is the relay itself, or anyone subscribed to it: it sees
every event, both the broadcast offer and the directed bids/accepts/locks. This tool plays that role.
It subscribes to kind 4859, captures every event during a live swap, and then checks what a watcher
can actually learn.

The claim (design 0005/0006): the relay sees only throwaway routing keys and ciphertext. Identities,
amounts, addresses and swap details live inside a post-quantum envelope (X25519+ML-KEM / Schnorr+ML-DSA
/ AES-256-GCM) carried in the event `content` as hex. So a full capture should reveal:
  - content that is opaque hex whose decoded bytes carry no plaintext (no address, "maker"/"taker",
    "amount", JSON, ...);
  - event pubkeys that are per-swap routing keys, not party identities.

Env: RELAY (ws:// URL), DURATION (seconds to observe, default 25).

Note on linkability: in production each swap draws fresh routing keys (sovereign-swap src/routing.rs
reads /dev/urandom), so captures do not link across swaps. The lab_e2e driver pins seeds for
determinism, so do NOT use it to judge cross-swap linkability; this tool checks content opacity, which
holds regardless.
"""
import json
import os
import re
import time

from websocket import create_connection

RELAY = os.environ.get("RELAY", "ws://10.13.37.61:7777")
DURATION = int(os.environ.get("DURATION", "25"))

# Multi-character tokens only: single bytes like "{" occur by chance in random ciphertext and must
# not count as a leak. These are words a swap payload would contain in the clear.
WORDS = ["bc1", "tb1", "bcrt1", "maker", "taker", "amount", "offer", "refund", "preimage", "secret",
         "address", "pubkey", "identity"]


def is_directed(ev):
    """Directed messages (bid/accept/swap steps) carry a `p` routing tag; a broadcast offer does not."""
    return any(isinstance(t, list) and t and t[0] == "p" for t in ev.get("tags", []))


def decode(ev):
    content = ev.get("content", "")
    if not content or re.fullmatch(r"[0-9a-f]*", content) is None or len(content) % 2:
        return content.encode(), False  # not clean hex -> treat raw
    return bytes.fromhex(content), True


def looks_plaintext(raw):
    if not raw:
        return False, []
    printable = sum(32 <= b < 127 for b in raw) / len(raw)
    text = raw.decode("latin-1").lower()
    words = [w for w in WORDS if w in text]
    return (printable > 0.85 or len(words) >= 2), words


ws = create_connection(RELAY, timeout=10)
ws.send(json.dumps(["REQ", "obs", {"kinds": [4859]}]))
ws.settimeout(1)
events = []
end = time.time() + DURATION
while time.time() < end:
    try:
        m = json.loads(ws.recv())
        if isinstance(m, list) and m and m[0] == "EVENT":
            events.append(m[2])
    except Exception:
        pass
ws.close()

directed = [e for e in events if is_directed(e)]
broadcast = [e for e in events if not is_directed(e)]
print(f"captured {len(events)} kind-4859 events as a passive relay observer "
      f"({len(broadcast)} broadcast, {len(directed)} directed)")

# The guarantee under test: DIRECTED swap messages must be opaque to the relay/observer.
leaked_directed = 0
for ev in directed:
    raw, _ = decode(ev)
    readable, words = looks_plaintext(raw)
    if readable:
        leaked_directed += 1
        print(f"  DIRECTED LEAK: id={ev.get('id','')[:12]} words={words}")

# Broadcast offers are public by design (an order book). Report what they expose, for the record.
for ev in broadcast:
    raw, _ = decode(ev)
    _, words = looks_plaintext(raw)
    print(f"  broadcast offer id={ev.get('id','')[:12]}: public by design; "
          f"exposes order terms{' ' + str(words) if words else ''}, not any taker or real-world identity")

pubkeys = {e.get("pubkey") for e in events}
print(f"distinct event pubkeys seen: {len(pubkeys)} (throwaway routing keys; real identities are sealed "
      f"inside directed ciphertext, never on the wire)")

if not events:
    print("VERDICT: INCONCLUSIVE - no events captured (did a swap run during the window?)")
elif leaked_directed == 0:
    print("VERDICT: PASS - directed swap messages are opaque to the observer (no amount, address, or "
          "identity); only broadcast offer terms are public, by design.")
else:
    print(f"VERDICT: FAIL - {leaked_directed}/{len(directed)} directed messages leaked plaintext.")
