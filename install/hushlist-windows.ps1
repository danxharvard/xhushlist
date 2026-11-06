# Hushlist for Windows (started by hushlist-windows.cmd, or hourly by Task Scheduler with -Update).
# Adds the blocklist to the hosts file between Hushlist markers (your own entries are left alone)
# and registers a scheduled task that refreshes it every hour.
param([switch]$Uninstall, [switch]$Update)

$ErrorActionPreference = 'Stop'
$ListUrl   = '__SITE_URL__lists/hushlist.txt'
$Hosts     = "$env:SystemRoot\System32\drivers\etc\hosts"
$AppDir    = "$env:ProgramData\Hushlist"
$TaskName  = 'Hushlist hourly update'
$Begin     = '# >>> Hushlist BEGIN (managed, do not edit) >>>'
$End       = '# <<< Hushlist END <<<'

function Say($msg) { if (-not $Update) { Write-Host $msg } }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Say 'Hushlist for Windows'

# Keep the lines outside any previous Hushlist block
$current = [IO.File]::ReadAllLines($Hosts)
$keep = New-Object System.Collections.Generic.List[string]
$skip = $false
foreach ($line in $current) {
  if ($line -eq $Begin) {
    if ($skip) { throw 'The hosts file contains nested Hushlist markers. Nothing changed.' }
    $skip = $true
    continue
  }
  if ($line -eq $End) {
    if (-not $skip) { throw 'The hosts file contains an unmatched Hushlist end marker. Nothing changed.' }
    $skip = $false
    continue
  }
  if (-not $skip) { $keep.Add($line) }
}
if ($skip) { throw 'The hosts file contains an incomplete Hushlist block. Nothing changed.' }

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
}

if ($Update) { exit 0 }

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item $AppDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host 'Hushlist removed, including hourly updates.'
  Write-Host "Backup of your previous hosts file: $Hosts.hushlist-backup"
  exit 0
}

# Install the hourly updater (runs as SYSTEM, hidden, also at startup)
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if (-not $PSCommandPath -or -not (Test-Path -LiteralPath $PSCommandPath)) {
  throw 'Cannot locate the installer script to install the local updater.'
}
Copy-Item -LiteralPath $PSCommandPath -Destination "$AppDir\update.ps1" -Force
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

Write-Host "Done. Blocking $count domains, and checking for updates every hour."
Write-Host "Backup of your previous hosts file: $Hosts.hushlist-backup"
