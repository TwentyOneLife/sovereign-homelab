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
| event flood | none `rate-limited` | most `rate-limited` after the per-minute allowance |
| oversized / malformed | relay survives, answers REQ | relay survives, answers REQ |
| wrong kind | `OK ... false ... kind not allowed` | `OK ... false ... kind not allowed` |
| connection flood | all accepted (cap ~ host sockets) | accepted plateaus at the connection cap |

Record the difference. That difference is the control doing its job.

Two of these do **not** vary with `MODE`, by design, and that is the finding to record:

- **The kind allowlist is unconditional.** `MODE=open` relaxes only the numeric limits (event bytes,
  connections, events/min, store cap); it does not relax the allowlist, which is not operator
  config. A wrong kind is blocked in both modes, which is the stronger property: it is not a knob an
  operator can turn off.
- **Oversized/malformed is rejected at parse in both modes.** The frame-size cap (set at the
  WebSocket layer) and parse rejection both fire regardless of `MODE`; the malformed event here (no
  pubkey) never reaches the store. This proves robustness, not a size-cap delta. To show the size
  cap itself you would send a *valid, large* event.

> **One trap the first run exposed.** The relay validates event *structure* at parse, before the
> rate-limit and kind checks, and the one field it checks is the `pubkey` (it must be a real
> secp256k1 point). An attack that sends a bogus pubkey is rejected as `unparseable` and never
> reaches the control it means to test, so it would look identical in both modes. The scripts here
> use secp256k1's generator x-coordinate (a valid x-only key) with a bogus id and signature: enough
> to pass parse and exercise the limiter / allowlist, which is what we are measuring.

## Carry a real swap over the relay (and under attack)

Taking the relay down is one axis; the other is proving it **carries a real swap**. `72-swap-e2e.sh`
runs sovereign-swap's `lab_e2e` integration test: two engines discover each other and complete a full
BTC/xBTC atomic swap over `ws://$SWAP_RELAY_IP:7777`, settling on two regtest nodes (Bitcoin Core +
Knots BLAKE2b) spawned as localhost children inside the runner container, so no node port is exposed
and isolation holds.

```sh
MODE=hardened bash builder/70-swap-relay.sh    # relay up, shipped controls on
bash builder/72-swap-e2e.sh                    # expect: LAB_E2E_OK: swap settled ...

# the payoff - a real swap while the relay is flooded:
#   on Kali, loop flood-events.py against the relay, then:
bash builder/72-swap-e2e.sh                    # still settles; the flood is rate-limited, the swap is not
```

A legitimate swap uses its own low-rate connections, so the per-connection rate limit throttles the
attacker without touching it. That is design 0007 made visible: abuse is expensive and ineffective,
the swap completes, and no coin is ever at risk.

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

## Measured results (2026-11-05, lab)

Run against the relay at `ws://10.13.37.61:7777` from Kali (`10.13.37.10`), relay built from
`sovereign-swap` `main`. Both node binaries verified (hash + GPG) by `fetch-nodes.sh`: Bitcoin Core
v31.1.0, Bitcoin Knots v29.4.3.knots20260508.

| Attack | MODE=open | MODE=hardened |
|---|---|---|
| `flood-events.py 1000` | `accepted=0 rate_limited=0 other_rejected=1000` | `accepted=0 rate_limited=760 other_rejected=240` |
| `oversized-and-malformed.py` | survived, answered REQ | survived, answered REQ |
| `wrong-kind.py` | `blocked: kind not allowed` | `blocked: kind not allowed` |
| connection cap (600 concurrent ws) | `accepted_concurrent=600` | `accepted_concurrent=512` |

- **Rate limit:** hardened throttles 760 of 1000 (the 240 "other" passed the per-minute allowance and
  then failed signature verification, as expected for the bogus-sig flood); open throttles none.
- **Connection cap:** hardened plateaus at 512 (the shipped cap); open accepts all 600.
- **Allowlist / oversized:** unconditional, identical in both modes (see the notes above).

Real swap over the relay (`72-swap-e2e.sh`, hardened): `LAB_E2E_OK: swap settled ... in 8 rounds`.
Repeated with a sustained `flood-events.py 2000` loop running on Kali (attacker saw
`rate_limited=1760` per round): the swap still settled in 8 rounds. The flood is throttled; the swap
is not.
