# 13. Attack the Sovereign Swap Relay

The [sovereign-swap](https://github.com/TwentyOneLife/sovereign-swap) relay carries swap messages
between peers over Nostr. It is **untrusted by design**: it holds no funds and no keys, only
throwaway routing keys and opaque, end-to-end-encrypted events. So you cannot steal from it. What you
can try is to take it **down**, and this module is about making that hard.

> **It cannot cost anyone coins.** A swap interrupted at any point ends in a refund. Knocking a relay
> offline costs traders time, and they switch to another relay. This is why the relay, not the user's
> funds, is the thing we harden, and why there is no "freeze the attacker's money" button: nobody,
> including the relay operator, can touch a user's coins (see *Defend*, below).

## The target

Stand it up on the lab network (from a sovereign-swap checkout beside this repo):

```sh
MODE=hardened bash builder/70-swap-relay.sh    # shipped controls on
# ...attack, observe, then:
MODE=open     bash builder/70-swap-relay.sh    # controls relaxed, attack again, compare
```

It listens at `ws://$SWAP_RELAY_IP:7777/`. From Kali, `export RELAY=ws://10.13.37.61:7777`.

## The controls

| Control | What it stops |
|---|---|
| Kind allowlist (only 4859) | events that are not swap messages |
| Event-size cap | oversized events eating memory |
| Signature + id verification | forged or tampered events |
| Per-connection rate limit | one client flooding events |
| Connection cap | many connections exhausting slots |
| Bounded store + time-to-live | the store growing without end |

## The attacks (run OFF then ON, compare)

From `attacks/swap-relay/` on Kali (`pip install websocket-client`):

```sh
python3 flood-events.py 1000        # accepted vs rate_limited
python3 oversized-and-malformed.py  # relay must survive and still answer a REQ
python3 wrong-kind.py               # must be blocked by the allowlist
bash connection-flood.sh 10.13.37.61 7777 2000   # then check a normal client still gets answered
```

### What you should see

| Attack | MODE=open | MODE=hardened |
|---|---|---|
| event flood | almost all accepted | most `rate-limited` after the per-minute allowance |
| oversized / malformed | may bloat memory | frame refused, connection stays up, REQ still answered |
| wrong kind | stored and served | `OK ... false ... kind not allowed` |
| connection flood | slots fill, host strains | past the cap, new connections dropped; a normal client still answered |

Record the difference. That difference is the control doing its job.

## Defend (and why you cannot "freeze" an attacker)

The sovereign way to punish abuse is to make it **expensive and ineffective**, never to seize money:

- **At the relay**: rate-limit and drop abusive connections and IPs; require a small proof-of-work on
  each message so flooding costs the attacker CPU; keep the kind allowlist and size cap tight. Run
  **several** relays so no one relay is a chokepoint.
- **Between peers**: optional, opt-in reputation from completed swaps, so a griefing key loses
  standing and honest peers refuse it. A forfeitable, time-locked bond is a heavier option.
- **What you must not build**: a switch that freezes a trader's funds pending an email or a message
  to get them back. It cannot work on Bitcoin or Bitcoin Blake2b (no one can freeze another's UTXOs),
  and to even attempt it you would have to take custody of user funds, which turns a sovereign,
  non-custodial tool into a bank with a honeypot and a censor's lever. The design refuses it: coins
  live only in the user's wallet and in swap contracts that resolve to claim-or-refund, and the
  operator holds nothing to freeze.

A denial-of-service attacker can cost the network a little time. They can never cost a trader a coin,
and they can never be punished by taking one.
