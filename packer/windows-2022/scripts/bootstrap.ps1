# First logon of the build VM (autounattend FirstLogonCommands). Enables WinRM over HTTP
# with Basic auth so Packer can drive the build. This exists ONLY inside the build, on
# Packer's private network, and finalize-run.ps1 removes it again before sysprep.
$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\Windows\Temp\vmb-bootstrap.log -Force

# Remote admin over WinRM for a local (non-built-in) admin needs UAC remote restrictions
# lifted. This persists through sysprep and is what lets Ansible use 'ansible' later.
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force | Out-Null

# The automation account must not expire (default would be 42 days)
Set-LocalUser -Name ansible -PasswordNeverExpires $true

# VirtIO guest tools (drivers + QEMU guest agent) BEFORE WinRM is up: the installer
# reloads the network driver, which silently kills any open WinRM command, so Packer
# would wait on it forever. 01-virtio.ps1 checks the result later.
$gt = Join-Path (Split-Path $PSScriptRoot) 'virtio-win-guest-tools.exe'
$p = Start-Process -FilePath $gt -ArgumentList '/install', '/quiet', '/norestart', '/log', 'C:\Windows\Temp\virtio-guest-tools.log' -PassThru
# Never throw here: without WinRM, Packer would only notice after its 3 h timeout.
# 01-virtio.ps1 fails the build on a bad exit code instead (-1 = timed out).
if ($p.WaitForExit(20 * 60 * 1000)) { $code = $p.ExitCode } else { $p | Stop-Process -Force; $code = -1 }
"virtio-win-guest-tools exit code: $code"
Set-Content -Path C:\Windows\Temp\virtio-guest-tools.exitcode -Value $code

# After the network driver reload, so the profile applies to the adapter as it now is
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
winrm quickconfig -quiet -force
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
Set-Service -Name WinRM -StartupType Automatic
Restart-Service WinRM
Stop-Transcript
