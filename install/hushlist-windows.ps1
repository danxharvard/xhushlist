# Hushlist for Windows (started by hushlist-windows.cmd, or hourly by Task Scheduler with -Update).
# Adds the blocklist to the hosts file between Hushlist markers (your own entries are left alone)
# and registers a scheduled task that runs every hour to:
#   1. install a newer version of this script, but only if it is signed with the Hushlist key
#   2. refresh the blocklist, downloading it only when it has changed
#
# Don't edit this file by hand on GitHub: publish changes with scripts/release.py,
# which sets the version and signs it. Unsigned changes are rejected by every device.
param([switch]$Uninstall, [switch]$Update, [switch]$Version, [switch]$SelfTest)

$HushlistVersion = 3

# BEGIN SIGNING KEY (written by scripts/release.py keygen)
$KeyModulus  = 'qzSpzSgrdFTXKGeywDtaD8xLoMj78Q2moYu2y0zef0jiBNdm8iZNHQDxf0H56zu96bCBLpm9LxRIrpqlX26hB9Aby1l5SmY3Tq9mlYZegC4rOSaT7nUxueZU+AMbZTyGJkaaTWaAlHYV8GNHRVhoi5lYWcVt4ln4+K/aVwN+Q8jwRS5r6aqo+jVRgIm9ZuGBZWD6hQeH6HvhRkYWUdNa8IdWm+nnjOMTCVF23jbTJ1usrGiL0Y31Ekp07vPh+9C2AL2f1Eya/WWKE5i0fMrtTFougeBL644Oc29xMYqMunFqbF+w/oeao4Jl2rNb8bJ9lPhPhbe4Dp7R2It206+WSCUBRJHW5RvDaV2qr48+sAkv8GW7Gmie/AomcvCOUSYiVyEg+cHxVU8RTByBKQW9zrMh1LBz7yZzNgTvuEELBBVZsoYt0drkjrOI3c+iedIA6SdZhgLfoFEF6bJqWoMjnymEM2vBEzOmcT1BSW5KlD5xjKRoqSN6yWcflm8WHUCN'
$KeyExponent = 'AQAB'
# END SIGNING KEY

if ($Version) { Write-Output $HushlistVersion; exit 0 }

$ErrorActionPreference = 'Stop'
$Site       = 'https://hushlist.online/'
$ListUrl    = $Site + 'lists/hushlist.txt'
$ScriptUrl  = $Site + 'install/hushlist-windows.ps1'
$Hosts      = "$env:SystemRoot\System32\drivers\etc\hosts"
$AppDir     = "$env:ProgramData\Hushlist"
$LogFile    = "$AppDir\update.log"
$StateFile  = "$AppDir\list.sha256"
$TaskName   = 'Hushlist hourly update'
$Begin      = '# >>> Hushlist BEGIN (managed, do not edit) >>>'
$End        = '# <<< Hushlist END <<<'
$MinEntries = 1000
$MaxEntries = 3000000
# Never block these, whatever the list says: the update server and names the system relies on.
$Protected  = '^0\.0\.0\.0\s+(hushlist\.online|www\.hushlist\.online|localhost|localhost\.localdomain|local|broadcasthost|ip6-localhost|ip6-loopback)\s*$'

