# Sovereign Homelab - lab builder

Reproducible scripts that stand up the whole isolated security lab on your own Linux/KVM host. Everything (names, IPs, passwords, keyboard layout) is read from one file, [`../lab.conf`](../lab.conf), so you build the same lab we did, or your own variant, by editing that file.

The lab is **fully isolated**: its virtual network has no route to your real LAN or the internet. Every target is a VM or container you own. The planted "secrets" are fake `FLAG-...{}` strings, never real keys. Only ever run these tools inside this lab.

## What gets built

| Component | What | Address |
|---|---|---|
| network | isolated libvirt net (no forward) + a `dir` storage pool | host at `LAB_HOST_IP` |
| kali | Kali Linux attacker, 2 NICs (lab + NAT for updates) | `KALI_IP` |
| linux | Metasploitable 2 + a Debian "blue" hardening target | `MSF2_IP`, `BLUE_IP` |
| web | DVWA + OWASP Juice Shop (Docker on a macvlan) | `DVWA_IP`, `JUICE_IP` |
| windows | Server 2022 domain controller + domain-joined Win11 | `WINDC_IP`, `WINCLI_IP` |

The Bitcoin node target (`NODE_IP`) is built by a separate script and is not part of this builder.

## 1. Prerequisites

A Linux host with hardware virtualization enabled (Intel VT-x / AMD-V), and enough RAM to run the profile you want (roughly 13 to 16 GB for a full session; do not run every VM at once). You need KVM/libvirt, QEMU, `virt-install`, `xorriso`, `p7zip`, `docker`, and a few standard tools.

On Debian or Ubuntu:

```
sudo apt update
sudo apt install -y \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
  virtinst xorriso p7zip-full unzip curl gnupg openssl \
  cloud-guest-utils ovmf swtpm swtpm-tools docker.io

# let your user drive libvirt and docker without sudo, then log out and back in
sudo usermod -aG libvirt,kvm,docker "$USER"
sudo systemctl enable --now libvirtd docker
```

