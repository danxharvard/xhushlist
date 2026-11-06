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
set "PS_SCRIPT=%TEMP%\hushlist-windows-%RANDOM%.ps1"
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('__SITE_URL__install/hushlist-windows.ps1', '%PS_SCRIPT%')"
if errorlevel 1 (
  echo Failed to download the Hushlist installer.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %ARGS%
set "RESULT=%ERRORLEVEL%"
del /q "%PS_SCRIPT%" >nul 2>&1
pause
exit /b %RESULT%
