@echo off
cd /d "%~dp0"
start "" powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0MonitorSwitch-Tray.ps1"
