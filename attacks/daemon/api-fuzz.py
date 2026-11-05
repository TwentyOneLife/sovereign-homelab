#!/usr/bin/env python3
"""Adversarial tester for the sovereign-swap daemon's local API (design 0009, module 14).

The daemon binds 127.0.0.1 and guards every route with a bearer token, so the real adversaries are a
malicious local web page (CSRF) or a local process, not a remote host. This battery plays them: it
tries to drive the API without the token, to slip bad input past validation, and to crash or hang the
daemon, then checks it is still up. Every check prints PASS/FAIL; a non-zero exit means something got
through.

Env: API_HOST (default 127.0.0.1), API_PORT (default 8787), API_TOKEN (required).
"""
import http.client
import json
import os
import sys

HOST = os.environ.get("API_HOST", "127.0.0.1")
PORT = int(os.environ.get("API_PORT", "8787"))
TOKEN = os.environ.get("API_TOKEN", "")

passed = failed = 0


def call(method, path, token=None, body="", extra_headers=None):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    if extra_headers:
        headers.update(extra_headers)
    conn.request(method, path, body=body, headers=headers)
    r = conn.getresponse()
    data = r.read().decode("latin-1")
    conn.close()
    return r.status, data


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")


# --- auth / CSRF: the token is mandatory on every route ---
check("no token -> 401", call("GET", "/status")[0] == 401)
check("wrong token -> 401", call("GET", "/status", token="deadbeef")[0] == 401)
check("token in query not accepted", call("GET", f"/status?token={TOKEN}")[0] == 401)
check("right token -> 200", call("GET", "/status", token=TOKEN)[0] == 200)
# A write route must also be refused without the token (the CSRF case).
check("PUT /settings no token -> 401", call("PUT", "/settings", body="{}")[0] == 401)
check("POST /offers no token -> 401", call("POST", "/offers", body="{}")[0] == 401)

# --- input validation: bad bodies are refused, never accepted, never a 500 ---
GOOD_SETTINGS = json.dumps({"btc_node": "127.0.0.1:8332", "xbtc_node": "127.0.0.1:8442",
                            "relays": ["ws://a.onion:7777"], "signer": "cold",
                            "btc_conf": 1, "xbtc_conf": 2, "margin_blocks": 2})
check("valid settings -> 200", call("PUT", "/settings", TOKEN, GOOD_SETTINGS)[0] == 200)
check("non-JSON settings -> 400", call("PUT", "/settings", TOKEN, "not json")[0] == 400)

bad_bodies = {
    "injection in node field": {"btc_node": "'; DROP TABLE x;--", "xbtc_node": "127.0.0.1:8442",
                                "relays": [], "signer": "cold", "btc_conf": 1, "xbtc_conf": 2, "margin_blocks": 2},
    "non-ws relay": {"btc_node": "127.0.0.1:8332", "xbtc_node": "127.0.0.1:8442",
                     "relays": ["http://evil"], "signer": "cold", "btc_conf": 1, "xbtc_conf": 2, "margin_blocks": 2},
    "conf out of range": {"btc_node": "127.0.0.1:8332", "xbtc_node": "127.0.0.1:8442",
                          "relays": [], "signer": "cold", "btc_conf": 99999, "xbtc_conf": 2, "margin_blocks": 2},
}
for name, obj in bad_bodies.items():
    code, _ = call("PUT", "/settings", TOKEN, json.dumps(obj))
    check(f"settings: {name} -> 422", code == 422, f"got {code}")

# Offers: dust, out-of-band price, min>amount, bad enum, huge/negative numbers, non-finite price.
bad_offers = {
    "below dust": '{"sell_chain":"xbtc","amount_sat":100,"price":1.0,"min_amount_sat":100}',
    "price out of band": '{"sell_chain":"xbtc","amount_sat":50000000,"price":9.9,"min_amount_sat":50000000}',
    "min above amount": '{"sell_chain":"xbtc","amount_sat":50000000,"price":1.0,"min_amount_sat":99999999999}',
}
for name, body in bad_offers.items():
    code, _ = call("POST", "/offers", TOKEN, body)
    check(f"offer: {name} -> 422", code == 422, f"got {code}")

# A non-finite price is refused either at the JSON layer (serde rejects 1e999 as out-of-range -> 400)
# or at validation (-> 422). Both are correct; what matters is it is never accepted.
nf = '{"sell_chain":"xbtc","amount_sat":50000000,"price":1e999,"min_amount_sat":50000000}'
check("offer: non-finite price refused (400/422)", call("POST", "/offers", TOKEN, nf)[0] in (400, 422))

# Malformed types the deserializer must reject with 400, never 422/200/500.
bad_types = {
    "unknown enum variant": '{"sell_chain":"gold","amount_sat":50000000,"price":1.0,"min_amount_sat":50000000}',
    "negative u64": '{"sell_chain":"xbtc","amount_sat":-1,"price":1.0,"min_amount_sat":1}',
    "string for number": '{"sell_chain":"xbtc","amount_sat":"lots","price":1.0,"min_amount_sat":1}',
}
for name, body in bad_types.items():
    code, _ = call("POST", "/offers", TOKEN, body)
    check(f"offer: {name} -> 400", code == 400, f"got {code}")

# --- path / method abuse ---
check("path traversal id -> 404", call("GET", "/swaps/..%2f..%2f..%2fetc%2fpasswd", TOKEN)[0] == 404)
check("unknown method -> 404", call("TRACE", "/status", TOKEN)[0] == 404)
check("unknown route -> 404", call("GET", "/../secret", TOKEN)[0] == 404)

# --- resilience: after all of the above, the daemon is still up and no check ever saw a 500 ---
check("daemon still alive", call("GET", "/status", TOKEN)[0] == 200)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
