---
title: "Hack a Network - 00: Network Map (host discovery)"
---

# Hack a Network - 00: Network Map (host discovery)

> Part of the **"Hack a Network"** journey. Everything here runs against **VMs and containers we own**
> on the **isolated `10.13.37.0/24` lab network**, which has no route to any real network or the
> internet. This is defensive-security self-study: we attack our own machines to learn to defend them.

| | |
|---|---|
| **Goal** | Discover every live host on `10.13.37.0/24` from Kali and turn the results into the target map the rest of the journey uses. |
| **Target(s)** | The whole lab subnet `10.13.37.0/24` (msf2 `.20` is the first thing we go after later). |
| **Difficulty** | Beginner |
| **Est. time** | 30-40 min |
| **Prereqs** | None. This is the first module. You only need to be logged in to `kali` (`kali` / `kali`). |
| **Start from** | `virsh -c qemu:///system start kali` (attacker), then `virsh -c qemu:///system start msf2` (first target is off by default). Windows and web targets can stay off for now. |

**MITRE ATT&CK**
- Reconnaissance / Active Scanning - **T1595**
- Discovery / Network Service Discovery - **T1046**
- Discovery / Remote System Discovery - **T1018**

---

## Background: why we map first

An attacker who lands on a network does not yet know what is on it. Before touching any single machine
they build a picture: which IP addresses answer, and roughly what each one is. That picture is the
**map**. Every later module (enumeration, foothold) starts from it. We build the same map here, against
our own lab, so you learn to read it, and so you understand why hiding a network from this step is so
hard.

All commands below run **from `kali`** (a terminal on the Kali desktop). Kali is `10.13.37.10`. Its lab
NIC is `eth0`.

> If Kali still has its second (NAT) NIC attached for updates, detach it before an exercise so scans
> stay strictly inside the lab:
> `virsh -c qemu:///system detach-interface kali network --mac <your-kali-nat-nic-mac> --live`

---

## Steps

### 1. Confirm your own address and interface

```
ip -br a
```

Shows each interface and its IP in one line each.

**What you should see:** a line `eth0 ... UP 10.13.37.10/24`. That confirms you are on the lab subnet as
`.10`. If `eth0` has no `10.13.37.10`, stop and fix the Kali NIC before scanning (see the lab builder).

### 2. Ping sweep the whole subnet with nmap

```
nmap -sn 10.13.37.0/24
```

`-sn` is a "no port scan" host-discovery sweep: nmap decides which hosts are up (ARP on the local link,
plus ICMP), without touching any service. This is the fastest, most reliable first pass.

**What you should see:** a short report, one block per live host, ending with `Host is up`. On the local
link nmap also prints the MAC address and often a vendor string like `QEMU virtual NIC`. Expect the lab
gateway `.1`, yourself `.10`, and `.20` (msf2, which you just started). Other addresses appear only if
those VMs are running.

### 3. Cross-check with an ARP scan

```
sudo arp-scan --interface=eth0 --localnet
```

Sends raw ARP requests to every address on the local subnet. ARP works at layer 2, below IP, so it finds
hosts even when they ignore ping. This is why an isolated LAN cannot really "hide" from a machine already
on it.

**What you should see:** a table of `IP  MAC  vendor` rows, then a count of responding hosts. The live
lab IPs should match what nmap found in step 2. QEMU/KVM MACs start with `52:54:00`.

### 4. Cross-check again with netdiscover

```
sudo netdiscover -P -i eth0 -r 10.13.37.0/24
```

`netdiscover` is another ARP-based sweeper. `-P` prints a plain table and exits (instead of running
interactively), `-i` picks the interface, `-r` sets the range. Running a second, independent tool is good
practice: if two tools agree, you trust the map.

**What you should see:** the same set of live IPs and MACs as arp-scan. Agreement across `nmap -sn`,
`arp-scan`, and `netdiscover` means your host list is solid.

### 5. Write down the map

Save the live list so later modules can reuse it:

```
nmap -sn 10.13.37.0/24 -oG - | awk '/Up$/{print $2}' | sort -V | tee ~/hacklab-hosts.txt
```

