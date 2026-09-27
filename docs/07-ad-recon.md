---
title: "Scenario 07 - Active Directory recon (authenticated enumeration + mapping)"
---

# Scenario 07 - Active Directory recon (authenticated enumeration + mapping)

> **Ethics + scope.** Everything here runs against **VMs we own** on the **isolated a local model net
> `10.13.37.0/24`**. There is no route to the real LAN or the internet. This is defensive-security
> education: we attack our own Active Directory so we learn to spot and stop it. Every offensive step
> below is paired with the control that defeats it. Doing any of this to a network you do not own is a
> crime.

You already hold **one ordinary domain account** (`HACKLAB\j.mueller`, a normal user). The whole point
of this module is to show how much of a domain a *single low-privilege account* can map, entirely with
read-only, "boring" LDAP/SMB queries that most networks never notice. By the end you will have drawn the
graph and **found the deliberately-broken thing**: a service account sitting in **Domain Admins**, with a
clickable shortest path to full domain compromise.

---

## Header

| | |
|---|---|
| **Goal** | With one low-priv domain user, enumerate `hacklab.local` (users, shares, policy), collect it into BloodHound, and map the shortest path(s) to Domain Admin. Find that `svc-backup` is over-privileged. |
| **Target** | `win-dc` 10.13.37.50 (DC + DNS for `hacklab.local`), `win-cli` 10.13.37.51 (domain-joined Win11). |
| **Difficulty** | Beginner -> intermediate (first AD module). |
| **Est. time** | 60-90 min. |
| **Prereqs** | Kali reachable on a local model (`10.13.37.10`); the AD pair booted; the creds `HACKLAB\j.mueller : Hacklab2026!`. No admin rights needed. Comfortable in a Linux terminal. |
| **Start-from** | Revert both Windows VMs to `clean-baseline` (see Cleanup), boot win-dc, then win-cli. This module makes **no changes** to the targets, but starting clean keeps runs deterministic. |

### MITRE ATT&CK coverage
- **Discovery / Domain Account** - T1087.002
- **Discovery / Domain Groups** - T1069.002
- **Discovery / Network Share** - T1135
- **Discovery / Password Policy** - T1201
- **Discovery / Remote System** - T1018
- **Credential Access / Kerberoasting** - T1558.003 (find the roastable accounts here; crack them in 08)
- **Credential Access / AS-REP Roasting** - T1558.004
- (BloodHound itself is a mapping tool; the collection it does is the Discovery techniques above.)

---

## Setup (once per session, on Kali)

Run these from a Kali terminal. They are **local Kali setup only** - no traffic to the targets yet.

**S1. Confirm you can see the lab and detach the NAT NIC (clean isolation).**
```
ip -br a                       # eth0 should be 10.13.37.10/24
ping -c1 10.13.37.50           # DC should answer
```
- *What it does:* sanity-checks that Kali is on the isolated net and the DC is up.
- *What you should see:* `10.13.37.10/24` on eth0 and a reply from `.50`. If the DC does not answer, it is
  probably still booting (Windows takes a minute) or off - `virsh -c qemu:///system start win-dc`.

**S2. Point Kali's name resolution at the DC.** AD tooling wants to resolve `hacklab.local` and
`win-dc.hacklab.local`. The DC **is** the DNS server. Two safe ways - do **both**, they are belt-and-braces:
```
# a) static host entries so names always resolve even without DNS
echo '10.13.37.50  win-dc.hacklab.local win-dc hacklab.local' | sudo tee -a /etc/hosts
echo '10.13.37.51  win-cli.hacklab.local win-cli'            | sudo tee -a /etc/hosts

# b) (optional) use the DC as a resolver for this session
#   NetworkManager may rewrite /etc/resolv.conf; the /etc/hosts entries above are the reliable path.
```
- *What it does:* lets `bloodhound-python`, `ldapsearch`, and impacket find the DC by name.
- *What you should see:* `getent hosts win-dc.hacklab.local` returns `10.13.37.50`.
- *Note:* most tools below also accept `-dc-ip 10.13.37.50` / `-ns 10.13.37.50`, so you can skip DNS
  entirely if you prefer. We show both styles.

**S3. Set two shell variables so the commands read cleanly.**
```
export DC=10.13.37.50
export DOM=hacklab.local
export U=j.mueller
export P='Hacklab2026!'          # single-quoted: the ! must not be shell-expanded
```

---

## Steps (attacker view) - all as the low-priv user `j.mueller`

