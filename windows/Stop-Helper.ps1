$ErrorActionPreference='Stop'
$cfg=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
if($cfg.channel -notin @(1,2,3)){throw 'Expected channel 1, 2 or 3'}
$tray=Join-Path $PSScriptRoot 'MonitorSwitch-Tray.ps1'
$deviceInstalled=Join-Path $env:LOCALAPPDATA ('MonitorSwitch\Device'+$cfg.channel+'\MonitorSwitch-Windows.ps1')
$deviceTray=Join-Path $env:LOCALAPPDATA ('MonitorSwitch\Device'+$cfg.channel+'\MonitorSwitch-Tray.ps1')
$installed=Join-Path $env:LOCALAPPDATA ('MonitorSwitch\HP'+$cfg.channel+'\MonitorSwitch-Windows.ps1')
$local=Join-Path $PSScriptRoot 'MonitorSwitch-Windows.ps1'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'") {
  if(!$p.CommandLine -or $p.ProcessId -eq $PID){continue}
  $matches=$false
  foreach($path in @($installed,$local,$tray,$deviceInstalled,$deviceTray)) { if($p.CommandLine.IndexOf($path,[StringComparison]::OrdinalIgnoreCase) -ge 0){$matches=$true} }
  if(!$matches){continue}
  $owner=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
  if($owner.Sid -ne $sid){continue}
  Stop-Process -Id $p.ProcessId
  Write-Host ('Stopped MonitorSwitch helper '+$p.ProcessId)
}
