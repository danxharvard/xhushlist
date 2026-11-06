@echo off
rem Hushlist for Windows: double-click to install or update.
rem To remove: run  hushlist-windows.cmd uninstall
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
  exit /b
)
set "ARGS="
if /i "%~1"=="uninstall" set "ARGS=-Uninstall"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((New-Object Net.WebClient).DownloadString('https://hushlist.online/install/hushlist-windows.ps1'))) %ARGS%"
pause
