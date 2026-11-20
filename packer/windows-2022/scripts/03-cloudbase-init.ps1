# cloudbase-init: configures each VM at first boot from the NoCloud "cidata" ISO
# (hostname, WinRM HTTPS listener, volume extension). It does NOT create users or set
# passwords: the 'ansible' admin is already in the image.
$ErrorActionPreference = 'Stop'
$msi = Get-ChildItem C:\Windows\Temp\vmb\CloudbaseInitSetup_*_x64.msi | Select-Object -First 1
$msiArgs = @('/i', $msi.FullName, '/qn', '/l*v', 'C:\Windows\Temp\vmb-cloudbase-init-install.log', 'RUN_SERVICE_AS_LOCAL_SYSTEM=1')
$p = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "cloudbase-init install failed with exit code $($p.ExitCode)" }

$conf = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
Copy-Item -Force C:\Windows\Temp\vmb\cloudbase-init\cloudbase-init.conf          "$conf\cloudbase-init.conf"
Copy-Item -Force C:\Windows\Temp\vmb\cloudbase-init\cloudbase-init-unattend.conf "$conf\cloudbase-init-unattend.conf"
if (-not (Test-Path "$conf\Unattend.xml")) { throw 'cloudbase-init Unattend.xml missing' }
Set-Service -Name cloudbase-init -StartupType Automatic
"cloudbase-init $($msi.Name) installed and configured"
