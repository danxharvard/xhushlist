@echo off
rem Hushlist for Windows: double-click to install or update.
rem To remove: run  hushlist-windows.cmd uninstall
setlocal
set "HL_SELF=%~f0"
set "HL_ARGS="
if /i "%~1"=="uninstall" set "HL_ARGS=uninstall"

rem Ask for administrator rights if we don't have them yet. The path and arguments go
rem through environment variables so folder names with spaces or quotes can't break this.
net session >nul 2>&1
if errorlevel 1 (
  if defined HL_ARGS (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath $env:HL_SELF -ArgumentList $env:HL_ARGS"
  ) else (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath $env:HL_SELF"
  )
  if errorlevel 1 (
    echo Hushlist needs administrator rights to change the hosts file. Nothing was changed.
    pause
  )
  exit /b
)

set "PSARGS="
if defined HL_ARGS set "PSARGS=-Uninstall"
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}; try { $s = (New-Object Net.WebClient).DownloadString('https://hushlist.online/install/hushlist-windows.ps1') } catch { Write-Host 'Could not download Hushlist. Check your internet connection and try again.'; exit 1 }; & ([scriptblock]::Create($s)) %PSARGS%"
pause