### 1. Prove the credentials work (netexec / SMB)
```
nxc smb $DC -u $U -p "$P"
```
- *What it does:* authenticates to SMB on the DC. `nxc` is `netexec` (the maintained `crackmapexec` fork).
- *What you should see:* a line ending in **`[+] hacklab.local\j.mueller:Hacklab2026!`** (green `[+]`).
  It also prints the host name (`WIN-DC`), the domain, the OS build, and whether SMB signing is required.
  A **red `[-]`** means the creds or the target are wrong - fix before continuing.
- *Note the "signing" field.* On a DC signing is required; on `win-cli` it may not be - remember that for
  relay attacks (scenario 01 / responder).

### 2. Enumerate domain users (T1087.002)
```
nxc smb $DC -u $U -p "$P" --users
```
- *What it does:* pulls the full domain user list over SMB/SAMR as an authenticated user.
- *What you should see:* the account list including **`Administrator`, `j.mueller`, `svc-backup`**, plus
  built-ins (`krbtgt`, `Guest`). Note last-logon and `badPwdCount` columns - useful before any spraying so
  you do not lock accounts out. **Write down every account name**; you will feed them to Kerberos next.

Save a clean username list for later:
```
nxc smb $DC -u $U -p "$P" --users | awk '/hacklab.local\\/{print $NF}' | sort -u > ~/users.txt
# simpler + reliable alternative:
nxc smb $DC -u $U -p "$P" --users 2>/dev/null | grep -oP '(?<=hacklab.local\\)\S+' | sort -u > ~/users.txt
cat ~/users.txt
```

### 3. Enumerate shares (T1135)
```
nxc smb $DC -u $U -p "$P" --shares
```
- *What it does:* lists SMB shares on the DC and this user's READ/WRITE access to each.
- *What you should see:* `NETLOGON`, `SYSVOL` (both readable by any domain user - normal), plus admin
  shares (`ADMIN$`, `C$`) that `j.mueller` should **not** be able to read. If a non-default share is
  world-readable, that is loot. Repeat against the client:
```
nxc smb 10.13.37.51 -u $U -p "$P" --shares
```
  On `win-cli` this is how you would later reach `C:\Users\Public\Documents` (the FLAG loot) if the share
  perms allow it - we take the flags properly in scenario 08.

### 4. Read the password policy (T1201)
```
nxc smb $DC -u $U -p "$P" --pass-pol
```
- *What it does:* dumps the domain password policy (min length, complexity, lockout threshold, lockout
  window).
- *What you should see:* the lockout threshold especially - if it is **0 (no lockout)** you can spray/guess
  freely; if it is low (e.g. 5) you must throttle. Record it. This single number decides whether the
  Kerberos/spray steps below are safe to run at speed.

### 5. Enumerate over LDAP directly (ldapsearch)
netexec is convenient, but you should see the raw directory at least once - it is where all of this data
actually lives.
```
# a) anonymous "who am I talking to" - the naming context (often allowed even unauthenticated)
ldapsearch -x -H ldap://$DC -s base -b '' namingContexts

# b) authenticated: list every user's name + group memberships
ldapsearch -x -H ldap://$DC -D "$U@$DOM" -w "$P" \
  -b 'DC=hacklab,DC=local' '(objectClass=user)' sAMAccountName memberOf
```
- *What it does:* (a) confirms LDAP is reachable and shows the directory root; (b) is an authenticated
  query for every user object and the groups each belongs to.
- *What you should see:* in (b), scroll to **`svc-backup`** and look at its `memberOf` - it will list
  **`CN=Domain Admins,CN=Users,DC=hacklab,DC=local`**. That is the flaw, visible in one query.

Target the over-privileged group directly:
```
ldapsearch -x -H ldap://$DC -D "$U@$DOM" -w "$P" \
  -b 'CN=Domain Admins,CN=Users,DC=hacklab,DC=local' member
```
- *What you should see:* `member:` lines for `Administrator` **and `svc-backup`**. A *service* account in
  Domain Admins is the deliberately-planted weakness this whole journey turns on.

Find accounts flagged **"do not require Kerberos preauth"** (AS-REP roastable, T1558.004) straight from LDAP:
```
ldapsearch -x -H ldap://$DC -D "$U@$DOM" -w "$P" -b 'DC=hacklab,DC=local' \
  '(&(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=4194304))' sAMAccountName
```
- *What you should see:* any account with the `DONT_REQUIRE_PREAUTH` bit set. If the query returns nothing,
  the domain has none - good hygiene on that axis; we still show the roasting technique in step 7.

### 6. Enumerate with impacket (cross-check + get the domain SID)
```
impacket-lookupsid "$DOM/$U:$P"@$DC | tee ~/lookupsid.txt
```
- *What it does:* brute-walks RIDs to enumerate domain principals via MS-LSAT, and prints the **domain
  SID**.
