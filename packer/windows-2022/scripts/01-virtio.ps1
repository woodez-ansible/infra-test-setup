# Check the VirtIO guest tools that bootstrap.ps1 installed at first logon (before WinRM,
# because the installer reloads the network driver and kills open WinRM commands).
# The QEMU guest agent is how the VM builder learns each VM's DHCP address.
$ErrorActionPreference = 'Stop'
$raw = Get-Content C:\Windows\Temp\virtio-guest-tools.exitcode -ErrorAction SilentlyContinue
$code = if ($raw) { [int]$raw } else { -2 }   # -2 = bootstrap never recorded a result
# 3010 = success, reboot required
if ($code -notin 0, 3010) {
    Get-Content C:\Windows\Temp\virtio-guest-tools.log -Tail 30 -ErrorAction SilentlyContinue
    throw "virtio-win-guest-tools failed in bootstrap (exit code $code)"
}
$svc = Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue
if (-not $svc) { throw 'QEMU guest agent service (QEMU-GA) not installed' }
Set-Service -Name QEMU-GA -StartupType Automatic
"virtio guest tools installed (exit $code); QEMU-GA: $($svc.Status)"
