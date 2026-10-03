@echo off
cd /d "%~dp0"
echo Quit MonitorSwitch from the tray before starting this diagnostic session.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0MonitorSwitch-Windows.ps1"
pause
