param([switch]$Disable)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
if ($cfg.channel -notin @(1,3)) { throw 'Device number must be 1 or 3.' }
$linkPath = Join-Path ([Environment]::GetFolderPath('Startup')) ('MonitorSwitch-Device' + $cfg.channel + '.lnk')
if ($Disable) {
    if (Test-Path -LiteralPath $linkPath) { Remove-Item -LiteralPath $linkPath }
    Write-Host 'Launch at sign-in disabled for this user.'
    return
}
$target = Join-Path $env:LOCALAPPDATA ('MonitorSwitch\Device' + $cfg.channel)
New-Item -ItemType Directory -Path $target -Force | Out-Null
foreach ($name in @('MonitorSwitch-Tray.ps1','MonitorSwitch-Windows.ps1','config.json','Setup-Autostart.ps1','Export-Diagnostics.ps1','README.md')) {
    $source = Join-Path $PSScriptRoot $name; $dest = Join-Path $target $name
    if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($dest)) { Copy-Item -LiteralPath $source -Destination $dest -Force }
}
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($linkPath)
$link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$link.Arguments = '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $target 'MonitorSwitch-Tray.ps1') + '"'
$link.WorkingDirectory = $target; $link.WindowStyle = 7
$link.Description = 'MonitorSwitch tray application for Device ' + $cfg.channel
$link.Save()
Write-Host 'Launch at sign-in enabled for this user.'
