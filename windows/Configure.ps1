$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Configuration-UI.ps1')
try { Show-DeviceSetup (Join-Path $PSScriptRoot 'config.json') | Out-Null }
catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'MonitorSwitch') | Out-Null }
