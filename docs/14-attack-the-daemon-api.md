# 14. Attack the sovereign-swap daemon API

The [sovereign-swap](https://github.com/TwentyOneLife/sovereign-swap) client daemon (design 0009, M4a)
runs the swap engine and exposes a small HTTP+JSON API for a GUI. That API is a new attack surface, so
this module attacks it before a GUI is built on top.

The daemon is **loopback-only** and **token-guarded** by design, so the real adversaries are not a
remote host but:
- a **malicious local web page** (a site the user visits that tries to POST to `127.0.0.1` - CSRF);
- a **malicious local process**.

Both are stopped by the same thing: every route needs the bearer token written to the data dir
(mode 600), which a web page cannot read and a stranger cannot guess.

## The target

```sh
bash builder/75-daemon-fuzz.sh       # builds the daemon, runs it loopback-only in a container,
                                     # fuzzes its API from inside (localhost), leaves it up
# then prove it is not reachable from another host, from Kali:
#   nc -z -w3 10.13.37.65 8787       # must be REFUSED
docker rm -f swap-daemon             # clean up
```

## What is checked

| Check | Why |
|---|---|
| no token / wrong token / token-in-query -> 401 | auth is mandatory on every route (the CSRF defense) |
| write routes (PUT/POST) refused without the token | a web page cannot drive the daemon |
| non-JSON body -> 400 | the parser refuses garbage |
| oversized body -> 413 | the request is size-capped (no unbounded buffer) |
| bad settings (injection in a field, non-ws relay, out-of-range conf) -> 422 | authoritative validation with field reasons |
| bad offers (dust, out-of-band price, min>amount) -> 422 | the daemon validation layer (design 0009 layer 2) |
| malformed types (unknown enum, negative u64, string-for-number) -> 400 | the deserializer rejects them before validation |
| non-finite price refused (400 or 422) | never accepted, at whichever layer catches it |
| path-traversal id, unknown method, unknown route -> 404 | nothing is mistaken for a file; no method confusion |
| daemon still alive after the whole battery | no input crashes or hangs it |

## Measured results (2026-11-05, lab)

- **Local API fuzz (`api-fuzz.py`): 22/22 pass.** Every unauthenticated request is `401`, every bad
  body is refused (`400`/`422`) with no `500` and no acceptance, and the daemon is still up at the end.
- **Loopback-only, from Kali:** the daemon container is pingable but `10.13.37.65:8787` is
  **Connection refused** - the API binds `127.0.0.1` only and is not reachable from another host. The
  daemon binary also refuses a non-loopback `SWAP_API_BIND` outright.

## Notes / improvements

- A non-finite price (`1e999`) is caught at the JSON layer (`400`) before the `is_finite()` validation
  (`422`); both refuse it. The validation check stays as defence in depth for any finite-but-insane
  value that parses.
- This module tests the API surface. When the GUI exists (M4b), add a click-through that confirms the
  client-side validation (disabled-until-valid, live "you receive") matches what the daemon enforces,
  so the two layers cannot drift.
- Engine wiring (publish to relays, drive swaps) is the next M4a step; once in, extend the fuzz to the
  `/offers/{id}/take` and `/swaps/{id}` routes and the SSE `/events` stream.
