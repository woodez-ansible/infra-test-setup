# Packer's shutdown_command. Anything started from a WinRM session dies with it, so the
# real work (finalize-run.ps1: remove Packer's WinRM access, then sysprep) runs as a
# one-off scheduled task under SYSTEM. This script returns immediately.
$ErrorActionPreference = 'Stop'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\vmb\scripts\finalize-run.ps1'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'vmb-finalize' -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName 'vmb-finalize'
'finalize scheduled; sysprep will shut the VM down'