function Say($msg) { if (-not $Update) { Write-Host $msg } }
function Log($msg) {
  try {
    if (-not (Test-Path $AppDir)) { return }
    Add-Content -Path $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm') + '  ' + $msg)
    if ((Get-Item $LogFile).Length -gt 100000) { Get-Content $LogFile -Tail 200 | Set-Content $LogFile }
  } catch {}
}
function Bust { '?v=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
try {   # older PCs don't enable TLS 1.2 by default; hushlist.online requires it
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

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

# Run by a candidate update before it is installed: it must be able to check its own
# signature with its own key, so it can still accept the update after it.
if ($SelfTest) {
  try {
    $ok = Test-Signed ([IO.File]::ReadAllBytes($PSCommandPath)) ([IO.File]::ReadAllText("$PSCommandPath.sig"))
  } catch { $ok = $false }
  if ($ok) { Write-Output $HushlistVersion; exit 0 } else { exit 1 }
}

function Get-Sha256([byte[]]$Data) {
  $h = [System.Security.Cryptography.SHA256]::Create()
  return (($h.ComputeHash($Data) | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Only SYSTEM and Administrators may change the updater folder (ProgramData lets any user
# create files in new folders by default, which would let them slip in their own update).
function Protect-AppDir {
  New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
  & icacls.exe $AppDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /T /C /Q | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Couldn't secure $AppDir" }
}

# Download the published script and check its signature.
# Returns @{ Status = 'ok' | 'download' | 'signature'; Bytes = ...; Sig = ... }
function Get-SignedScript {
  try {
    $wc = New-Object Net.WebClient
    $bytes = $wc.DownloadData($ScriptUrl + (Bust))
    $sig = $wc.DownloadString($ScriptUrl + '.sig' + (Bust))
  } catch { return @{ Status = 'download' } }
  if (-not (Test-Signed $bytes $sig)) { return @{ Status = 'signature' } }
  return @{ Status = 'ok'; Bytes = $bytes; Sig = $sig }
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

  $new = "$AppDir\update.new.ps1"
  Remove-Item $new, "$new.sig" -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllBytes($new, $r.Bytes)
  [IO.File]::WriteAllText("$new.sig", $r.Sig)
  # Run the candidate in its own PowerShell. Errors are relaxed around the call because Windows
  # PowerShell can turn a native program's error output into a hard error under 'Stop'.
  $ErrorActionPreference = 'Continue'
  $out = $null
  try { $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $new -SelfTest } catch {}
  $code = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($code -ne 0 -or "$out".Trim() -ne "$v") {
    Log "Ignored version ${v}: it failed its self-test."
    Remove-Item $new, "$new.sig" -Force -ErrorAction SilentlyContinue
    return
  }
  $current = "$AppDir\update.ps1"
  Copy-Item $current "$AppDir\update.prev.ps1" -Force -ErrorAction SilentlyContinue
  Move-Item $new $current -Force
  Remove-Item "$new.sig" -Force -ErrorAction SilentlyContinue
  Log "Updated Hushlist from version $HushlistVersion to $v."
  $env:HUSHLIST_JUST_UPDATED = '1'
  $ErrorActionPreference = 'Continue'
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $current -Update
  exit $LASTEXITCODE
}

if ($Update) {
  Protect-AppDir     # also fixes folders created by older versions
  Invoke-SelfUpdate
}

Say "Hushlist for Windows (version $HushlistVersion)"
$wc = New-Object Net.WebClient

# The list's checksum is tiny: compare it first and skip the 6 MB download when nothing changed.
$want = ''
if (-not $Uninstall) {
  try { $want = $wc.DownloadString($ListUrl + '.sha256' + (Bust)).Trim().ToLower() } catch {}
  if ($want -notmatch '^[0-9a-f]{64}$') { $want = '' }
  if ($Update -and $want) {
    $have = ''
    try { $have = ([IO.File]::ReadAllText($StateFile)).Trim() } catch {}
    if ($want -eq $have -and (Select-String -Path $Hosts -SimpleMatch $Begin -Quiet)) { exit 0 }
  }
}

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
  $data = $wc.DownloadData($ListUrl + (Bust))
  if ($want -and (Get-Sha256 $data) -ne $want) { throw "The download didn't match its checksum (it may be mid-update). Nothing changed." }
  $text = [Text.Encoding]::UTF8.GetString($data)
  $entries = @($text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '0.0.0.0 *' })
  $count = $entries.Count
  if ($count -lt $MinEntries -or $count -gt $MaxEntries) { throw "Download looks wrong ($count entries). Nothing changed." }
  $entries = @($entries | Where-Object { $_ -notmatch $Protected })
  $keep.Add($Begin); $keep.AddRange([string[]]$entries); $keep.Add($End)
}

# Only touch the hosts file when something changed
if (($current -join "`n") -ne ($keep -join "`n")) {
  if (-not $Update) { Copy-Item $Hosts "$Hosts.hushlist-backup" -Force }
  # Write a complete copy next to it, then swap it in, so a crash or power cut can
  # never leave a half-written hosts file.
  [IO.File]::WriteAllLines("$Hosts.hushlist-new", $keep, (New-Object Text.UTF8Encoding $false))
  Move-Item "$Hosts.hushlist-new" $Hosts -Force
  ipconfig /flushdns | Out-Null
  if ($Update) { Log "List updated: $count domains." }
}

if ($Update) {
  if ($want) { [IO.File]::WriteAllText($StateFile, $want) }
  exit 0
}

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
Protect-AppDir
Remove-Item "$AppDir\update.new.ps1", "$AppDir\update.new.ps1.sig" -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllBytes("$AppDir\update.ps1", $r.Bytes)
if ($want) { [IO.File]::WriteAllText($StateFile, $want) }
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
