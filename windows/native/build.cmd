@echo off
setlocal
set "ROOT=%~dp0..\.."
set "OUT=%ROOT%\build\windows-native"
if not exist "%OUT%" mkdir "%OUT%"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" exit /b 1
"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ /warnaserror+ /out:"%OUT%\MonitorSwitch.exe" /win32icon:"%ROOT%\assets\MonitorSwitch.ico" /win32manifest:"%~dp0App.manifest" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:System.Management.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "%~dp0Native.cs" "%~dp0Program.cs"
exit /b %errorlevel%
