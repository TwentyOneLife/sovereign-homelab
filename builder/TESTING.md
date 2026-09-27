# Clean-host test runbook

How to validate the whole lab builder from scratch on a **fresh, disposable host**, then delete it. This
is the real test: it exercises the prerequisite install and every build path (image download + verify,
the Debian offline-customize, the Windows unattended install) that a first-time user hits. Do this before
telling anyone "clone and go".

> A partial test on an already-set-up host only checks script logic. It skips the prerequisite install,
> and a lab bridge with no VM has no carrier so container targets look broken. Use a clean host.

## 1. Pick a disposable host

You need hardware virtualization (nested KVM), so pick one of:
- **A spare physical PC** (best, simplest): install Debian 12 or Ubuntu 22.04+, done.
- **A nested-virt-capable cloud VM**: most shared cloud VMs cannot run KVM. Use one that supports nested
  virtualization (for example a bare-metal instance, or a provider/instance that explicitly enables it).
- **A nested KVM VM on a machine you already have**: workable for the Linux parts; the Windows VMs are
  slow nested and Windows-in-Windows-in-Linux is painful. Fine for a Linux-only smoke test.

Confirm virtualization on the host:
```
egrep -c '(vmx|svm)' /proc/cpuinfo   # must be > 0
ls -l /dev/kvm                        # must exist
```

## 2. Install prerequisites

```
sudo apt update
sudo apt install -y \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
  virtinst xorriso p7zip-full unzip curl gnupg openssl docker.io lvm2 openssh-client
sudo usermod -aG libvirt,kvm,docker "$USER"
# log out and back in so the groups take effect
```
Note: `p7zip-full` provides `7z`, needed to extract the Kali image. `builder/setup.sh --check` will tell
you if anything is still missing.

## 3. Get the Windows ISOs (only for the AD modules)

Download the two free evaluations to `~/Downloads` (or wherever `lab.conf` `WIN11_ISO` / `WINSRV_ISO`
point): Windows 11 Enterprise and Windows Server 2022, from Microsoft's Evaluation Center. Skip this if
you only want to test the Linux + web + node targets.

## 4. Clone and configure

```
git clone https://github.com/TwentyOneLife/sovereign-homelab.git
cd sovereign-homelab
$EDITOR lab.conf          # review; defaults are fine for an isolated lab. Set WIN11_ISO / WINSRV_ISO paths.
./builder/setup.sh --check
```

## 5. Build

Run components in order (or `./builder/setup.sh --all` for the non-Windows set, then Windows and node
separately). Windows needs a couple of manual clicks (the installer boot and the domain-join), which
`50-windows.sh` prints.
```
./builder/00-network.sh          # isolated net + pool
./builder/10-kali.sh             # attacker (downloads + verifies the Kali image)
./builder/20-targets-linux.sh    # Metasploitable 2 + the Debian 'blue' target (needs sudo for nbd)
./builder/30-web.sh              # DVWA + Juice Shop containers
./builder/60-node.sh             # the Bitcoin regtest node
./builder/50-windows.sh          # win-dc + win-cli (follow the printed manual steps)
```

## 6. Verification checklist

Start Kali first (it gives the bridge carrier). From Kali (`KALI_IP` in `lab.conf`):
- [ ] **Network isolated**: from a target, `ping` the host bridge IP succeeds; `ping` a made-up real-LAN
      address and `ping 1.1.1.1` both fail.
- [ ] **Kali reachable** and has its tools (`nmap`, `msfconsole`, `nxc`, `bloodhound-python`, `sqlmap`).
- [ ] **Linux targets**: `nmap -sV MSF2_IP` shows the expected open services; `ssh` to `blue` works.
- [ ] **Web**: `curl http://DVWA_IP/` and `http://JUICE_IP:3000/` respond from Kali.
- [ ] **Node**: the exposed RPC answers, e.g.
      `curl --user rpc:rpcpassword --data-binary '{"method":"getblockchaininfo","params":[]}' http://NODE_IP:18443/`.
- [ ] **AD** (if built): `nxc smb WINDC_IP` and `bloodhound-python ... -d hacklab.local` work; win-cli is
      domain-joined; the loot flags exist on win-cli.
- [ ] Work module `00-network-map.md` end to end; it should read cleanly against the real targets.

Record anything that differs from the course text; fix the internal source and re-run `homelab-sync`.

## 7. Teardown

```
./builder/reset.sh --teardown     # removes the lab VMs, network and pool
docker rm -f node dvwa juiceshop 2>/dev/null
```
Then delete or wipe the disposable host. Nothing from the test should remain on it.

## Expected quirks (already known)
- `setup.sh --check` flags `7z` if `p7zip-full` is not installed. Install it, per step 2.
- Container targets (web/node) need at least one VM (Kali) running on the bridge, or the bridge has no
  carrier and they look unreachable. Start Kali first.
- **osinfo names vs an older libosinfo:** a host whose `osinfo-db` predates a release (Debian bookworm
  has no `debian12`) rejects `--osinfo debian12`. The Linux targets pick a known id at runtime
  (`osinfo_pick`); `50-windows.sh` still hardcodes `win11`/`win2k22`, so on a very old libosinfo the
  Windows step may need those adjusted (or `osinfo-db` updated).
- **Nested test host only:** if you run this inside a VM whose own uplink is on `192.168.122.0/24`
  (libvirt's usual `default` subnet), the guest's `default` network cannot start
  (`Network is already in use by interface ...`) and Kali comes up without its internet NIC. This does
  not happen on a real host, whose LAN is some other subnet. To test the full path in a nested guest,
  give the guest's uplink a different subnet, or re-define the guest's `default` net onto e.g.
  `192.168.150.0/24` before running `10-kali.sh`.
