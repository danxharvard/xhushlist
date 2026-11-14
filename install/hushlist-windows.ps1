# Hushlist for Windows (started by hushlist-windows.cmd, or hourly by Task Scheduler with -Update).
# Adds the blocklist to the hosts file between Hushlist markers (your own entries are left alone)
# and registers a scheduled task that runs every hour to:
#   1. install a newer version of this script, but only if it is signed with the Hushlist key
#   2. refresh the blocklist, downloading it only when it has changed
# The published list is one domain per line; this script adds the 0.0.0.0 for the hosts file.
#
# Don't edit this file by hand on GitHub: publish changes with scripts/release.py,
# which sets the version and signs it. Unsigned changes are rejected by every device.
param([switch]$Uninstall, [switch]$Update, [switch]$Version, [switch]$SelfTest)

$HushlistVersion = 4

# BEGIN SIGNING KEY (written by scripts/release.py keygen)
$KeyModulus  = 'ubfJxkBNrz9SkH30P9G2isgJCDb7j2MLB2v1b1lXbt6nt2rRZzJ/K7TgApUmrXfCCa3AAXNyHzcomVUFEdUlc0GH3GM4J7Onq88rjfHewv0zPtj/BHhhUivnt9AsvSauBVHDKVKh09a5zSEb06y95oOquu5Gxdq1CqlH3UPNKwxxw9aynecGJBJ8Sm6DJY9h2cuIcNu9BVAatm8ArdLqLi5QsVuL18V3pZTJcDzoQcsT8FwKDqZNqIeiV1h7hIeRz83CEDzBokNWB9LTkuIzdHsLx4sbHYh8tNx/R29bJtaxddE2V6ms5AGwwePoYIbF9jfyOHwXU1mQtaGdH876S4inWgOzH9vGZbFWwsZzrRu46ocg+Eouhzl1wsiXENYps6vviumnjrYR9WC0cCh4vtLJntL92Apbdpl9ux31VoioBG2SQwDhqkY5PKBAXDFH1hWubHLFsv5tCgMr4muPpW05YT/hQfQtLj3tMZiT6elWWANK3d+F7x5/Df55u5Mz'
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

