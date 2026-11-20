# Shrink the image: drop superseded components and the update cache, then TRIM so the
# qcow2 (discard=unmap) gives the freed space back.
$ErrorActionPreference = 'Continue'
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force C:\Windows\SoftwareDistribution\Download\* -ErrorAction SilentlyContinue
Start-Service -Name wuauserv -ErrorAction SilentlyContinue
Optimize-Volume -DriveLetter C -ReTrim -Verbose
"cleanup done; C: free: {0:N1} GiB" -f ((Get-PSDrive C).Free / 1GB)