- *What you should see:* the domain SID (`S-1-5-21-...`) followed by every user/group with its RID. This
  corroborates the netexec user list and gives you SIDs (handy for advanced attacks). `Domain Admins` is
  always RID 512 - note which accounts map into it.

### 7. Find Kerberos-attackable accounts (T1558.003 / T1558.004)
These two impacket scripts do **not** need admin - any domain user can ask the DC for these tickets. We
only *find and fetch* here; cracking happens in scenario 08.

**7a. Kerberoastable accounts (accounts with a Service Principal Name):**
```
impacket-GetUserSPNs "$DOM/$U:$P" -dc-ip $DC
```
- *What it does:* lists every account that has an SPN registered (these are exactly the accounts whose
  service ticket you can request and crack offline).
- *What you should see:* a table of `ServicePrincipalName / Name / MemberOf / PasswordLastSet`. If
  **`svc-backup`** appears here (it has an SPN) it is kerberoastable **and** in Domain Admins - the jackpot
  target. To actually request and save the crackable hashes, add `-request`:
```
impacket-GetUserSPNs "$DOM/$U:$P" -dc-ip $DC -request -outputfile ~/kerberoast.hash
cat ~/kerberoast.hash        # a $krb5tgs$23$... blob per SPN account
```
  Keep `~/kerberoast.hash`; scenario 08 Path B cracks it. If `GetUserSPNs` returns an empty table, no
  account has an SPN - note that and rely on Path A (direct svc-backup creds) in 08.

**7b. AS-REP roastable accounts (no Kerberos pre-auth):**
```
# try every known user - this needs no password, only the username list from step 2
impacket-GetNPUsers "$DOM/" -no-pass -usersfile ~/users.txt -dc-ip $DC -format hashcat -outputfile ~/asrep.hash
cat ~/asrep.hash             # a $krb5asrep$23$... blob for any preauth-disabled account
```
- *What it does:* asks the DC for an AS-REP for each user; any account with pre-auth disabled hands back a
  crackable hash **without valid credentials**.
- *What you should see:* one hash per vulnerable account, or "no entries" if the domain requires pre-auth
  everywhere (the healthy default). Either result is a finding - record it.

### 8. Collect the graph with the BloodHound Python collector
This is the centrepiece. One authenticated run pulls users, groups, ACLs, sessions, and trusts into JSON
that BloodHound turns into a clickable attack graph.
```
mkdir -p ~/bh && cd ~/bh
bloodhound-python -u $U -p "$P" -d $DOM -dc win-dc.hacklab.local -c all -ns 10.13.37.50
```
- *What it does:* `-c all` runs every collection method against the DC named by `-dc`, resolving via the
  nameserver `-ns` (the DC). It writes several `*_hacklab.local.json` files in the current directory.
- *What you should see:* progress lines ("Found N users", "Found N groups", "Done in ...") and, on success,
  a set of JSON files:
```
ls -1 ~/bh/*.json
# 20260927_*_users.json  *_groups.json  *_computers.json  *_domains.json  *_gpos.json  *_ous.json ...
```
- *If it errors on DNS:* the `-ns 10.13.37.50` flag and the `/etc/hosts` entry from S2 both fix name
  resolution; make sure at least one is in place. `-dc win-dc.hacklab.local` must be the FQDN, not the IP.

### 9. Start BloodHound and import
BloodHound's GUI reads a local **neo4j** database (already on this Kali).
```
sudo neo4j start            # start the graph DB; first run wait ~15s
#   (browse http://localhost:7474 once to set/confirm the neo4j password; default neo4j/neo4j -> change)
bloodhound &                # launch the BloodHound GUI (community edition)
```
- *What it does:* starts the database, then the analysis UI.
- *What you should see:* the BloodHound login screen; sign in with the neo4j creds. Then **Upload Data**
  (or drag the folder) and select all the JSON files from `~/bh/`. A toast confirms the import counts.
- *Note (version drift):* if this Kali ships **BloodHound CE**, ingestion is via the browser UI's
  *Administration -> File Ingest* and neo4j is managed by its docker/`bloodhound` service - the collector
  output is the same JSON. Either way, you load the `~/bh/*.json` files. If `neo4j` is not found, it is a
  bundled service; `bloodhound` will tell you what it expects.

### 10. Analyse - find the path to Domain Admin
In the BloodHound GUI:
1. Click the **search** box, type `svc-backup`, select the user node.
2. On the node, open **Node Info** -> confirm **Member of: Domain Admins**.
3. Use the **Pathfinding** control (the two-dot icon): set **start = j.mueller**, **end = Domain Admins**
   (or the `DOMAIN ADMINS@HACKLAB.LOCAL` group). BloodHound draws the **shortest path**.
