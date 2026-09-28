#!/usr/bin/env bash
# 50-windows.sh - the Windows / Active Directory pair, built UNATTENDED.
#   win-dc  : Server 2022, promoted to a DC for $AD_DOMAIN (UEFI)
#   win-cli : Windows 11, domain-joined victim desktop (UEFI + vTPM 2.0)
#
# From two Microsoft Evaluation Center ISOs you download yourself, this script
# generates autounattend.xml answer files + a scripts CD, builds them into tiny
# ISOs with xorriso, and defines the VMs. Windows Setup then installs hands-off.
#
# HONEST ABOUT THE MANUAL BITS (see the printed steps at the end):
#  - At the UEFI console you may see "Press any key to boot from CD" - press one.
#  - A firmware boot-manager pick is sometimes needed to boot the install ISO.
#  - The VMs boot disk-first with the install DVD second and reboot on their own
#    through Setup (no power-off, no 'virsh start' step).
#  - Creating the domain users and joining win-cli are two scripts you run
#    inside the guests from the attached scripts CD (there is no guest agent,
#    and a non-US keyboard defeats console key-injection).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

need_cmd virsh; need_cmd virt-install; need_cmd xorriso
net_exists "$LAB_NET_NAME" || die "lab network '$LAB_NET_NAME' not found - run 00-network.sh first"

WORK="$DOWNLOAD_DIR/windows"
mkdir -p "$WORK"

# --- keymap -> Windows input locale ----------------------------------------
input_locale() {
  case "$LAB_KEYMAP" in
    us) echo "0409:00000409" ;;
    de) echo "0407:00000407" ;;
    gb|uk) echo "0809:00000809" ;;
    fr) echo "040c:0000040c" ;;
    es) echo "040a:0000040a" ;;
    it) echo "0410:00000410" ;;
    *) warn "unknown LAB_KEYMAP '$LAB_KEYMAP' - defaulting Windows input to US"; echo "0409:00000409" ;;
  esac
}
INLOC="$(input_locale)"

# --- resolve the user-supplied ISOs ----------------------------------------
resolve_iso() { # varvalue glob description
  local given="$1" glob="$2" desc="$3"
  if [ -n "$given" ]; then
    [ -f "$given" ] || die "$desc ISO not found at: $given"
    echo "$given"; return
  fi
  local matches=()
  mapfile -t matches < <(find "$DOWNLOAD_DIR" -maxdepth 1 -iname "$glob" 2>/dev/null | sort)
  case ${#matches[@]} in
    0) die "$desc ISO not set and none matching '$glob' in $DOWNLOAD_DIR.
       Download the free Evaluation Center ISO (see builder/README.md), then set
       its path in lab.conf/lab.local.conf (WIN11_ISO / WINSRV_ISO) or drop it into $DOWNLOAD_DIR." ;;
    1) echo "${matches[0]}" ;;
    *) die "$desc: multiple ISOs match '$glob' in $DOWNLOAD_DIR - refusing to guess:
$(printf '         %s\n' "${matches[@]}")
       Set WIN11_ISO / WINSRV_ISO in lab.local.conf to the one you want." ;;
  esac
}

# ---------------------------------------------------------------------------
# autounattend.xml generators (values come from lab.conf)
# ---------------------------------------------------------------------------
gen_win11_unattend() {
  cat > "$WORK/autounattend-win11.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>${INLOC}</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UILanguageFallback>en-US</UILanguageFallback>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall><OSImage><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo></OSImage></ImageInstall>
      <UserData><ProductKey><WillShowUI>OnError</WillShowUI></ProductKey><AcceptEula>true</AcceptEula></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>${WINCLI_NAME}</ComputerName>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>${INLOC}</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>${INLOC}</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><NetworkLocation>Work</NetworkLocation><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>${WINCLI_USER}</Name><DisplayName>Lab Admin</DisplayName><Group>Administrators</Group>
            <Password><Value>${LAB_PASS}</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>${WINCLI_USER}</Username><LogonCount>1</LogonCount><Password><Value>${LAB_PASS}</Value><PlainText>true</PlainText></Password></AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell -NoProfile -Command "\$a=Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1; New-NetIPAddress -InterfaceIndex \$a.ifIndex -IPAddress ${WINCLI_IP} -PrefixLength ${PREFIX} -ErrorAction SilentlyContinue; Set-DnsClientServerAddress -InterfaceIndex \$a.ifIndex -ServerAddresses ${WINDC_IP}"</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>reg add "HKLM\System\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>netsh advfirewall firewall set rule group="remote desktop" new enable=Yes</CommandLine></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF
}

