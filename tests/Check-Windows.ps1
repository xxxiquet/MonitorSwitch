$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$errorsFound = $false
foreach ($file in Get-ChildItem (Join-Path $root 'windows') -Filter '*.ps1') {
    if ($file.Name -eq 'MonitorSwitch-Capture.ps1') { continue }
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { $errors; $errorsFound = $true }
}
if ($errorsFound) { throw 'PowerShell syntax validation failed.' }
if ($env:OS -eq 'Windows_NT') {
    $text = Get-Content -LiteralPath (Join-Path $root 'windows/MonitorSwitch-Windows.ps1') -Raw
    $source = [regex]::Match($text,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    if (!$source) { throw 'Native helper source not found.' }
    Add-Type -TypeDefinition $source
    if ([MonitorSwitchReturnListener]::Authenticate('{}', [byte[]](1..32), 1000)) { throw 'Malformed command was accepted.' }
    $tray = Get-Content -LiteralPath (Join-Path $root 'windows/MonitorSwitch-Tray.ps1') -Raw
    $art = [regex]::Match($tray,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition $art -ReferencedAssemblies System.Drawing
    $icon = [TrayArtwork]::Create()
    if ($icon.Width -ne 32 -or $icon.Height -ne 32) { throw 'Invalid tray icon dimensions.' }
    $icon.Dispose()
}
Write-Host 'Windows syntax and available native checks passed.'