4. Run the built-in query **"Shortest Paths to Domain Admins"** (Analysis tab / pre-built queries).
5. Right-click the `svc-backup` -> `Domain Admins` edge -> **Help** to read exactly what the abuse is and,
   crucially, the **"remediation"** text.
- *What you should see:* a graph where `svc-backup` has a **MemberOf** edge into **Domain Admins**. Because
  it is also a *service* account (and, if step 7a hit, kerberoastable), the path from "any user who can
  read/guess/roast svc-backup" to full domain control is one hop. Mark this node **High Value**.
- *Takeaway to write down:* the fastest domain compromise here does not need a single exploit - just a
  misplaced group membership that a read-only account could see.

---

## Defense (harden, then re-test)

Recon is mostly read-only and cannot be fully "blocked" - a legitimate domain user can always query the
directory. The defensive goal is to **remove what recon finds** and to **detect the collection**.

- **AD tiering / no service accounts in Domain Admins (the main fix).** `svc-backup` must not be a Domain
  Admin. Put service accounts in a dedicated OU with only the rights they need. Reserve Tier-0 groups
  (Domain/Enterprise Admins) for a handful of dedicated admin accounts that log on nowhere else.
- **Least privilege + gMSA.** Replace the standing service account with a **Group Managed Service Account**
  (long, auto-rotated, unknown-to-humans password) - covered hands-on in scenario 08's defence.
- **Kill Kerberoast/AS-REP exposure.** Ensure no account has "do not require pre-auth"; give any SPN
  account a 25+ char random password so an offline crack is infeasible (again, gMSA does this for free).
- **LDAP signing + channel binding.** Require LDAP signing and enable LDAP channel binding on DCs so
  unsigned/relayed LDAP is refused (Group Policy: *Domain controller: LDAP server signing requirements =
  Require signing*).
- **Monitoring + honeytokens.** Watch for the tell-tale collection: mass SAMR/LDAP enumeration, a burst of
  Kerberos **TGS requests with RC4 (etype 23)** from one host (Event ID **4769**) is the Kerberoast
  signature. Plant a **honeytoken** account - a fake service account with an SPN and a decoy password that
  is never used legitimately; any TGS request or logon for it is a high-fidelity alarm.

### Prove the fix
- **Group membership:** after remediation, re-run step 5's `Domain Admins` query -
  `ldapsearch ... -b 'CN=Domain Admins,...' member` should list **only** the real admin account(s), not
  `svc-backup`.
- **Graph:** re-run steps 8-10. In BloodHound, **"Shortest Paths to Domain Admins"** should no longer
  route through `svc-backup` (this is the exact before/after you demonstrate in scenario 08).
- **Kerberoast surface:** re-run step 7a; the SPN account is gone or now uncrackable (25+ char random).
- **Detection:** trigger step 7a again on purpose and confirm the DC logs **4769** with RC4 encryption for
  the target/honeytoken, and that your monitor fired.

---

## Wrap-up

**Flags / evidence collected**
- `~/users.txt` - the domain user list (T1087.002 output).
- `~/lookupsid.txt` - domain SID + RIDs.
- `~/kerberoast.hash` and/or `~/asrep.hash` - Kerberos hashes staged for scenario 08 (may be empty if the
  domain is clean on that axis).
- `~/bh/*.json` + the BloodHound graph - the mapped domain.
- **The finding:** `svc-backup` is a member of **Domain Admins**, with a shortest path from a normal user
  to full domain compromise. (The actual FLAG-BANK / FLAG-SEED / FLAG-CREDS loot lives on win-cli and is
  captured in **scenario 08**, once we escalate.)

**Cleanup / reset** (this module changes nothing on the targets, but reset keeps runs deterministic)
```
# shut the VMs down FIRST, then revert (external UEFI snapshots)
virsh -c qemu:///system shutdown win-cli ; virsh -c qemu:///system shutdown win-dc
#   wait for both to power off (virsh ... list --all shows "shut off"), then:
virsh -c qemu:///system snapshot-revert win-dc  clean-baseline
virsh -c qemu:///system snapshot-revert win-cli clean-baseline
# stop the local graph DB when done:
sudo neo4j stop
```
On Kali, the `/etc/hosts` lines you added in S2 are harmless to leave, or remove them by editing
`/etc/hosts`.

**Next:** scenario **08 - AD escalation**: turn this map into Domain Admin (Path A: use `svc-backup`
directly; Path B: kerberoast it), grab the loot flags off win-cli, then remediate and prove the path
disappears.

**Go deeper: ** Research: In scenario 07, my bloodhound-python run fails with a DNS/timeout error against win-dc - what do I check?
