---
title: "Hack a Network - 01: Enumeration (deep service scan of msf2)"
---

# Hack a Network - 01: Enumeration (deep service scan of msf2)

> Part of the **"Hack a Network"** journey. Everything here runs against **VMs we own** on the
> **isolated `10.13.37.0/24` lab network** with no route to any real network or the internet. This is
> defensive-security self-study: we attack our own machine to learn to defend it.

| | |
|---|---|
| **Goal** | Enumerate every service on `msf2` in depth, read the version banners, and list which services look weak. This is the intelligence the foothold module (02) acts on. |
| **Target(s)** | `msf2` - Metasploitable 2, `10.13.37.20`. |
| **Difficulty** | Beginner |
| **Est. time** | 45-60 min |
| **Prereqs** | **Module 00** (you have the host map and know `.20` is msf2). |
| **Start from** | `virsh -c qemu:///system start msf2` (skip if it is already up from module 00). Attacker: `virsh -c qemu:///system start kali`. |

**MITRE ATT&CK**
- Discovery / Network Service Discovery - **T1046**
- Reconnaissance / Active Scanning: Vulnerability Scanning - **T1595.002**
- Reconnaissance / Gather Victim Host Information - **T1592**

---

## Background: from "a host exists" to "here is how it breaks"

Module 00 told us `10.13.37.20` is alive. Enumeration answers the next questions: **what services does it
run, which exact versions, and what is misconfigured or out of date?** The version string is the payload
here. A service banner like `vsftpd 2.3.4` or `UnrealIRCd` is often enough to know, before touching it
again, exactly how it can be exploited. Learning to read these banners is the core skill of this module.

All commands run **from `kali`** against `10.13.37.20`.

---

## Steps

### 1. Full TCP port + version + default-script scan

```
nmap -sV -sC -p- -oN ~/msf2-nmap.txt 10.13.37.20
```

`-p-` scans all 65535 TCP ports (msf2 has services on high ports too, like Tomcat on 8180), `-sV` grabs
the version of each open service, `-sC` runs nmap's safe default scripts (`default` category), and
`-oN` saves a readable copy. This is the single most important command in the module, so let it finish.

**What you should see:** a long list of open ports with versions. On a clean Metasploitable 2 expect,
among others:

| Port | Service | Version nmap reports (typical) |
|---|---|---|
| 21 | ftp | `vsftpd 2.3.4` |
| 22 | ssh | `OpenSSH 4.7p1` |
| 23 | telnet | Linux telnetd |
| 25 | smtp | `Postfix smtpd` |
| 80 | http | `Apache httpd 2.2.8` |
| 139 / 445 | netbios-ssn / microsoft-ds | `Samba smbd 3.x` |
| 3306 | mysql | `MySQL 5.0.51a` |
| 5432 | postgresql | `PostgreSQL DB 8.3` |
| 3632 | distccd | `distccd v1` |
| 8180 | http | Apache Tomcat/Coyote JSP engine |

(plus a VNC service, an IRC daemon, and others). Note the versions, this list is your worksheet.

### 2. Read the versions: spot the weaknesses

You do not need a tool for this step, you need your eyes and the nmap output. For each service ask: *is
this version old, and is it famous for a flaw?* On Metasploitable 2 the standouts are:

- **`vsftpd 2.3.4`** - this exact version shipped, briefly, with a backdoor: a username ending in `:)`
  opens a root shell on port 6200. This is the classic beginner foothold (module 02).
- **`OpenSSH 4.7p1`** - ancient, and (more importantly for us) the accounts use weak/default passwords.
  A brute-force / credential path (module 02).
- **`Samba 3.x`** - old SMB, likely speaks SMBv1, worth deep enumeration (below).
- **`distccd`, Tomcat 8180, the IRC daemon** - each has its own well-known exploit. Good "next targets"
  once you have the basics.

The lesson: **an exposed version number is a roadmap for the attacker.** Every service you can see is a
service that must be patched, restricted, or turned off.

### 3. Enumerate SMB with smbclient (shares, no login)

```
smbclient -L //10.13.37.20/ -N
```

`-L` lists the shares offered by the server, `-N` tries it with no password (a "null session"). If a
server hands over its share list to an anonymous client, that is already a finding.

**What you should see:** a share list including `tmp`, `IPC$`, `ADMIN$`, and a `print$`, with a comment
line naming the Samba version. The null session succeeding at all is the weakness.

### 4. Deep SMB / host enumeration with enum4linux-ng

```
enum4linux-ng -A 10.13.37.20
```

`-A` runs "all simple enumeration": OS info, users, groups, shares, password policy, over SMB/RPC. It is
the modern rewrite of the classic `enum4linux`.

**What you should see:** the Samba version, the workgroup (`WORKGROUP`), a list of local users (you may
see `msfadmin`, `user`, `games`, and others), and often an empty or weak password policy. A full user
list from an unauthenticated attacker is exactly what makes the brute-force path in module 02 realistic.

