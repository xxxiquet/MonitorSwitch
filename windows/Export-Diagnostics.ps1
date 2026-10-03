$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object Windows.Forms.SaveFileDialog
$dialog.Filter = 'ZIP archive (*.zip)|*.zip'
$dialog.FileName = 'MonitorSwitch-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip'
if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { $dialog.Dispose(); return }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('MonitorSwitch-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    foreach ($name in @('diagnostic.log','switch-events.log','helper-errors.log')) {
        $path = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $temp }
    }
    $cfg = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
    @('MonitorSwitch 0.9.3', ('Device: ' + $cfg.channel), ('PowerShell: ' + $PSVersionTable.PSVersion), ('Windows: ' + [Environment]::OSVersion.VersionString), ('Language mode: ' + $ExecutionContext.SessionState.LanguageMode), 'Configuration and pairing keys are excluded. Logs may contain local IP addresses and device identifiers.') | Set-Content -LiteralPath (Join-Path $temp 'summary.txt')
    Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $dialog.FileName -Force
    [Windows.Forms.MessageBox]::Show('Diagnostics saved. Review the logs before sharing: they may contain local IP addresses and device identifiers.','MonitorSwitch') | Out-Null
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue; $dialog.Dispose() }
