$ErrorActionPreference = 'Stop'
$channel = [int](Read-Host 'Device number (1 or 3)')
if ($channel -notin @(1,3)) { throw 'Device number must be 1 or 3.' }
$macIP = Read-Host 'Device 2 LAN IPv4 address'
$address = $null
if (![Net.IPAddress]::TryParse($macIP,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Enter a valid IPv4 address.' }
$key = Read-Host 'Pairing key for this device (from the private setup package)'
if ($key -notmatch '^[a-fA-F0-9]{64}$') { throw 'Pairing key must contain 64 hexadecimal characters.' }
@{channel=$channel;macIP=$macIP;port=25347;key=$key.ToLowerInvariant()} | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'config.json')
Write-Host 'Device configured. Run Start.cmd to show the tray icon.'