gen_srv_unattend() {
  cat > "$WORK/autounattend-win2k22.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>${INLOC}</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UILanguageFallback>en-US</UILanguageFallback><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall><OSImage>
        <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        <!-- Select the image by INDEX, not name. /IMAGE/NAME matches the WIM <NAME>
             field, but Setup's picker shows <DISPLAYNAME>; on the Server 2022 eval the
             two differ (index 2 NAME="Windows Server 2022 SERVERSTANDARD",
             DISPLAYNAME="Windows Server 2022 Standard Evaluation (Desktop Experience)"),
             so a /IMAGE/NAME of the display string matched nothing and Setup prompted.
             Index 2 = Standard w/ Desktop Experience, fixed on every Server 2022 eval ISO. -->
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>2</Value></MetaData></InstallFrom>
      </OSImage></ImageInstall>
      <UserData><ProductKey><WillShowUI>OnError</WillShowUI></ProductKey><AcceptEula>true</AcceptEula></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>${WINDC_NAME}</ComputerName>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>${INLOC}</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>${INLOC}</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><NetworkLocation>Work</NetworkLocation><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><AdministratorPassword><Value>${LAB_PASS}</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>Administrator</Username><LogonCount>2</LogonCount><Password><Value>${LAB_PASS}</Value><PlainText>true</PlainText></Password></AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell -NoProfile -Command "\$a=Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1; New-NetIPAddress -InterfaceIndex \$a.ifIndex -IPAddress ${WINDC_IP} -PrefixLength ${PREFIX} -ErrorAction SilentlyContinue; Set-DnsClientServerAddress -InterfaceIndex \$a.ifIndex -ServerAddresses 127.0.0.1"</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>powershell -NoProfile -Command "Install-WindowsFeature AD-Domain-Services -IncludeManagementTools"</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>powershell -NoProfile -Command "Import-Module ADDSDeployment; Install-ADDSForest -DomainName '${AD_DOMAIN}' -DomainNetbiosName '${AD_NETBIOS}' -SafeModeAdministratorPassword (ConvertTo-SecureString '${LAB_PASS}' -AsPlainText -Force) -InstallDns -Force"</CommandLine></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF
}

# ---------------------------------------------------------------------------
# scripts CD: run these inside the guests after install (order in RUN-ME.txt)
# ---------------------------------------------------------------------------
gen_scripts_cd() {
  local sd="$WORK/scripts"; rm -rf "$sd"; mkdir -p "$sd"

  cat > "$sd/RUN-ME.txt" <<EOF
Sovereign Homelab - Windows/AD post-install steps
==================================================
Run in this order (both guests auto-log in as an administrator):

ON win-dc (after it finishes promoting to a domain controller and reboots):
  1) Open PowerShell as Administrator, run:  D:\\1-create-users.ps1
     (creates the domain users ${AD_USER1} and ${AD_SVC}; puts ${AD_SVC} in Domain Admins)

ON win-cli:
  2) Double-click  D:\\2-join-domain.cmd   (self-elevates, joins ${AD_DOMAIN}, reboots)
  3) After reboot, open PowerShell as Administrator, run:  D:\\3-plant-loot.ps1
     (writes the fake FLAG files into C:\\Users\\Public\\Documents)

The CD drive letter may differ from D: - check This PC.
EOF

  cat > "$sd/1-create-users.ps1" <<EOF
# Run on the DC. Creates domain users from lab.conf values.
Import-Module ActiveDirectory
\$pw = ConvertTo-SecureString '${LAB_PASS}' -AsPlainText -Force
New-ADUser -Name '${AD_USER1}' -SamAccountName '${AD_USER1}' -AccountPassword \$pw -Enabled \$true -PasswordNeverExpires \$true -ErrorAction SilentlyContinue
New-ADUser -Name '${AD_SVC}'  -SamAccountName '${AD_SVC}'  -AccountPassword \$pw -Enabled \$true -PasswordNeverExpires \$true -ErrorAction SilentlyContinue
# Deliberately weak: service account in Domain Admins (a lab escalation path).
Add-ADGroupMember -Identity 'Domain Admins' -Members '${AD_SVC}' -ErrorAction SilentlyContinue
Write-Host 'Domain users created.'
EOF

  cat > "$sd/2-join-domain.ps1" <<EOF
