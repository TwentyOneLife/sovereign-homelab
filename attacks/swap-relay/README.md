# Attack scripts for the sovereign-swap relay (lab only)

These run from Kali against the relay stood up by `builder/70-swap-relay.sh`, on the isolated lab
network only. The relay holds no funds and no keys, so these test its **availability**, not any
value. Set `RELAY=ws://10.13.37.61:7777` (your `SWAP_RELAY_IP`).

Python scripts need `websocket-client` (`pip install websocket-client`, present on recent Kali).

| Script | Attack | Control that blunts it |
|---|---|---|
| `flood-events.py` | publish events as fast as possible | per-connection rate limit |
| `oversized-and-malformed.py` | a huge frame and junk JSON | message-size cap, event verification |
| `wrong-kind.py` | publish a non-swap event kind | kind allowlist |
| `connection-flood.sh` | open many simultaneous connections | connection cap |

Run each with the relay in `MODE=open` then `MODE=hardened` (redeploy with
`MODE=open bash builder/70-swap-relay.sh`) and compare, as module 13 describes.
