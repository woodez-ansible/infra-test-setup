# Runs as SYSTEM (scheduled by finalize.ps1). Removes everything that existed only for
# the build, then generalizes the image with sysprep and shuts down.
$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\Windows\Temp\vmb-finalize.log -Force
Start-Sleep -Seconds 10          # let Packer's WinRM call return

# Packer's build-only WinRM access: HTTP listener, Basic auth, unencrypted traffic
winrm delete 'winrm/config/Listener?Address=*+Transport=HTTP'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'
winrm set winrm/config/service/auth '@{Basic="false"}'
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

# Automatic logon (and any stored logon password) used only for the first build logon
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value '0'
Remove-ItemProperty -Path $wl -Name DefaultPassword -ErrorAction SilentlyContinue

# Built-in Administrator isn't used: 'ansible' is the admin
Disable-LocalUser -Name Administrator

# Answer-file copies Windows Setup keeps (passwords are already masked there, but they
# have no use in the image)
Remove-Item -Force C:\Windows\Panther\unattend.xml, C:\Windows\Panther\Unattend\*.xml -ErrorAction SilentlyContinue

Unregister-ScheduledTask -TaskName 'vmb-finalize' -Confirm:$false
Get-ChildItem C:\Windows\Temp\vmb -Exclude scripts | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Stop-Transcript
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /generalize /oobe /shutdown /quiet `
  /unattend:"C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