# Run on win-cli. Points DNS at the DC, joins the domain, reboots.
\$a = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex \$a.ifIndex -ServerAddresses ${WINDC_IP}
if (-not (Resolve-DnsName '${AD_DOMAIN}' -ErrorAction SilentlyContinue)) {
  Write-Warning 'Cannot resolve ${AD_DOMAIN}. Is win-dc up and promoted? DNS = ${WINDC_IP}'
  exit 1
}
\$cred = New-Object System.Management.Automation.PSCredential('${AD_NETBIOS}\Administrator', (ConvertTo-SecureString '${LAB_PASS}' -AsPlainText -Force))
Add-Computer -DomainName '${AD_DOMAIN}' -Credential \$cred -Force -Restart
EOF

  cat > "$sd/2-join-domain.cmd" <<'CMD'
@echo off
REM self-elevate then run the join script
net session >nul 2>&1 || (powershell -Command "Start-Process cmd -ArgumentList '/c %~f0' -Verb RunAs" & exit /b)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp02-join-domain.ps1"
CMD

  cat > "$sd/3-plant-loot.ps1" <<'PS'
# Run on win-cli. Plants FAKE flag files (never real secrets).
$dir = 'C:\Users\Public\Documents'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
'FLAG-BANK{fake-statement-for-the-lab}'      | Set-Content "$dir\statement.txt"
'FLAG-SEED{these-twelve-words-are-not-real}' | Set-Content "$dir\wallet-seed.txt"
'FLAG-CREDS{lab-only-not-a-real-password}'   | Set-Content "$dir\saved-credentials.txt"
Write-Host 'Loot planted (fake).'
PS

  log "building lab-scripts.iso"
  run xorriso -as mkisofs -quiet -o "$WORK/lab-scripts.iso" -V LABSCRIPTS -J -R "$sd"
}

# ---------------------------------------------------------------------------
# ISO builders + VM definitions
# ---------------------------------------------------------------------------
build_unattend_iso() { # xmlfile isoname label
  local dir; dir="$(mktemp -d)"
  cp "$1" "$dir/autounattend.xml"
  run xorriso -as mkisofs -quiet -o "$WORK/$2" -V "$3" -J -R "$dir"
  rm -rf "$dir"
}

# All ISOs must live where the qemu:///system process (user libvirt-qemu) can
# read them. A user's home is typically not traversable by that user, so copy
# every ISO into the libvirt pool dir and reference it there. Idempotent.
place_iso() { # src destname  -> echoes pool path
  local src="$1" dest="$LAB_STORAGE_DIR/$2"
  if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
    as_root cp -f "$src" "$dest"
  fi
  echo "$dest"
}

define_win_dc() {
  if vm_exists win-dc; then ok "VM 'win-dc' already defined"; return; fi
  local src; src="$(resolve_iso "$WINSRV_ISO" '*SERVER*EVAL*.iso' 'Windows Server 2022 Evaluation')"
  gen_srv_unattend
  build_unattend_iso "$WORK/autounattend-win2k22.xml" "win2k22-unattend.iso" "UNATTEND"
  log "placing ISOs into the pool (readable by qemu:///system)"
  local iso ua scr
  iso="$(place_iso "$src" win-dc-install.iso)"
  ua="$(place_iso "$WORK/win2k22-unattend.iso" win2k22-unattend.iso)"
  scr="$(place_iso "$WORK/lab-scripts.iso" lab-scripts.iso)"
  run virsh pool-refresh "$LAB_STORAGE_POOL" >/dev/null || true
  log "defining VM 'win-dc' (Server 2022, UEFI)"
  # Boot the hard disk first, the install DVD second (--import = no install phase,
  # just boot what we attach). First boot the disk is empty, so firmware falls
  # through to the DVD and Setup runs; once Windows is on the disk it boots from
  # there and the DVD is ignored. So the VM survives its own reboots
  # (on_reboot=restart) with no manual 'virsh start', and because the DVD is never
  # first it can never re-trigger the wiping installer.
  run virt-install --connect "$LIBVIRT_DEFAULT_URI" --name win-dc \
    --memory 4096 --vcpus 2 --cpu host-passthrough \
    --machine q35 --boot uefi \
    --import --events on_reboot=restart \
    --disk path="$LAB_STORAGE_DIR/win-dc.qcow2",size=60,bus=sata,format=qcow2,boot.order=1 \
    --disk device=cdrom,path="$iso",bus=sata,boot.order=2 \
    --disk device=cdrom,path="$ua",bus=sata \
    --disk device=cdrom,path="$scr",bus=sata \
    --network network="$LAB_NET_NAME",model=e1000,mac="$(mac_for_ip "$WINDC_IP")" \
    --osinfo "$(osinfo_pick win2k22 win2k19 win2k16)" \
    --graphics spice --video qxl --noautoconsole
  ok "VM 'win-dc' defined (Administrator / \$LAB_PASS; static $WINDC_IP)"
}

