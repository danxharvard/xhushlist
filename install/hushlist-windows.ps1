# Hushlist for Windows (started by hushlist-windows.cmd, or hourly by Task Scheduler with -Update).
# Adds the blocklist to the hosts file between Hushlist markers (your own entries are left alone)
# and registers a scheduled task that runs every hour to:
#   1. install a newer version of this script, but only if it is signed with the Hushlist key
#   2. refresh the blocklist
#
# Don't edit this file by hand on GitHub: publish changes with scripts/release.py,
# which sets the version and signs it. Unsigned changes are rejected by every device.
param([switch]$Uninstall, [switch]$Update, [switch]$Version)

$HushlistVersion = 1

# BEGIN SIGNING KEY (written by scripts/release.py keygen)
$KeyModulus  = ''
$KeyExponent = ''
# END SIGNING KEY

if ($Version) { Write-Output $HushlistVersion; exit 0 }

$ErrorActionPreference = 'Stop'
$Site      = 'https://hushlist.online/'
$ListUrl   = $Site + 'lists/hushlist.txt'
$ScriptUrl = $Site + 'install/hushlist-windows.ps1'
$Hosts     = "$env:SystemRoot\System32\drivers\etc\hosts"
$AppDir    = "$env:ProgramData\Hushlist"
$LogFile   = "$AppDir\update.log"
$TaskName  = 'Hushlist hourly update'
$Begin     = '# >>> Hushlist BEGIN (managed, do not edit) >>>'
$End       = '# <<< Hushlist END <<<'

function Say($msg) { if (-not $Update) { Write-Host $msg } }
function Log($msg) {
  try {
    if (-not (Test-Path $AppDir)) { return }
    Add-Content -Path $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm') + '  ' + $msg)
    $lines = Get-Content $LogFile
    if ($lines.Count -gt 200) { $lines | Select-Object -Last 200 | Set-Content $LogFile }
  } catch {}
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# True if $Data matches the base64 signature in $SigText, using the key above.
function Test-Signed([byte[]]$Data, [string]$SigText) {
  if (-not $KeyModulus) { return $false }
  try {
    $p = New-Object System.Security.Cryptography.RSAParameters
    $p.Modulus  = [Convert]::FromBase64String($KeyModulus)
    $p.Exponent = [Convert]::FromBase64String($KeyExponent)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    $rsa.ImportParameters($p)
    $sig = [Convert]::FromBase64String($SigText.Trim())
    return $rsa.VerifyData($Data, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                           [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
  } catch { return $false }
}

# Download the published script and check its signature.
# Returns @{ Status = 'ok' | 'download' | 'signature'; Bytes = ... }
function Get-SignedScript {
  $bust = '?v=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  try {
    $wc = New-Object Net.WebClient
    $bytes = $wc.DownloadData($ScriptUrl + $bust)
    $sig = $wc.DownloadString($ScriptUrl + '.sig' + $bust)
  } catch { return @{ Status = 'download' } }
  if (-not (Test-Signed $bytes $sig)) { return @{ Status = 'signature' } }
  return @{ Status = 'ok'; Bytes = $bytes }
}

# Install a newer signed version of this script, then carry on with it.
function Invoke-SelfUpdate {
  if ($env:HUSHLIST_JUST_UPDATED) { return }
  $r = Get-SignedScript
  if ($r.Status -eq 'signature') { Log "Ignored an update that isn't signed with the Hushlist key."; return }
  if ($r.Status -ne 'ok') { return }
  $text = [Text.Encoding]::UTF8.GetString($r.Bytes)
  $m = [regex]::Match($text, '(?m)^\$HushlistVersion\s*=\s*(\d+)\s*$')
  if (-not $m.Success) { return }
  $v = [int]$m.Groups[1].Value
  if ($v -le $HushlistVersion) { return }
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) { Log "Ignored version ${v}: it failed a syntax check."; return }
  $current = "$AppDir\update.ps1"
  Copy-Item $current "$AppDir\update.prev.ps1" -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllBytes("$AppDir\update.new.ps1", $r.Bytes)
  Move-Item "$AppDir\update.new.ps1" $current -Force
  Log "Updated Hushlist from version $HushlistVersion to $v."
  $env:HUSHLIST_JUST_UPDATED = '1'
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $current -Update
  exit $LASTEXITCODE
}

if ($Update) { Invoke-SelfUpdate }

Say "Hushlist for Windows (version $HushlistVersion)"

# Keep the lines outside any previous Hushlist block
$current = [IO.File]::ReadAllLines($Hosts)
$keep = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($line in $current) {
  if ($line -eq $Begin) { $skip = $true; continue }
  if ($line -eq $End)   { $skip = $false; continue }
  if (-not $skip) { $keep.Add($line) }
}

$count = 0
if (-not $Uninstall) {
  Say 'Downloading blocklist...'
  $text = (New-Object Net.WebClient).DownloadString($ListUrl)
  $entries = $text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '0.0.0.0 *' }
  $count = @($entries).Count
  if ($count -lt 1000) { throw "Download looks wrong ($count entries). Nothing changed." }
  $keep.Add($Begin); $keep.AddRange([string[]]$entries); $keep.Add($End)
}

# Only touch the hosts file when something changed
if (($current -join "`n") -ne ($keep -join "`n")) {
  if (-not $Update) { Copy-Item $Hosts "$Hosts.hushlist-backup" -Force }
  [IO.File]::WriteAllLines($Hosts, $keep, (New-Object Text.UTF8Encoding $false))
  ipconfig /flushdns | Out-Null
  if ($Update) { Log "List updated: $count domains." }
}

if ($Update) { exit 0 }

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host 'Hushlist removed, including hourly updates.'
  Write-Host "Backup of your previous hosts file: $Hosts.hushlist-backup"
  exit 0
}

# Install the hourly updater: a signed copy of this script, run by a SYSTEM task
Say 'Installing the hourly updater...'
$r = Get-SignedScript
if ($r.Status -ne 'ok') {
  if ($r.Status -eq 'signature') { Write-Host "The updater download isn't signed with the Hushlist key, so it wasn't installed." }
  else { Write-Host "Couldn't download the updater. Check your connection and try again." }
  Write-Host "Your blocklist is in place, but it won't update by itself until you run this installer again."
  exit 1
}
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
[IO.File]::WriteAllBytes("$AppDir\update.ps1", $r.Bytes)
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$AppDir\update.ps1`" -Update"
$hourly   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
              -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$startup  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
$system   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $hourly, $startup `
  -Settings $settings -Principal $system -Force | Out-Null

Write-Host "Done. Blocking $count domains. Hushlist checks for list and app updates every hour."
Write-Host "Backup of your previous hosts file: $Hosts.hushlist-backup"
