$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
 . (Join-Path $PSScriptRoot 'Configuration-UI.ps1')
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (!(Test-Path -LiteralPath $cfgPath)) {
    if (!(Show-DeviceSetup $cfgPath)) { exit }
}
$cfg = Convert-DeviceProfile (Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json)
$script:restartTray = $false
$mutex = [Threading.Mutex]::new($false, ('Local\MonitorSwitch-Tray-' + $cfg.channel))
try { $owner = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owner = $true }
if (!$owner) { $mutex.Dispose(); exit }
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class TrayArtwork {
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    public static Icon Create() {
        using(var bitmap = new Bitmap(32,32)) using(var g = Graphics.FromImage(bitmap)) {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using(var background = new SolidBrush(Color.FromArgb(45,108,240))) g.FillEllipse(background,1,1,30,30);
            using(var p = new Pen(Color.White,2)) {
                g.DrawRectangle(p,7,8,18,12); g.DrawLine(p,16,20,16,24); g.DrawLine(p,11,24,21,24);
                g.DrawLine(p,10,13,21,13); g.DrawLine(p,18,10,21,13); g.DrawLine(p,18,16,21,13);
            }
            IntPtr handle = bitmap.GetHicon();
            try { using(var icon=Icon.FromHandle(handle)) return (Icon)icon.Clone(); }
            finally { DestroyIcon(handle); }
        }
    }
}
'@ -ReferencedAssemblies System.Drawing
$script:worker = $null
function Start-Worker {
    if ($script:worker -and !$script:worker.HasExited) { return }
    $file = Join-Path $PSScriptRoot 'MonitorSwitch-Windows.ps1'
    $script:worker = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $file + '"') -WindowStyle Hidden -RedirectStandardError (Join-Path $PSScriptRoot "helper-errors.log") -PassThru
}
function Stop-Worker {
    if ($script:worker -and !$script:worker.HasExited) {
        $script:worker.Kill(); $script:worker.WaitForExit(3000) | Out-Null
    }
    $script:worker = $null
}
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = [TrayArtwork]::Create()
$tray.Text = 'MonitorSwitch - Device ' + $cfg.channel
$menu = New-Object Windows.Forms.ContextMenuStrip
$title = $menu.Items.Add('MonitorSwitch | Device ' + $cfg.channel); $title.Enabled = $false
$status = $menu.Items.Add('Starting...'); $status.Enabled = $false
$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) | Out-Null
$follow = $menu.Items.Add('Follow Easy-Switch'); $follow.Checked = $true
$follow.Add_Click({
    if ($script:worker -and !$script:worker.HasExited) { Stop-Worker } else { Start-Worker }
})
$autostart = $menu.Items.Add('Launch at sign-in')
$autostart.Add_Click({
    try {
        if (Test-Path -LiteralPath $script:startupLink) {
            & (Join-Path $PSScriptRoot 'Setup-Autostart.ps1') -Disable
        } else {
            & (Join-Path $PSScriptRoot 'Setup-Autostart.ps1')
        }
        $autostart.Checked = Test-Path -LiteralPath $script:startupLink
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'MonitorSwitch') | Out-Null }
})
$setup = $menu.Items.Add('Setup device...')
$setup.Add_Click({
    $wasRunning = $script:worker -and !$script:worker.HasExited
    Stop-Worker
    try {
        if (Show-DeviceSetup $cfgPath) {
            if (Test-Path -LiteralPath $script:startupLink) {
                & (Join-Path $PSScriptRoot 'Setup-Autostart.ps1')
                $newCfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
                if ($newCfg.channel -ne $cfg.channel) { Remove-Item -LiteralPath $script:startupLink }
            }
            $script:restartTray = $true
            [Windows.Forms.Application]::ExitThread()
        } elseif ($wasRunning) { Start-Worker }
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'MonitorSwitch') | Out-Null; if ($wasRunning) { Start-Worker } }
})
$diagnostics = New-Object Windows.Forms.ToolStripMenuItem('Diagnostics')
$logs = $diagnostics.DropDownItems.Add('Open logs folder')
$logs.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $PSScriptRoot + '"') })
$collect = $diagnostics.DropDownItems.Add('Export diagnostics...')
$collect.Add_Click({
    try { & (Join-Path $PSScriptRoot 'Export-Diagnostics.ps1') }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'MonitorSwitch') | Out-Null }
})
$menu.Items.Add($diagnostics) | Out-Null
$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) | Out-Null
$quit = $menu.Items.Add('Quit MonitorSwitch')
$quit.Add_Click({ [Windows.Forms.Application]::ExitThread() })
$tray.ContextMenuStrip = $menu
$script:startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) ('MonitorSwitch-Device' + $cfg.channel + '.lnk')
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    $running = $script:worker -and !$script:worker.HasExited
    $follow.Checked = $running
    $status.Text = if ($running) { 'Ready | Easy-Switch enabled' } else { 'Paused or helper stopped' }
    $autostart.Checked = Test-Path -LiteralPath $script:startupLink
})
try {
    Start-Worker
    $autostart.Checked = Test-Path -LiteralPath $script:startupLink
    $tray.Visible = $true; $timer.Start()
    [Windows.Forms.Application]::Run()
} finally {
    $timer.Stop(); $timer.Dispose(); Stop-Worker
    $tray.Visible = $false; $tray.Icon.Dispose(); $tray.Dispose(); $menu.Dispose()
    $mutex.ReleaseMutex(); $mutex.Dispose()
}

if ($script:restartTray) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList ('-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'MonitorSwitch-Tray.ps1') + '"') -WindowStyle Hidden
}