define_win_cli() {
  if vm_exists win-cli; then ok "VM 'win-cli' already defined"; return; fi
  local src; src="$(resolve_iso "$WIN11_ISO" '*CLIENT*EVAL*.iso' 'Windows 11 Enterprise Evaluation')"
  gen_win11_unattend
  build_unattend_iso "$WORK/autounattend-win11.xml" "win11-unattend.iso" "UNATTEND"
  log "placing ISOs into the pool (readable by qemu:///system)"
  local iso ua scr
  iso="$(place_iso "$src" win-cli-install.iso)"
  ua="$(place_iso "$WORK/win11-unattend.iso" win11-unattend.iso)"
  scr="$(place_iso "$WORK/lab-scripts.iso" lab-scripts.iso)"
  run virsh pool-refresh "$LAB_STORAGE_POOL" >/dev/null || true
  log "defining VM 'win-cli' (Windows 11, UEFI + vTPM 2.0)"
  run virt-install --connect "$LIBVIRT_DEFAULT_URI" --name win-cli \
    --memory 4096 --vcpus 2 --cpu host-passthrough \
    --machine q35 --boot uefi \
    --import --events on_reboot=restart \
    --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
    --disk path="$LAB_STORAGE_DIR/win-cli.qcow2",size=64,bus=sata,format=qcow2,boot.order=1 \
    --disk device=cdrom,path="$iso",bus=sata,boot.order=2 \
    --disk device=cdrom,path="$ua",bus=sata \
    --disk device=cdrom,path="$scr",bus=sata \
    --network network="$LAB_NET_NAME",model=e1000,mac="$(mac_for_ip "$WINCLI_IP")" \
    --osinfo "$(osinfo_pick win11 win10)" \
    --graphics spice --video qxl --noautoconsole
  ok "VM 'win-cli' defined (${WINCLI_USER} / \$LAB_PASS; static $WINCLI_IP)"
}

PREFIX="${LAB_SUBNET##*/}"
WINDC_NAME="WIN-DC"
WINCLI_NAME="WIN-CLI"

# Allow this file to be sourced (for testing the generators) without building.
[ "${WINDOWS_LIB_ONLY:-0}" = "1" ] && return 0

gen_scripts_cd
define_win_dc
define_win_cli

cat <<EOF

$(printf '%s' "$_c_green")Windows pair defined.$(printf '%s' "$_c_reset") What happens now (some manual steps - be at the console):

  1. Open the console for each VM:  virt-manager  (or: virsh console is text-only, use SPICE)
  2. If you see "Press any key to boot from CD", press a key. If it boots to the UEFI
     shell / firmware menu instead, pick the DVD/CDROM entry to start Windows Setup.
  3. Setup runs UNATTENDED from autounattend.xml and the VM continues through its
     own reboots on its own - no power-off, no 'virsh start' needed.
  4. win-dc auto-installs AD and promotes itself to a DC for '${AD_DOMAIN}'. Give it
     a few minutes and a couple of automatic reboots.
  5. Run the post-install steps from the attached scripts CD - see RUN-ME.txt on it:
       on win-dc:  D:\\1-create-users.ps1        (create domain users)
       on win-cli: D:\\2-join-domain.cmd         (join the domain, reboot)
                   D:\\3-plant-loot.ps1          (plant the fake FLAG files)
  6. When each VM is settled, snapshot it (win VMs use EXTERNAL disk snapshots -
     see reset.sh) so you can revert in seconds.

Resource note: run this Windows pair with the Linux targets OFF (memory budget).
EOF
