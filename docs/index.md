---
title: "Hack a Network - the Sovereign Homelab course"
---

# Hack a Network

A guided, hands-on path through the Sovereign Homelab: **learn to attack your own network so you can
defend it.** Thirteen small modules, each teaching one technique with exact steps, then the control that
stops it. Work them in order on your isolated lab; every target is a VM or container you own on
`10.13.37.0/24`.

> Attack in order to defend. Every offensive step here has a paired **Defense** and a **"prove the fix"**
> re-test. That pairing is the whole point of the course.

New here? Build the lab first (see the [`builder/`](https://github.com/TwentyOneLife/sovereign-homelab/tree/main/builder)
directory), then start at module 00. Every default name, IP and credential lives in one file,
[`lab.conf`](https://github.com/TwentyOneLife/sovereign-homelab/blob/main/lab.conf); because the lab is
fully isolated, those defaults are safe to keep.

## The path

| # | Module | Target(s) | You learn (attack -> defense) |
|---|---|---|---|
| 00 | [Map the network](00-network-map.md) | whole /24 | host discovery -> segmentation, isolation |
| 01 | [Service enumeration](01-enumeration.md) | msf2 | version/service enum -> minimise + patch, SMB2, host fw |
| 02 | [First foothold](02-foothold.md) | msf2 | exploit + ssh brute -> patch, key auth, fail2ban |
| 03 | [Web: SQL injection](03-web-sqli-dvwa.md) | DVWA | manual + sqlmap SQLi, crack hashes -> parameterised queries |
| 04 | [Web: modern app](04-web-juiceshop.md) | Juice Shop | OWASP Top 10 challenges -> authz, validation, CSP |
| 05 | [Password attacks](05-password-attacks.md) | msf2/blue | hydra/nxc + john/hashcat -> MFA, lockout, strong passphrase |
| 06 | [Linux privesc + harden](06-linux-privesc-blue.md) | blue | linpeas/sudo/SUID -> least privilege, then re-attack |
| 07 | [AD recon](07-ad-recon.md) | hacklab.local | BloodHound map -> tiering, no svc in DA, LAPS |
| 08 | [AD escalation](08-ad-escalation.md) | win-cli -> win-dc | kerberoast/DCSync/PtH -> gMSA, tiering, prove path gone |
| 09 | [The loot](09-loot-exfil.md) | win-cli | find + exfil the flags -> disk encryption, offline seed |
| 10 | [Wi-Fi opener (simulated)](10-wifi-wpa.md) | virtual radio | WPA2 handshake crack -> WPA3, long passphrase |
| 11 | [Blue-team capstone](11-blue-capstone.md) | all | chain 00-09, then harden and measure what stops |
| 12 | [**Secure your sovereign node**](12-secure-your-node.md) | node | the flagship: harden a self-hosted Bitcoin node end to end |

## How to work a module

1. **Reset first.** Each module says which snapshot to start from:
   `virsh -c qemu:///system snapshot-revert <vm> clean-baseline` (Windows: shut down first). Some targets
   are off by default: `virsh -c qemu:///system start <vm>`.
2. **Follow the numbered steps** from Kali (`10.13.37.10`). Each has the command, what it does, and what
   you should see.
3. **Do the Defense section** and its "prove the fix" re-test. This is where the learning sticks.
4. **Capture the flag** and note what you did. Keeping a short write-up per module, what you ran, what you
   saw, and what the fix changed, is the fastest way to make it stick.

## Scope and safety (binding)

Everything here targets **VMs and containers you own** on the isolated `10.13.37.0/24` network, for
**education**. Never point any tool at your real LAN, the internet, or anyone else's systems; doing so is
illegal in most places. The "bank/crypto/secrets" in the lab are planted `FLAG-...{}` files, never real
keys.

## For instructors and classes

Each module is self-contained and resettable, so students can retry freely. Suggested pacing: 00-02 as a
first session (recon to foothold on the gentlest target), then web (03-04), then creds + Linux (05-06),
then AD (07-09), the Wi-Fi opener (10), the capstone (11), and the node-hardening flagship (12) as
graduation.

## Scenario file template (for new modules)

Goal, Target(s), Difficulty, Est. time, Prereqs, **Start from** (snapshot to revert to), MITRE ATT&CK
refs, **Steps** (numbered, exact commands, "what you should see"), **Defense** (the control +
"prove the fix"), **Flags/evidence**, **Cleanup/reset**.
