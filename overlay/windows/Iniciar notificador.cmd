@echo off
setlocal
set "SCRIPT=%~dp0dsh-session-notifier-overlay.ps1"
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
endlocal
