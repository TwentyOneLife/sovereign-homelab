---
title: "Scenario 04 - Web: OWASP Juice Shop (guided challenges across the OWASP Top 10)"
---

# Scenario 04 - Web: OWASP Juice Shop (guided challenges across the OWASP Top 10)

> **Authorized lab only.** Juice Shop is a container **we own** on the isolated `10.13.37.0/24` hacklab
> net (no route to the real LAN or the internet). Attack our own app to learn to defend it: every
> challenge below is paired with the fix.

| | |
|---|---|
| **Goal** | Solve 5-6 beginner Juice Shop challenges spanning the OWASP Top 10, use the built-in score board to track progress, and state the concrete defense for each class. |
| **Target** | OWASP Juice Shop - `http://10.13.37.35:3000/` (self-register your own account) |
| **Difficulty** | Beginner |
| **Est. time** | 60-75 min |
| **Prereqs** | `kali` VM up at `10.13.37.10` with a browser (Firefox on Kali). Handy tools: browser Developer Tools (F12), `curl`, Burp Suite. |
| **Start from** | Ensure the web container is up. On the **host**: `docker ps --filter name=juiceshop` shows it running; if not, `docker start juiceshop`. From Kali confirm reach: `curl -s -o /dev/null -w '%{http_code}\n' http://10.13.37.35:3000/` -> `200`. |

Juice Shop is a modern Angular single-page app (SPA) on a Node/Express backend with a SQLite database.
It is intentionally full of bugs, and it **tracks your solves itself** on a hidden Score Board - so
success is measurable without planting flags.

## MITRE ATT&CK / OWASP mapping
- **A03:2021 Injection / T1190 Exploit Public-Facing Application** - SQLi login bypass, DOM XSS.
- **A01:2021 Broken Access Control** - viewing another user's basket, reaching the admin section.
- **A02/A05 (Sensitive Data Exposure / Security Misconfiguration)** - a confidential file served from a static folder.
- The **Score Board** discovery is itself the "Find the carefully hidden Score Board" challenge.

All steps are in the **browser on Kali** unless a shell command is shown.

---

## Step 0 - Register an account (you need to be logged in for several challenges)
1. Go to `http://10.13.37.35:3000/`. Dismiss the welcome/cookie banners.
2. Top-right **Account -> Login -> "Not yet a customer?"** (`/#/register`).
3. Register e.g. `student@lab.local` / a password you will remember; answer the security question.
4. Log in.

**What you should see:** your email in the top-right account menu. You are now an authenticated
customer (the lowest privilege level).

---

## Challenge 1 - Find the hidden Score Board (the challenge tracker)
**Class:** Security misconfiguration / discovery. This is your progress dashboard for everything else.

1. View source / open Dev Tools (F12) -> **Sources** (or **Debugger**) and open the main bundle
   (`main.js` / `main-*.js`). Search it for `score-board`.
2. You will find a client-side route for it. Browse directly to:
   ```
   http://10.13.37.35:3000/#/score-board
   ```

**What solving looks like:** the Score Board page loads with a grid of every challenge, filterable by
difficulty and category, each turning **green** as you solve it. A success toast pops:
*"You successfully solved a challenge: Score Board"*. **Keep this tab open** - it is the built-in
challenge tracker you will watch for the rest of the scenario.

**Defense:** don't ship hidden-but-reachable admin/debug pages and rely on obscurity. Routes and assets
in a SPA bundle are fully visible to the client. Protect sensitive views with **server-side
authorization**, and remove debug/hidden functionality from production builds.

---

## Challenge 2 - SQL injection login bypass ("Login Admin")
**Class:** A03 Injection / T1190. The login form builds a SQL query by concatenating the email string.

1. Go to **Login** (`/#/login`).
2. **Email:**
   ```
   ' OR 1=1--
   ```
   **Password:** anything (e.g. `x`).
3. Click **Log in**.

