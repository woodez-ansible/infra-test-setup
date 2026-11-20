# One round of Windows Update via the built-in Windows Update Agent API. Packer runs this
# elevated (a scheduled task as 'ansible'): the API refuses downloads/installs from a plain
# remote WinRM session. Rounds are separated by reboots; the template runs four.
$ErrorActionPreference = 'Stop'
$session  = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$result   = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

$updates = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($u in $result.Updates) {
  # Defender definitions change every few hours; they don't belong in a golden image
  if ($u.Categories | Where-Object { $_.Name -eq 'Definition Updates' }) { continue }
  if (-not $u.EulaAccepted) { $u.AcceptEula() }
  [void]$updates.Add($u)
}

"Updates to install this round: $($updates.Count)"
if ($updates.Count -eq 0) { 'Windows is up to date.'; exit 0 }
foreach ($u in $updates) { " - $($u.Title)" }

$downloader = $session.CreateUpdateDownloader()
$downloader.Updates = $updates
$dl = $downloader.Download()
"Download result: $($dl.ResultCode) (2 = succeeded)"

$installer = $session.CreateUpdateInstaller()
$installer.Updates = $updates
$in = $installer.Install()
"Install result: $($in.ResultCode) (2 = succeeded, 3 = succeeded with errors); reboot required: $($in.RebootRequired)"
if ($in.ResultCode -notin 2, 3) { throw "Windows Update install failed (result $($in.ResultCode))" }
