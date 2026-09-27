<div align="center">

# Sovereign Homelab

### Secure your homelab, secure your node.

An isolated, reproducible hacking lab and a hands-on course that teaches you to **attack your own network so you can defend it**. Built for self-hosters and Bitcoin node operators: you cannot be sovereign if the network your node runs on can be owned.

[Course](https://twentyonelife.github.io/sovereign-homelab/) · [Build the lab](builder/) · [twentyone.life](https://twentyone.life) · [GitHub](https://github.com/TwentyOneLife)

</div>

---

## What this is

A complete, self-contained lab you build on your own machine with free, open tools, plus a 13-part journey called **"Hack a Network"**. Each module teaches one technique with exact, copy-paste steps, then the **defence that stops it** and a **"prove the fix"** re-test. You attack a Kali box against deliberately vulnerable targets: Linux servers, web apps, a small Windows Active Directory domain, and a **Bitcoin node** you learn to harden.

- **Attack in order to defend.** Every offensive step is paired with the control that stops it.
- **Isolated by design.** The lab sits on its own network with no route to your real LAN or the internet.
- **Reproducible, not a black box.** You build it from scripts and verify every image yourself.
- **On theme.** The flagship module hardens a self-hosted node, the way a sovereign operator should.

## Who it is for

Beginners who want to actually understand how their home network and node get attacked, node operators and self-hosters who want to harden their setup, and anyone running a security class who needs a ready-made, resettable lab.

## Ethics and scope (read first)

Everything here targets **virtual machines you own**, on an **isolated network**, for **education**. Never point these tools at any system you do not own and have explicit permission to test. Doing so is illegal in most places. The "secrets" in the lab (bank statements, wallet seeds, passwords) are planted fakes, never real keys.

## Quick start

1. **Build the lab** (a KVM/Linux host): see [`builder/`](builder/). It creates the isolated network, downloads and verifies the base images, and stands up every VM. About one to two hours, mostly hands-off.
2. **Start the course**: open the [Sovereign Homelab course](https://twentyonelife.github.io/sovereign-homelab/) and begin at module 00.
3. **Break, learn, reset.** Every target reverts from a clean snapshot in seconds.

Default usernames and passwords ship in [`lab.conf`](lab.conf). Because the lab is fully isolated, the defaults are safe to keep; change them in that one file if you prefer, and the builder uses your values everywhere.

## The journey

`00` map the network · `01` enumeration · `02` foothold · `03` web SQLi · `04` web (Juice Shop) · `05` password attacks · `06` Linux privesc and harden · `07` Active Directory recon · `08` AD escalation · `09` the loot · `10` Wi-Fi (simulated) · `11` blue-team capstone · `12` **secure your sovereign node**.

## Repository layout

- [`builder/`](builder/) - scripts that build the whole lab on your host (network, images, VMs, config).
- [`docs/`](docs/) - the course modules; also the VitePress source (`docs/.vitepress/`) for the published site.
- [`lab.conf`](lab.conf) - your lab's names, IPs and credentials in one place.

## Built with, and for, TwentyOne.Life

This is part of [TwentyOne.Life](https://twentyone.life): tools for running your own Bitcoin infrastructure, focused on Bitcoin Blake2b (BitcoinB2B). Follow on Nostr and Lightning at `TwentyOneLife@primal.net`.

## Supporting this work

Donations in **BitcoinB2B**, the coin of the Bitcoin Blake2b chain:

```
1BH665bXvEqSuoWQUihiQiPpt2BqpzrgGD
```

**Read this before sending.** Bitcoin Blake2b shares Bitcoin's address format and its genesis block, so this is a perfectly valid Bitcoin address as well, and nothing about it says which chain it belongs to. Send from a Bitcoin Blake2b wallet. Bitcoin sent to it is a different asset and is not a donation to this project, whatever your wallet shows you. There is no way to make that visible in the address itself; it is a property of the fork, not an oversight.

Lightning tips (paid in Bitcoin on the SHA-256 chain) are welcome at `TwentyOneLife@primal.net`.

## License

MIT, see [`LICENSE`](LICENSE). The lab targets deliberately vulnerable software; that software keeps its own licenses.