### 5. Banner-grab individual services with netcat

```
nc -nv 10.13.37.20 21
```

Opens a raw TCP connection to port 21 and prints whatever the service says first, its banner. `-n` skips
DNS, `-v` is verbose. Press `Ctrl-C` to exit. Repeat for other text protocols, for example `25` (SMTP)
and `23` (telnet).

**What you should see:** for port 21, a line like `220 (vsFTPd 2.3.4)`. This confirms the version nmap
guessed, straight from the service's own mouth. Banner grabbing is the manual double-check of automated
version detection.

### 6. Scan the web server (:80) with nikto

```
nikto -h http://10.13.37.20
```

`nikto` is a web-server scanner: it checks the server version, dangerous default files, and known
misconfigurations.

**What you should see:** the Apache 2.2.8 version flagged as outdated, a list of interesting directories
(`/phpMyAdmin/`, `/dav/`, and the vulnerable web apps `/dvwa/`, `/mutillidae/`, `/tikiwiki/`), and
several "OSVDB"/CVE-style findings. Each discovered app is another door, explored in the web modules.

*(Optional, to enumerate hidden web paths:*
`gobuster dir -u http://10.13.37.20 -w /usr/share/seclists/Discovery/Web-Content/common.txt` *, which
brute-forces directory names from a SecLists wordlist.)*

### 7. Check MySQL and PostgreSQL for weak access

```
nxc mysql 10.13.37.20 -u root -p ''
nxc postgres 10.13.37.20 -u postgres -p postgres
```

`nxc` (netexec) tests a login against a service. Here we try the classic weak defaults: MySQL `root` with
an **empty** password, and PostgreSQL `postgres` / `postgres`.

**What you should see:** a `[+]` success line for MySQL `root` with a blank password (Metasploitable
leaves it open), meaning the database is reachable with no real authentication. That is a critical
finding: the database is exposed to the whole network with a trivial login.

---

## Defense: shrink and harden the attack surface

Every finding above comes from a service being **reachable and out of date**. The controls, in order of
impact:

1. **Minimise exposed services.** If a box does not need FTP, telnet, distcc, an IRC daemon, and a second
   Tomcat, do not run them. The service you turn off cannot be enumerated or exploited.
2. **Patch.** Old versions (`vsftpd 2.3.4`, Apache 2.2.8, Samba 3.x) are old *known* holes. On a real
   box, keep packages current. Metasploitable is a frozen 2012 image on purpose and cannot be patched,
   so here we demonstrate the other two controls, which are provable on the box itself.
3. **Host firewall.** Even a service that must run can be limited to the hosts that need it.
4. **Disable SMBv1.** Legacy SMB is a perennial target, turn it off.

### How to apply it (on msf2, provable)

**a) Host firewall - close a service to the network.** Block telnet (port 23) with iptables. On `msf2`
(via console, or the SSH container recipe in the lab builder):

```
sudo iptables -A INPUT -p tcp --dport 23 -j DROP
```

Appends a rule that drops any inbound connection to port 23. (In production you would default-drop and
allow only what is needed; one rule keeps this demo readable.)

**b) Disable SMBv1** in Samba. Edit `/etc/samba/smb.conf`, and in the `[global]` section set:

```
[global]
    server min protocol = SMB2
```

then restart Samba: `sudo /etc/init.d/samba restart`. This refuses the legacy SMBv1 dialect.

### Prove the fix (re-test the attack)

Re-run the relevant enumeration from Kali and confirm it now fails:

```
nc -nv -w3 10.13.37.20 23        # telnet: was open, now the firewall drops it
```

**What you should see:** instead of a banner, the connection hangs then times out (`Ctrl-C` to stop). The
port that answered in step 5's family is now dark from the attacker's side, the firewall rule worked.

For SMBv1, re-run an SMBv1-only probe:

```
nmap --script smb-protocols -p445 10.13.37.20
```

**What you should see:** `SMBv1` no longer listed among the accepted dialects (only `SMB2`+ remain). The
legacy protocol the attacker wanted is gone.

---

## Flags / evidence captured
- `~/msf2-nmap.txt` on Kali: the full port/version report.
- Your weakness worksheet from step 2 (the shortlist of exploitable services), which feeds module 02.
- Evidence of the null SMB session and the open MySQL root login.

## Cleanup / reset
The firewall and Samba edits above change the target, so reset it before the next module so it is back to
its known-vulnerable baseline:

```
virsh -c qemu:///system snapshot-revert msf2 clean-baseline
```

(Windows targets must be shut down before a revert; msf2 can be reverted while running.)

## Go deeper
Research: how do I read an nmap -sV line to decide if a service is exploitable? or run a local model
for an interactive session.