# Turn the downloaded list into hosts lines. Accepts plain domains or hosts lines, skips
# comments, lowercases, drops anything that isn't a valid domain name, and removes duplicates.
$DomainPattern = '^[a-z0-9_]([a-z0-9_-]*[a-z0-9])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9])?)+$'
function ConvertTo-HostsLines([string]$Text) {
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $out  = New-Object 'System.Collections.Generic.List[string]'
  $rx   = New-Object System.Text.RegularExpressions.Regex($DomainPattern, 'Compiled')
  $n = 0
  foreach ($raw in $Text.Split("`n")) {
    if ((++$n % 12000) -eq 0) { Step-Frame }
    $line = $raw.Trim()
    if ($line.Length -eq 0 -or $line[0] -eq '#' -or $line[0] -eq '!') { continue }
    $parts = $line.Split([char[]]@(' ', "`t"), [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -ge 2 -and ($parts[0] -eq '0.0.0.0' -or $parts[0] -eq '127.0.0.1')) { $d = $parts[1] }
    elseif ($parts.Count -eq 1) { $d = $parts[0] }
    else { continue }
    $d = $d.ToLowerInvariant()
    if ($d.Length -gt 253 -or -not $rx.IsMatch($d)) { continue }
    if ($seen.Add($d)) { $out.Add('0.0.0.0 ' + $d) }
  }
  return ,$out
}

# ---------- How the installer looks: banner and animated progress ----------
# Only when someone is watching in a console window; the hourly task stays silent.
$Fancy = (-not $Update) -and ($Host.Name -eq 'ConsoleHost') -and (-not $env:HUSHLIST_PLAIN)
try { if ([Console]::IsOutputRedirected) { $Fancy = $false } } catch { $Fancy = $false }
$SpinTitle = if ($Uninstall) { 'Removing, please wait' } else { 'Installing, please wait' }
$script:SpinStep = ''
$script:SpinI = 0
$script:Spinning = $false
$Glyphs = @{
  H = @('1   1', '1   1', '11111', '1   1', '1   1')
  U = @('1   1', '1   1', '1   1', '1   1', ' 111 ')
  S = @(' 1111', '1    ', ' 111 ', '    1', '1111 ')
  L = @('1    ', '1    ', '1    ', '1    ', '11111')
  I = @('11111', '  1  ', '  1  ', '  1  ', '11111')
  T = @('11111', '  1  ', '  1  ', '  1  ', '  1  ')
}

function Show-Banner {
  if (-not $Fancy) { Say "Hushlist for Windows (version $HushlistVersion)"; return }
  $colours = 'Cyan', 'Cyan', 'DarkCyan', 'Blue', 'DarkBlue'
  $rows = foreach ($r in 0..4) { (('HUSHLIST'.ToCharArray()) | ForEach-Object { $Glyphs[[string]$_][$r] + '  ' }) -join '' }
  $rnd = New-Object Random
  try {
    [Console]::CursorVisible = $false
    Write-Host ''
    $top = [Console]::CursorTop
    for ($f = 1; $f -le 7; $f++) {          # digits flicker a few times, then settle
      [Console]::SetCursorPosition(0, $top)
      for ($r = 0; $r -lt 5; $r++) {
        $line = -join ($rows[$r].ToCharArray() | ForEach-Object { if ($_ -eq '1') { [char](48 + $rnd.Next(10)) } else { ' ' } })
        Write-Host ('  ' + $line) -ForegroundColor $colours[$r]
      }
      if ($f -lt 7) { Start-Sleep -Milliseconds 60 }
    }
  } catch {}
  Write-Host "  Quiet the noise.  -  Windows installer, version $HushlistVersion" -ForegroundColor DarkGray
  Write-Host ''
  try { [Console]::CursorVisible = $true } catch {}
}

function Clear-Line {
  $w = 79
  try { $w = [Console]::WindowWidth - 1 } catch {}
  Write-Host ("`r" + (' ' * $w) + "`r") -NoNewline
}

# One frame: a spinner, the title with a highlight sweeping across it, and the current step.
function Step-Frame {
  if (-not $script:Spinning) { return }
  $frames = '|', '/', '-', '\'
  $msg = $SpinTitle
  $i = $script:SpinI
  $p = $i % ($msg.Length + 10)
  Write-Host "`r  " -NoNewline
  Write-Host $frames[$i % 4] -NoNewline -ForegroundColor Cyan
  Write-Host '  ' -NoNewline
  if ($p -lt $msg.Length) {
    Write-Host $msg.Substring(0, $p) -NoNewline -ForegroundColor DarkCyan
    Write-Host $msg[$p] -NoNewline -ForegroundColor White
    Write-Host $msg.Substring($p + 1) -NoNewline -ForegroundColor DarkCyan
  } else {
    Write-Host $msg -NoNewline -ForegroundColor DarkCyan
  }
  Write-Host ('   ' + $script:SpinStep + '   ') -NoNewline -ForegroundColor DarkGray
  $script:SpinI++
}
function Start-Spin([string]$Step) {
  if (-not $Fancy) { Say "$Step..."; return }
  try { [Console]::CursorVisible = $false } catch {}
  $script:SpinStep = $Step; $script:Spinning = $true; Step-Frame
}
function Stop-Spin {
  if ($Fancy -and $script:Spinning) { Clear-Line; try { [Console]::CursorVisible = $true } catch {} }
  $script:Spinning = $false
}
function Complete-Spin([string]$Done) {
  Stop-Spin
  if ($Fancy) { Write-Host '  ' -NoNewline; Write-Host ([char]0x221A) -NoNewline -ForegroundColor Green; Write-Host " $Done" }
  else { Say $Done }
}
function Stop-WithError([string]$Message) {
  Stop-Spin
  if ($Fancy) { Write-Host '  x ' -NoNewline -ForegroundColor Red; Write-Host $Message } else { Write-Host $Message }
  Log $Message
  exit 1
}
# Download while keeping the animation moving.
function Get-Download([string]$Url) {
  $client = New-Object Net.WebClient
  $task = $client.DownloadDataTaskAsync($Url)
  while (-not $task.IsCompleted) { Step-Frame; Start-Sleep -Milliseconds 70 }
  if ($task.IsFaulted -or $task.IsCanceled) { return $null }
  return ,$task.Result
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

# One run at a time (the hourly task and a manual install could otherwise overlap).
$mutex = New-Object System.Threading.Mutex($false, 'Global\HushlistUpdate')
try { $haveLock = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
if (-not $haveLock) { Say 'Hushlist is already updating on this PC. Try again in a minute.'; exit 0 }

Show-Banner
$wc = New-Object Net.WebClient
if ($Uninstall) { Start-Spin 'removing the blocklist' } else { Start-Spin 'downloading the blocklist' }

# The list's checksum is tiny: compare it first and skip the 6 MB download when nothing changed.
$want = ''
if (-not $Uninstall) {
  try { $want = $wc.DownloadString($ListUrl + '.sha256' + (Bust)).Trim().ToLower() } catch {}
  if ($want -notmatch '^[0-9a-f]{64}$') { $want = '' }
  if ($Update -and $want) {
    $have = ''
    try { $have = ([IO.File]::ReadAllText($StateFile)).Trim() } catch {}
    if ($want -eq $have -and (Select-String -Path $Hosts -SimpleMatch $Begin -Quiet)) { Stop-Spin; exit 0 }
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
  $data = Get-Download ($ListUrl + (Bust))
  if ($null -eq $data) { Stop-WithError "Couldn't download the blocklist. Check your connection and try again." }
  if ($want -and (Get-Sha256 $data) -ne $want) { Stop-WithError "The download didn't match its checksum (it may be mid-update). Nothing changed." }
  Complete-Spin ('Downloaded the latest blocklist ({0:N1} MB)' -f ($data.Length / 1e6))
  Start-Spin 'checking every domain'
  $text = [Text.Encoding]::UTF8.GetString($data)
  $entries = ConvertTo-HostsLines $text
  $count = $entries.Count
  if ($count -lt $MinEntries -or $count -gt $MaxEntries) { Stop-WithError "Download looks wrong ($count entries). Nothing changed." }
  Complete-Spin ('Checked {0:N0} domains' -f $count)
  Start-Spin 'updating your hosts file'
  $entries = @($entries.Where({ $_ -notmatch $Protected }))
  $keep.Add($Begin); $keep.AddRange([string[]]$entries); $keep.Add($End)
}

# Only touch the hosts file when something changed
if (($current -join "`n") -ne ($keep -join "`n")) {
  if (-not $Update) { Copy-Item $Hosts "$Hosts.hushlist-backup" -Force }
  # Write a complete copy next to it, then swap it in, so a crash or power cut can
  # never leave a half-written hosts file.
  [IO.File]::WriteAllLines("$Hosts.hushlist-new", $keep, (New-Object Text.UTF8Encoding $false))
  # Antivirus can hold the hosts file for a moment: retry a few times before giving up.
  $moved = $false
  for ($i = 1; $i -le 5 -and -not $moved; $i++) {
    try { Move-Item "$Hosts.hushlist-new" $Hosts -Force; $moved = $true }
    catch { Start-Sleep -Seconds 2 }
  }
  if (-not $moved) {
    Remove-Item "$Hosts.hushlist-new" -Force -ErrorAction SilentlyContinue
    Stop-WithError 'The hosts file is in use by another program. Nothing changed; Hushlist will try again next hour.'
  }
  ipconfig /flushdns | Out-Null
  if ($Update) { Log "List updated: $count domains." }
}
if ($Uninstall) { Complete-Spin 'Blocklist removed from your hosts file' }
else { Complete-Spin 'Hosts file updated (your own entries are untouched)' }

if ($Update) {
  if ($want) { [IO.File]::WriteAllText($StateFile, $want) }
  exit 0
}

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
  Complete-Spin 'Hourly updates switched off'
  Write-Host ''
  if ($Fancy) { Write-Host '  Hushlist removed.' -ForegroundColor Cyan } else { Write-Host 'Hushlist removed, including hourly updates.' }
  Write-Host "  Backup of your previous hosts file: $Hosts.hushlist-backup"
  exit 0
}

# Install the hourly updater: a signed copy of this script, run by a SYSTEM task
Start-Spin 'switching on hourly updates'
$r = Get-SignedScript
if ($r.Status -ne 'ok') {
  Stop-Spin
  if ($r.Status -eq 'signature') { Write-Host "  The updater download isn't signed with the Hushlist key, so it wasn't installed." -ForegroundColor Red }
  else { Write-Host "  Couldn't download the updater. Check your connection and try again." -ForegroundColor Red }
  Write-Host "  Your blocklist is in place, but it won't update by itself until you run this installer again."
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

Complete-Spin 'Hourly updates switched on'
if ($Fancy) {
  Write-Host ''
  Write-Host '  Done. ' -NoNewline -ForegroundColor Cyan
  Write-Host ('Hushlist is blocking {0:N0} domains on this PC.' -f $count)
  Write-Host '  It checks for list and app updates every hour. Backup of your old hosts file:' -ForegroundColor DarkGray
  Write-Host "  $Hosts.hushlist-backup" -ForegroundColor DarkGray
  Write-Host ''
} else {
  Write-Host "Done. Blocking $count domains. Hushlist checks for list and app updates every hour."
  Write-Host "Backup of your previous hosts file: $Hosts.hushlist-backup"
}
