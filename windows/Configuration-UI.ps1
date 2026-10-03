Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
function Convert-DeviceProfile($Profile) {
    if ($Profile.deviceType -and $Profile.deviceType -ne 'Windows') { throw 'Configure a macOS device in the MonitorSwitch menu-bar app.' }
    $macChannel = if ($Profile.macChannel) { [int]$Profile.macChannel } else { 2 }
    if ([int]$Profile.channel -notin @(1,2,3) -or $macChannel -notin @(1,2,3) -or [int]$Profile.channel -eq $macChannel) { throw 'Choose different device numbers for this Windows computer and the macOS coordinator.' }
    $address = $null
    if (![Net.IPAddress]::TryParse([string]$Profile.macIP,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Enter a valid coordinator IPv4 address.' }
    if ([string]$Profile.key -notmatch '^[a-fA-F0-9]{64}$') { throw 'Import the private Windows profile exported by the macOS app, or enter its 64-character pairing key.' }
    $port = if ($Profile.port) { [int]$Profile.port } else { 25347 }
    $inputCode = if ($Profile.returnInput) { [int]$Profile.returnInput } else { 16 }
    if ($port -lt 1 -or $port -gt 65535 -or $inputCode -lt 1 -or $inputCode -gt 255) { throw 'Invalid port or monitor input code.' }
    $model = if ($Profile.monitorModel) { [string]$Profile.monitorModel } else { 'G274QPF' }
    if (![string]::IsNullOrWhiteSpace($model)) {
        return [pscustomobject]@{deviceType='Windows';channel=[int]$Profile.channel;macChannel=$macChannel;macIP=$address.ToString();port=$port;key=([string]$Profile.key).ToLowerInvariant();returnInput=$inputCode;monitorModel=$model.Trim()}
    }
    throw 'Enter the monitor name as shown by Windows.'
}
function Show-DeviceSetup([string]$ConfigPath) {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'MonitorSwitch | Device setup'; $form.ClientSize = New-Object Drawing.Size(510,440)
    $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $controls = @{}
    $labels = @('System','This device','macOS coordinator','Coordinator IPv4 address','Pairing key','Coordinator monitor input','Windows monitor name','UDP port')
    $fields = @('deviceType','channel','macChannel','macIP','key','returnInput','monitorModel','port')
    for ($i=0; $i -lt $fields.Count; $i++) {
        $label = New-Object Windows.Forms.Label; $label.Text = $labels[$i]; $label.SetBounds(20,25+$i*36,190,25); $form.Controls.Add($label)
        if ($i -lt 3) {
            $control = New-Object Windows.Forms.ComboBox; $control.DropDownStyle = 'DropDownList'
            if ($i -eq 0) { $control.Items.AddRange(@('Windows','macOS')) } else { $control.Items.AddRange(@('1','2','3')) }
        } else { $control = New-Object Windows.Forms.TextBox }
        $control.SetBounds(220,20+$i*36,265,26); $form.Controls.Add($control); $controls[$fields[$i]]=$control
    }
    $controls.key.UseSystemPasswordChar = $true
    $errorLabel = New-Object Windows.Forms.Label; $errorLabel.ForeColor = [Drawing.Color]::Firebrick; $errorLabel.SetBounds(20,320,465,65); $form.Controls.Add($errorLabel)
    $import = New-Object Windows.Forms.Button; $import.Text='Import profile...'; $import.SetBounds(20,395,140,30); $form.Controls.Add($import)
    $save = New-Object Windows.Forms.Button; $save.Text='Save'; $save.SetBounds(300,395,85,30); $form.Controls.Add($save)
    $cancel = New-Object Windows.Forms.Button; $cancel.Text='Cancel'; $cancel.SetBounds(400,395,85,30); $cancel.DialogResult='Cancel'; $form.Controls.Add($cancel); $form.CancelButton=$cancel
    $fill = {
        param($profile)
        $defaults = @{deviceType='Windows';channel=1;macChannel=2;macIP='';key='';returnInput=16;monitorModel='G274QPF';port=25347}
        foreach ($field in $fields) { $value = if ($null -ne $profile.$field -and [string]$profile.$field -ne '') { $profile.$field } else { $defaults[$field] }; $controls[$field].Text=[string]$value }
    }
    & $fill $(if (Test-Path -LiteralPath $ConfigPath) { Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} })
    $import.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog; $dialog.Filter='MonitorSwitch profile (*.json)|*.json'; $dialog.Title='Import private device profile'
        try { if ($dialog.ShowDialog() -eq 'OK') { $profile=Convert-DeviceProfile (Get-Content -LiteralPath $dialog.FileName -Raw | ConvertFrom-Json); & $fill $profile; $errorLabel.Text='' } }
        catch { $errorLabel.Text=$_.Exception.Message } finally { $dialog.Dispose() }
    })
    $save.Add_Click({
        try {
            $values=@{}; foreach ($field in $fields) { $values[$field]=$controls[$field].Text }
            $profile=Convert-DeviceProfile ([pscustomobject]$values)
            $temporary=$ConfigPath+'.'+[Guid]::NewGuid().ToString()+'.tmp'
            try { [IO.File]::WriteAllText($temporary,($profile | ConvertTo-Json),[Text.UTF8Encoding]::new($false)); if (Test-Path -LiteralPath $ConfigPath) { [IO.File]::Replace($temporary,$ConfigPath,$null) } else { [IO.File]::Move($temporary,$ConfigPath) } }
            finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
            $form.DialogResult='OK'; $form.Close()
        } catch { $errorLabel.Text=$_.Exception.Message }
    })
    try { return ($form.ShowDialog() -eq 'OK') } finally { $form.Dispose() }
}