- `ovmf` provides UEFI firmware, `swtpm` provides the virtual TPM (both needed for Windows 11).
- `cloud-guest-utils` provides `growpart` (used to grow the Debian target's disk; optional).
- Check `/dev/kvm` exists and `virsh version` works before you start.

Run the built-in check any time:

```
./setup.sh --check
```

## 2. Base images

The Linux images are downloaded and verified automatically. The two Windows ISOs are free but you download them yourself (Microsoft requires accepting their evaluation terms).

| Image | Source | Verification |
|---|---|---|
| Kali Linux QEMU | https://www.kali.org/get-kali/ (Virtual Machines, QEMU) | GPG on `SHA256SUMS` + sha256, automatic |
| Debian 12 genericcloud | https://cloud.debian.org/images/cloud/bookworm/latest/ | sha512 (GPG optional, see below), automatic |
| Metasploitable 2 | https://sourceforge.net/projects/metasploitable/ | pinned sha256 (no upstream signature exists), automatic |
| Windows 11 Enterprise (eval) | https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise | you download; keep the ISO |
| Windows Server 2022 (eval) | https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022 | you download; keep the ISO |

Put the two Windows ISOs where the builder can find them: either set `WIN11_ISO` and `WINSRV_ISO` (absolute paths) in `lab.conf`, or drop the files into `builder/downloads/` (the script globs for `*CLIENT*EVAL*.iso` and `*SERVER*EVAL*.iso`). The builder copies each ISO into the libvirt pool so the `qemu:///system` process can read it (a home directory is usually not readable by that service account), so allow room for that copy.

Downloaded images and intermediate files live in `builder/downloads/` (gitignored, user-writable). Final VM disks are placed into the libvirt pool at `LAB_STORAGE_DIR`.

**Optional stronger Debian check.** The Debian image is verified by sha512 against the checksums file. To also GPG-verify the checksums file itself, get the Debian cloud signing key fingerprint from cloud.debian.org, then run the builder with `DEBIAN_CLOUD_KEY_FPR="<fingerprint>"` exported so `20-targets-linux.sh` checks the signature too.

## 3. Configure

Edit [`../lab.conf`](../lab.conf), or copy it to `lab.local.conf` (gitignored) and edit that. Because the lab is isolated the shipped defaults are safe to keep. Notable options:

- `LAB_KEYMAP` (default `us`): keyboard layout baked into the guests and the Windows input locale. UI language stays en-US.
- network and address variables (`LAB_NET_NAME`, `LAB_BRIDGE`, `LAB_SUBNET`, `LAB_HOST_IP`, the per-VM IPs).
- credentials (`LAB_PASS`, `KALI_*`, `BLUE_*`, and the AD variables).
- `LAB_STORAGE_DIR` / `LAB_STORAGE_POOL`: where VM disks live.

## 4. Build

```
cd builder

./setup.sh --all            # build everything, in order (asks to confirm)
./setup.sh --all --yes      # ... without prompts

# or build components individually, in any order (network first):
./setup.sh network
./setup.sh kali
./setup.sh linux
./setup.sh web
./setup.sh windows
```

Each component is idempotent: re-running skips what already exists. The Linux side is roughly hands-off. Budget one to two hours end to end, most of it downloading and Windows installing.

### The Windows step needs a few clicks

The two Windows VMs install **unattended** from generated `autounattend.xml` answer files, but UEFI + Microsoft's eval media mean a few manual moments at the console (open `virt-manager` to watch):

1. If you see "Press any key to boot from CD", press a key. If the VM lands in the UEFI shell or firmware menu instead, pick the DVD/CDROM entry to start Windows Setup.
2. After the **first** reboot the VM powers **off** (a side effect of the install phase). Just start it again: `virsh start win-dc`, later `virsh start win-cli`.
3. `win-dc` auto-installs Active Directory and promotes itself to a domain controller for `AD_DOMAIN`. Give it a few minutes and a couple of automatic reboots.
4. Finish with two short scripts from the attached scripts CD (there is no guest agent, so these run inside the guest). See `RUN-ME.txt` on the CD:
   - on `win-dc`: `1-create-users.ps1` (creates the domain users)
   - on `win-cli`: `2-join-domain.cmd` (joins the domain) then `3-plant-loot.ps1` (plants the fake flags)

A note on reachability: the web containers sit on a macvlan, which by design blocks traffic between a container and its parent host. So the **host cannot** ping or curl DVWA / Juice Shop, but **Kali can**. That is expected. The builder initialises DVWA's database from a helper container on the same macvlan.

## 5. Snapshot, reset and teardown

Once a VM is set up the way you want, snapshot it so you can revert in seconds after an attack:

```
./reset.sh snapshot              # snapshot every lab VM as 'clean-baseline'
./reset.sh snapshot blue         # just one
./reset.sh revert blue           # roll blue back to clean-baseline
./reset.sh list                  # show snapshots
```

Linux VMs use internal snapshots. Windows VMs use external disk snapshots (the UEFI firmware store blocks internal ones), so shut them down before reverting; `reset.sh` does that for you. Reverting an external snapshot needs libvirt 9.0 or newer.

### Verify isolation

Before trusting any target, confirm the lab has no way out. From Kali (detach its NAT NIC first, `virsh detach-interface kali network --mac 52:54:00:13:37:fe --live`): pinging the host at `LAB_HOST_IP` must succeed, while pinging your real LAN gateway and a public address such as `1.1.1.1` must both fail with "Network is unreachable". If any external ping succeeds, stop and check that the libvirt network has no `<forward>` element.

Full teardown removes everything the builder created (VMs, containers, network, pool), and offers to delete the VM disks. Your downloads are left in place.

```
./reset.sh teardown              # asks before removing, and again before wiping disks
./reset.sh teardown --yes        # no prompts
```

## File map

- `setup.sh` - orchestrator (prereq check, runs components in order).
- `lib/common.sh` - shared helpers (config loading, logging, verification, qemu-nbd, virsh wrappers).
- `00-network.sh` - isolated network + storage pool.
- `10-kali.sh` - Kali attacker.
- `20-targets-linux.sh` - Metasploitable 2 + the Debian "blue" target.
- `30-web.sh` - DVWA + Juice Shop containers.
- `50-windows.sh` - the Windows / Active Directory pair.
- `reset.sh` - snapshot / revert / teardown.
- `downloads/` - images and generated ISOs (gitignored).

## Ethics and scope

Everything here targets VMs you own on an isolated network, for learning. Never point these tools at any system you do not own and have explicit permission to test. The lab's "bank" and "wallet" secrets are planted fakes.