**What it does:** the injected `' OR 1=1--` makes the `WHERE` clause always true and comments out the
password check, so the query returns the **first** user in the table - the administrator.
**What solving looks like:** you are logged in (top-right shows `admin@juice-sh.op`), and the Score
Board marks **"Login Admin"** green. To log in as a *specific* user instead, use
`admin@juice-sh.op'--` in the email field (closes the string, comments out the password) - same bug,
targeted.

**Defense:** **parameterized queries / prepared statements** (with Sequelize, use bound
replacements/`where` objects, never string interpolation of `req.body.email` into the query). The email
is then treated as a data value, so `' OR 1=1--` matches no account. Add server-side input validation
(a login field is not free-form SQL) and generic error messages.

---

## Challenge 3 - Broken access control: view another user's basket ("View Basket")
**Class:** A01 Broken Access Control. The basket endpoint trusts a client-supplied id.

1. Log in as **your own** account (Step 0). Add any product to your basket so a basket exists.
2. Open Dev Tools -> **Application** -> **Session Storage** (and Local Storage). Note the value of
   **`bid`** (your basket id) and your **`token`** (JWT).
3. Watch the basket request: Dev Tools -> **Network**, open your basket. You will see
   `GET /rest/basket/<your-bid>`. Now request a **different** id. Easiest from the shell on Kali
   (replace `TOKEN` with your JWT, and try ids 1, 2, 3...):
   ```bash
   curl -s http://10.13.37.35:3000/rest/basket/1 \
     -H "Authorization: Bearer TOKEN" | head
   ```
   Or in the browser, change `bid` in Session Storage to another number and reload the basket.

**What solving looks like:** you receive **another user's** basket contents (products that are not
yours). The Score Board marks **"View Basket"** green.
**Why it works:** the server returns basket `N` to anyone with a valid token, without checking the
basket **belongs to** the caller (an IDOR - Insecure Direct Object Reference).

**Defense:** enforce **object-level authorization** server-side: verify the authenticated user
(`req.user.id` from the verified JWT) actually owns the requested basket before returning it. Never
derive identity or ownership from a client-supplied id in the URL or storage.

---

## Challenge 4 - Broken access control: reach the Admin Section ("Admin Section")
**Class:** A01 Broken Access Control (missing role check on a route).

1. Stay logged in **as admin** from Challenge 2 (or an account with the admin role).
2. Browse directly to:
   ```
   http://10.13.37.35:3000/#/administration
   ```

**What solving looks like:** the **Administration** page loads (registered users, product reviews). The
Score Board marks **"Admin Section"** green. As a normal user you can *reach the route* client-side, but
the data behind it should be denied - the lesson is that client-side hiding is not access control.

**Defense:** guard admin routes and their **APIs** with a server-side role/permission check on every
request (not just hiding the menu item in the UI). The frontend route guard is a convenience; the
authorization decision must be made and enforced on the backend.

---

## Challenge 5 - Sensitive data exposure: read a confidential document ("Confidential Document")
**Class:** A02 Cryptographic/Sensitive-Data Failures + A05 Misconfiguration (files served from a public static path).

1. Go to **About Us** (`/#/about`). There is a link to a "terms of use" document in the `/ftp/` folder.
2. Follow it, then browse the folder / guess the neighbouring file. The target file is:
   ```
   http://10.13.37.35:3000/ftp/acquisitions.md
   ```
   (Some files in `/ftp/` are blocked by extension; `.md` is readable. From the shell:
   `curl -s http://10.13.37.35:3000/ftp/acquisitions.md | head`.)

**What solving looks like:** the confidential acquisitions memo renders in the browser (or prints in the
terminal). The Score Board marks **"Confidential Document"** green.

**Defense:** never serve sensitive files from a world-readable static directory. Apply **least data
exposure**: keep confidential documents out of the web root, put downloads behind an
**authorization-checked** endpoint, and audit static-folder contents before deploy.