Re-runs the sweep in "greppable" output, pulls just the IPs that are `Up`, sorts them, and saves them to
`~/hacklab-hosts.txt` (while also printing them).

**What you should see:** a clean list of IP addresses, one per line, and the same file on disk. This file
is your map for module 01 and 02.

---

## Reading the map: which host is which

Match the IPs you found against the known lab roster. (Only the powered-on VMs show up, so your list is
a subset of this table.)

| IP | Host | Role | Notes |
|---|---|---|---|
| `10.13.37.1` | lab gateway | libvirt host on the a local model bridge | Always up. Not a target. |
| `10.13.37.10` | **kali** | the attacker (you) | Do not scan yourself as a target. |
| `10.13.37.20` | **msf2** | Metasploitable 2 (Linux) | The first real target. Off by default; you started it. |
| `10.13.37.34` | **dvwa** | web target (`:80`) | Web-app module. |
| `10.13.37.35` | **juiceshop** | web target (`:3000`) | Web-app module. |
| `10.13.37.40` | **blue** | Debian hardening target | Used later as the "hardened" comparison box. |
| `10.13.37.50` | **win-dc** | Active Directory DC `hacklab.local` | Windows/AD module. |
| `10.13.37.51` | **win-cli** | Win11 desktop, domain-joined | Windows/AD module. |
| `10.13.37.60` | **node** | Bitcoin node (regtest, RPC `:18443`) | The flagship "secure your node" module. Off by default. |

**How to tell them apart without logging in:** the IP itself is the strongest clue in this lab because
addressing is static and planned (host `.1`, kali `.10`, targets `.20+`). Vendor/MAC (`52:54:00...`)
confirms a VM. In a real, unplanned network you would lean on the next module (service/version
enumeration) to identify a host by the services it runs, for example port `3389` open suggests Windows,
`445` suggests SMB, `3000` suggests a Node web app.

---

## Defense: segmentation and isolation

**The control:** host discovery from *inside* a subnet is essentially unstoppable, ARP is fundamental to
the LAN working at all. So the defensive lesson is not "block the scan", it is **control who and what
shares a subnet in the first place**.

- **Network segmentation / VLANs.** Put untrusted or IoT devices on their own segment so a foothold on
  one does not reveal, or reach, the trusted machines. A router that only forwards between segments on
  explicit rules turns one flat "everything sees everything" LAN into several small blast radii.
- **Client isolation** on guest/Wi-Fi networks stops one connected client from even ARP-ing another.
- **An isolated lab is the same principle taken to the extreme,** and it is why this whole exercise is
  safe. Our a local model libvirt network has **no `<forward>` element at all**, so the VMs cannot route off
  the subnet to the real LAN (Bitcoin node, a device on your real home LAN `192.168.1.1`) or the internet. That is what lets
  us run loud, aggressive scans with zero risk to anything real.

**How to apply it here:** the segmentation is already applied, that is the lab design. You can prove the
boundary holds rather than build it.

**Prove the fix (isolation gate):** from a target guest, confirm it can reach the lab host but nothing
beyond it. From `msf2` (via console, or the SSH container in the lab builder):

```
ping -c1 10.13.37.1        # lab host - should succeed
ping -c1 192.168.1.1     # real a device on your real home LAN - should fail
ping -c1 1.1.1.1           # internet - should fail
```

**What you should see:** the first ping replies; the other two return `Network is unreachable`. That is
the segmentation boundary doing its job: the scan you ran can only ever see the lab.

---

## Flags / evidence captured
- `~/hacklab-hosts.txt` on Kali: the confirmed list of live lab IPs (your map for modules 01 and 02).
- The host-to-role table above, filled in for the machines that were powered on.

## Cleanup / reset
- Nothing on the targets was changed (discovery is read-only), so no revert is needed.
- Leave `msf2` running if you are going straight into module 01. Otherwise:
  `virsh -c qemu:///system snapshot-revert msf2 clean-baseline` then `virsh -c qemu:///system shutdown msf2`.

## Go deeper
Stuck or curious? Ask the lab tutor: Research: why does arp-scan find hosts that don't answer ping?
or just run a local model for an interactive session.