---

## Challenge 6 - DOM Cross-Site Scripting ("DOM XSS")
**Class:** A03 Injection / T1059.007. The search box writes your query into the DOM without sanitising it.

1. Use the **search** magnifier in the top bar.
2. Enter this payload and press Enter:
   ```
   <iframe src="javascript:alert(`xss`)">
   ```

**What solving looks like:** an `xss` alert box fires (the search term is reflected into the page's DOM
and executed). The URL shows your payload in the `?q=` fragment. The Score Board marks **"DOM XSS"**
green.
**Why it works:** the app inserts the untrusted search string into the page using a sink that trusts
HTML (Angular's sanitizer was bypassed), so the browser runs your markup.

**Defense:** **output encoding + framework sanitization** - let Angular's built-in contextual escaping
handle interpolation and **never** call `bypassSecurityTrustHtml`/`innerHTML` on user input. Add a
strict **Content-Security-Policy** header (e.g. no inline scripts) as defense in depth, and validate
input server-side.

---

## Track your progress (the built-in tracker)
Return to the Score Board tab (`http://10.13.37.35:3000/#/score-board`). Every challenge you solved
above is now **green**. Use the **difficulty** and **category** filters to find your next beginner
target (1-star). The tracker is authoritative - if a challenge is not green, it did not actually solve,
and you should re-check the exact payload/URL.

---

## Defense summary (per OWASP class you touched)
| Challenge | OWASP class | The fix |
|---|---|---|
| Login bypass | A03 Injection | Parameterized queries / ORM bound params; input validation; generic errors |
| View Basket | A01 Broken Access Control | Server-side object-ownership check (no trust in client id / `bid`) |
| Admin Section | A01 Broken Access Control | Server-side role check on the route **and** its API, not UI hiding |
| Confidential Document | A02/A05 Sensitive Data / Misconfig | Least data exposure; sensitive files out of the web root; authz on downloads |
| DOM XSS | A03 Injection | Framework auto-escaping / output encoding; no `bypassSecurityTrust*`; strict CSP |
| Score Board discovery | A05 Misconfiguration | No security by obscurity; protect sensitive views server-side; strip debug from prod |

> **Note on proving the fix:** unlike DVWA, Juice Shop has no "Impossible" switch - it is deliberately
> vulnerable end to end. The way to *prove* a fix here is to read the offending source
> (`routes/`, `models/`, `data/` in the Juice Shop repo), apply the parameterized-query / authz-check /
> encoding change, rebuild, and confirm the same payload now fails. In this lab we state the fix per
> challenge and demonstrate it conceptually; the code-level fix belongs to a follow-on "patch it"
> exercise on a copy of the source.

---

## Flags / evidence captured
Juice Shop uses solved challenges instead of flags. Capture a screenshot of the Score Board showing the
green tiles for: **Score Board, Login Admin, View Basket, Admin Section, Confidential Document, DOM XSS**.
Optionally save the confidential doc (`acquisitions.md`) and the admin login JWT as evidence.

## Cleanup / reset
Juice Shop is a container and it stores its state (accounts, solved challenges) in-memory/SQLite;
restarting resets it to a clean, unsolved state:
```bash
# on the HOST (containers live on the host, not on Kali)
docker restart juiceshop            # resets solved challenges + accounts to clean
# full clean rebuild if it got wedged:
docker rm -f juiceshop
docker run -d --name juiceshop --network hacklab-mv --ip 10.13.37.35 \
  --restart unless-stopped bkimminich/juice-shop
```
Give it ~30-60s to come back up, then re-verify with the `curl` reach check in the header.

## Go deeper
- Research: why does ' OR 1=1-- log me in as admin specifically in Juice Shop?
- Research: explain IDOR vs a proper object-ownership check for the basket endpoint
- Research: how does a Content-Security-Policy stop the DOM XSS iframe payload?
