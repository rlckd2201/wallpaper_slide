param(
    [string]$Root = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$RootPath = (Resolve-Path -LiteralPath $Root).Path
$PolicyPath = Join-Path $RootPath 'policy.json'
$ImagesDir = Join-Path $RootPath 'images'
$ServerBatchPath = Join-Path $RootPath 'StartSafetyWallpaperServer.bat'
$PolicyUrl = 'http://172.16.19.35:28080/safety-wallpaper/policy.json'

New-Item -ItemType Directory -Force -Path $ImagesDir | Out-Null

function Get-DefaultPolicy {
    [pscustomobject]([ordered]@{
        policyVersion = (Get-Date -Format 'yyyy-MM-dd-HHmmss')
        enabled = $true
        campaignStart = (Get-Date).Date.ToString('yyyy-MM-ddTHH:mm:ss')
        campaignEnd = (Get-Date).Date.AddYears(1).AddSeconds(-1).ToString('yyyy-MM-ddTHH:mm:ss')
        policyPollSeconds = 600
        slideIntervalSeconds = 30
        configReloadSeconds = 10
        wallpaperStyle = 'Fit'
        avoidTaskbar = $true
        safeAreaPaddingPixels = 24
        shuffle = $false
        maxSlides = 0
        slides = @()
    })
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }

    return $DefaultValue
}

function Read-Policy {
    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
        return Get-DefaultPolicy
    }

    $raw = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return Get-DefaultPolicy
    }

    $loaded = $raw | ConvertFrom-Json
    $policy = Get-DefaultPolicy

    foreach ($property in $loaded.PSObject.Properties) {
        $policy | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
    }

    if ($null -eq $policy.slides) {
        $policy.slides = @()
    }

    return $policy
}

function ConvertTo-DateTimeValue {
    param(
        [object]$Value,
        [DateTime]$Fallback
    )

    try {
        if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
            return $Fallback
        }

        return [DateTime]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $Fallback
    }
}

function Get-SafeFileName {
    param([string]$FileName)

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $result = $FileName

    foreach ($char in $invalidChars) {
        $result = $result.Replace($char, '_')
    }

    return $result
}

function Add-SlideItem {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Version = '1',
        [bool]$Enabled = $true
    )

    $item = New-Object System.Windows.Forms.ListViewItem($Name)
    $item.Checked = $Enabled
    [void]$item.SubItems.Add($Url)
    [void]$item.SubItems.Add($Version)
    [void]$script:slideList.Items.Add($item)
}

function Load-PolicyToForm {
    param([pscustomobject]$Policy)

    $script:enabledCheck.Checked = [bool](Get-PropertyValue -Object $Policy -Name 'enabled' -DefaultValue $true)
    $script:versionText.Text = [string](Get-PropertyValue -Object $Policy -Name 'policyVersion' -DefaultValue (Get-Date -Format 'yyyy-MM-dd-HHmmss'))
    $script:startPicker.Value = ConvertTo-DateTimeValue -Value (Get-PropertyValue -Object $Policy -Name 'campaignStart') -Fallback (Get-Date).Date
    $script:endPicker.Value = ConvertTo-DateTimeValue -Value (Get-PropertyValue -Object $Policy -Name 'campaignEnd') -Fallback (Get-Date).Date.AddYears(1).AddSeconds(-1)
    $script:pollSeconds.Value = [decimal][Math]::Max(60, [int](Get-PropertyValue -Object $Policy -Name 'policyPollSeconds' -DefaultValue 600))
    $script:slideSeconds.Value = [decimal][Math]::Max(5, [int](Get-PropertyValue -Object $Policy -Name 'slideIntervalSeconds' -DefaultValue 30))
    $script:reloadSeconds.Value = [decimal][Math]::Max(5, [int](Get-PropertyValue -Object $Policy -Name 'configReloadSeconds' -DefaultValue 10))
    $script:maxSlides.Value = [decimal][Math]::Max(0, [int](Get-PropertyValue -Object $Policy -Name 'maxSlides' -DefaultValue 0))
    $script:paddingPixels.Value = [decimal][Math]::Max(0, [int](Get-PropertyValue -Object $Policy -Name 'safeAreaPaddingPixels' -DefaultValue 24))
    $script:shuffleCheck.Checked = [bool](Get-PropertyValue -Object $Policy -Name 'shuffle' -DefaultValue $false)
    $script:avoidTaskbarCheck.Checked = [bool](Get-PropertyValue -Object $Policy -Name 'avoidTaskbar' -DefaultValue $true)
    $script:styleCombo.SelectedItem = [string](Get-PropertyValue -Object $Policy -Name 'wallpaperStyle' -DefaultValue 'Fit')

    if ($null -eq $script:styleCombo.SelectedItem) {
        $script:styleCombo.SelectedItem = 'Fit'
    }

    $script:slideList.Items.Clear()

    foreach ($slide in @($Policy.slides)) {
        if ($slide -is [string]) {
            Add-SlideItem -Name ([System.IO.Path]::GetFileName($slide)) -Url $slide -Version '1' -Enabled $true
            continue
        }

        $url = [string](Get-PropertyValue -Object $slide -Name 'url' -DefaultValue (Get-PropertyValue -Object $slide -Name 'file' -DefaultValue ''))

        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }

        Add-SlideItem `
            -Name ([string](Get-PropertyValue -Object $slide -Name 'name' -DefaultValue ([System.IO.Path]::GetFileName($url)))) `
            -Url $url `
            -Version ([string](Get-PropertyValue -Object $slide -Name 'version' -DefaultValue '1')) `
            -Enabled ([bool](Get-PropertyValue -Object $slide -Name 'enabled' -DefaultValue $true))
    }
}

function Save-PolicyFromForm {
    $slides = @()

    foreach ($item in $script:slideList.Items) {
        $slides += [ordered]@{
            name = [string]$item.Text
            url = [string]$item.SubItems[1].Text
            enabled = [bool]$item.Checked
            version = [string]$item.SubItems[2].Text
        }
    }

    $policy = [ordered]@{
        policyVersion = (Get-Date -Format 'yyyy-MM-dd-HHmmss')
        enabled = [bool]$script:enabledCheck.Checked
        campaignStart = $script:startPicker.Value.ToString('yyyy-MM-ddTHH:mm:ss')
        campaignEnd = $script:endPicker.Value.ToString('yyyy-MM-ddTHH:mm:ss')
        policyPollSeconds = [int]$script:pollSeconds.Value
        slideIntervalSeconds = [int]$script:slideSeconds.Value
        configReloadSeconds = [int]$script:reloadSeconds.Value
        wallpaperStyle = [string]$script:styleCombo.SelectedItem
        avoidTaskbar = [bool]$script:avoidTaskbarCheck.Checked
        safeAreaPaddingPixels = [int]$script:paddingPixels.Value
        shuffle = [bool]$script:shuffleCheck.Checked
        maxSlides = [int]$script:maxSlides.Value
        slides = $slides
    }

    $json = $policy | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $PolicyPath -Value $json -Encoding UTF8
    $script:versionText.Text = [string]$policy.policyVersion
}

function Show-Message {
    param(
        [string]$Text,
        [string]$Title = 'Safety Wallpaper Admin'
    )

    [void][System.Windows.Forms.MessageBox]::Show($script:form, $Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'Safety Wallpaper Admin'
$script:form.StartPosition = 'CenterScreen'
$script:form.Size = New-Object System.Drawing.Size(1060, 720)
$script:form.MinimumSize = New-Object System.Drawing.Size(980, 640)

$font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:form.Font = $font

$header = New-Object System.Windows.Forms.Label
$header.Text = 'Safety Wallpaper Policy'
$header.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(18, 14)
$header.Size = New-Object System.Drawing.Size(440, 34)
$script:form.Controls.Add($header)

$urlLabel = New-Object System.Windows.Forms.Label
$urlLabel.Text = $PolicyUrl
$urlLabel.Location = New-Object System.Drawing.Point(20, 52)
$urlLabel.Size = New-Object System.Drawing.Size(600, 22)
$script:form.Controls.Add($urlLabel)

$script:enabledCheck = New-Object System.Windows.Forms.CheckBox
$script:enabledCheck.Text = 'Campaign enabled'
$script:enabledCheck.Location = New-Object System.Drawing.Point(22, 88)
$script:enabledCheck.Size = New-Object System.Drawing.Size(190, 24)
$script:form.Controls.Add($script:enabledCheck)

$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = 'Policy version'
$versionLabel.Location = New-Object System.Drawing.Point(235, 91)
$versionLabel.Size = New-Object System.Drawing.Size(92, 20)
$script:form.Controls.Add($versionLabel)

$script:versionText = New-Object System.Windows.Forms.TextBox
$script:versionText.Location = New-Object System.Drawing.Point(332, 87)
$script:versionText.Size = New-Object System.Drawing.Size(185, 24)
$script:versionText.ReadOnly = $true
$script:form.Controls.Add($script:versionText)

$startLabel = New-Object System.Windows.Forms.Label
$startLabel.Text = 'Start'
$startLabel.Location = New-Object System.Drawing.Point(22, 130)
$startLabel.Size = New-Object System.Drawing.Size(60, 20)
$script:form.Controls.Add($startLabel)

$script:startPicker = New-Object System.Windows.Forms.DateTimePicker
$script:startPicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$script:startPicker.CustomFormat = 'yyyy-MM-dd HH:mm:ss'
$script:startPicker.Location = New-Object System.Drawing.Point(82, 126)
$script:startPicker.Size = New-Object System.Drawing.Size(190, 24)
$script:form.Controls.Add($script:startPicker)

$endLabel = New-Object System.Windows.Forms.Label
$endLabel.Text = 'End'
$endLabel.Location = New-Object System.Drawing.Point(292, 130)
$endLabel.Size = New-Object System.Drawing.Size(60, 20)
$script:form.Controls.Add($endLabel)

$script:endPicker = New-Object System.Windows.Forms.DateTimePicker
$script:endPicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$script:endPicker.CustomFormat = 'yyyy-MM-dd HH:mm:ss'
$script:endPicker.Location = New-Object System.Drawing.Point(352, 126)
$script:endPicker.Size = New-Object System.Drawing.Size(190, 24)
$script:form.Controls.Add($script:endPicker)

$settingsGroup = New-Object System.Windows.Forms.GroupBox
$settingsGroup.Text = 'Policy settings'
$settingsGroup.Location = New-Object System.Drawing.Point(22, 170)
$settingsGroup.Size = New-Object System.Drawing.Size(1000, 120)
$script:form.Controls.Add($settingsGroup)

function Add-NumericSetting {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Minimum,
        [int]$Maximum
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size(125, 20)
    $Parent.Controls.Add($label)

    $numeric = New-Object System.Windows.Forms.NumericUpDown
    $numeric.Location = New-Object System.Drawing.Point(($X + 132), ($Y - 3))
    $numeric.Size = New-Object System.Drawing.Size(86, 24)
    $numeric.Minimum = $Minimum
    $numeric.Maximum = $Maximum
    $Parent.Controls.Add($numeric)

    return $numeric
}

$script:pollSeconds = Add-NumericSetting -Parent $settingsGroup -Text 'Policy poll sec' -X 18 -Y 32 -Minimum 60 -Maximum 86400
$script:slideSeconds = Add-NumericSetting -Parent $settingsGroup -Text 'Slide wait sec' -X 265 -Y 32 -Minimum 5 -Maximum 86400
$script:reloadSeconds = Add-NumericSetting -Parent $settingsGroup -Text 'Fallback reload sec' -X 512 -Y 32 -Minimum 5 -Maximum 86400
$script:maxSlides = Add-NumericSetting -Parent $settingsGroup -Text 'Max slides (0=all)' -X 18 -Y 76 -Minimum 0 -Maximum 999
$script:paddingPixels = Add-NumericSetting -Parent $settingsGroup -Text 'Safe padding px' -X 265 -Y 76 -Minimum 0 -Maximum 500

$styleLabel = New-Object System.Windows.Forms.Label
$styleLabel.Text = 'Wallpaper style'
$styleLabel.Location = New-Object System.Drawing.Point(512, 76)
$styleLabel.Size = New-Object System.Drawing.Size(125, 20)
$settingsGroup.Controls.Add($styleLabel)

$script:styleCombo = New-Object System.Windows.Forms.ComboBox
$script:styleCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:styleCombo.Items.AddRange(@('Fill', 'Fit', 'Stretch', 'Center', 'Tile', 'Span'))
$script:styleCombo.Location = New-Object System.Drawing.Point(644, 73)
$script:styleCombo.Size = New-Object System.Drawing.Size(110, 24)
$settingsGroup.Controls.Add($script:styleCombo)

$script:shuffleCheck = New-Object System.Windows.Forms.CheckBox
$script:shuffleCheck.Text = 'Shuffle per cycle'
$script:shuffleCheck.Location = New-Object System.Drawing.Point(786, 30)
$script:shuffleCheck.Size = New-Object System.Drawing.Size(150, 24)
$settingsGroup.Controls.Add($script:shuffleCheck)

$script:avoidTaskbarCheck = New-Object System.Windows.Forms.CheckBox
$script:avoidTaskbarCheck.Text = 'Avoid taskbar'
$script:avoidTaskbarCheck.Location = New-Object System.Drawing.Point(786, 74)
$script:avoidTaskbarCheck.Size = New-Object System.Drawing.Size(150, 24)
$settingsGroup.Controls.Add($script:avoidTaskbarCheck)

$slidesLabel = New-Object System.Windows.Forms.Label
$slidesLabel.Text = 'Slides'
$slidesLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$slidesLabel.Location = New-Object System.Drawing.Point(22, 310)
$slidesLabel.Size = New-Object System.Drawing.Size(100, 24)
$script:form.Controls.Add($slidesLabel)

$script:slideList = New-Object System.Windows.Forms.ListView
$script:slideList.Location = New-Object System.Drawing.Point(22, 340)
$script:slideList.Size = New-Object System.Drawing.Size(1000, 245)
$script:slideList.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:slideList.View = [System.Windows.Forms.View]::Details
$script:slideList.CheckBoxes = $true
$script:slideList.FullRowSelect = $true
$script:slideList.GridLines = $true
$script:slideList.MultiSelect = $true
[void]$script:slideList.Columns.Add('Name', 250)
[void]$script:slideList.Columns.Add('URL', 560)
[void]$script:slideList.Columns.Add('Version', 120)
$script:form.Controls.Add($script:slideList)

$addButton = New-Object System.Windows.Forms.Button
$addButton.Text = 'Add Images'
$addButton.Location = New-Object System.Drawing.Point(22, 605)
$addButton.Size = New-Object System.Drawing.Size(115, 34)
$addButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$script:form.Controls.Add($addButton)

$removeButton = New-Object System.Windows.Forms.Button
$removeButton.Text = 'Remove'
$removeButton.Location = New-Object System.Drawing.Point(148, 605)
$removeButton.Size = New-Object System.Drawing.Size(100, 34)
$removeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$script:form.Controls.Add($removeButton)

$selectAllButton = New-Object System.Windows.Forms.Button
$selectAllButton.Text = 'Enable All'
$selectAllButton.Location = New-Object System.Drawing.Point(260, 605)
$selectAllButton.Size = New-Object System.Drawing.Size(100, 34)
$selectAllButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$script:form.Controls.Add($selectAllButton)

$clearAllButton = New-Object System.Windows.Forms.Button
$clearAllButton.Text = 'Disable All'
$clearAllButton.Location = New-Object System.Drawing.Point(372, 605)
$clearAllButton.Size = New-Object System.Drawing.Size(100, 34)
$clearAllButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$script:form.Controls.Add($clearAllButton)

$reloadButton = New-Object System.Windows.Forms.Button
$reloadButton.Text = 'Reload'
$reloadButton.Location = New-Object System.Drawing.Point(526, 605)
$reloadButton.Size = New-Object System.Drawing.Size(90, 34)
$reloadButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$script:form.Controls.Add($reloadButton)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Save Policy'
$saveButton.Location = New-Object System.Drawing.Point(628, 605)
$saveButton.Size = New-Object System.Drawing.Size(110, 34)
$saveButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$script:form.Controls.Add($saveButton)

$startServerButton = New-Object System.Windows.Forms.Button
$startServerButton.Text = 'Start Server'
$startServerButton.Location = New-Object System.Drawing.Point(750, 605)
$startServerButton.Size = New-Object System.Drawing.Size(110, 34)
$startServerButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$script:form.Controls.Add($startServerButton)

$openUrlButton = New-Object System.Windows.Forms.Button
$openUrlButton.Text = 'Open URL'
$openUrlButton.Location = New-Object System.Drawing.Point(872, 605)
$openUrlButton.Size = New-Object System.Drawing.Size(110, 34)
$openUrlButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$script:form.Controls.Add($openUrlButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Policy: $PolicyPath"
$statusLabel.Location = New-Object System.Drawing.Point(22, 652)
$statusLabel.Size = New-Object System.Drawing.Size(990, 24)
$statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:form.Controls.Add($statusLabel)

$addButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Add slide images'
    $dialog.Filter = 'Image files|*.png;*.jpg;*.jpeg;*.bmp|All files|*.*'
    $dialog.Multiselect = $true

    if ($dialog.ShowDialog($script:form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    foreach ($sourcePath in $dialog.FileNames) {
        $fileName = Get-SafeFileName -FileName ([System.IO.Path]::GetFileName($sourcePath))
        $destPath = Join-Path $ImagesDir $fileName
        Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force

        $relativeUrl = "images/$fileName"
        $existing = $null

        foreach ($item in $script:slideList.Items) {
            if ([string]$item.SubItems[1].Text -eq $relativeUrl) {
                $existing = $item
                break
            }
        }

        $version = (Get-Date -Format 'yyyyMMddHHmmss')

        if ($null -ne $existing) {
            $existing.Checked = $true
            $existing.SubItems[2].Text = $version
        }
        else {
            Add-SlideItem -Name $fileName -Url $relativeUrl -Version $version -Enabled $true
        }
    }

    $statusLabel.Text = "Added images to $ImagesDir"
})

$removeButton.Add_Click({
    foreach ($item in @($script:slideList.SelectedItems)) {
        $script:slideList.Items.Remove($item)
    }
})

$selectAllButton.Add_Click({
    foreach ($item in $script:slideList.Items) {
        $item.Checked = $true
    }
})

$clearAllButton.Add_Click({
    foreach ($item in $script:slideList.Items) {
        $item.Checked = $false
    }
})

$reloadButton.Add_Click({
    Load-PolicyToForm -Policy (Read-Policy)
    $statusLabel.Text = "Reloaded $PolicyPath"
})

$saveButton.Add_Click({
    Save-PolicyFromForm
    $statusLabel.Text = "Saved $PolicyPath at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Show-Message -Text 'Policy saved. User agents will pick it up on the next policy check.'
})

$startServerButton.Add_Click({
    if (-not (Test-Path -LiteralPath $ServerBatchPath -PathType Leaf)) {
        Show-Message -Text "Cannot find $ServerBatchPath"
        return
    }

    try {
        Start-Process -FilePath $ServerBatchPath -WorkingDirectory $RootPath -Verb RunAs
    }
    catch {
        Show-Message -Text "Failed to start server: $($_.Exception.Message)"
    }
})

$openUrlButton.Add_Click({
    Start-Process $PolicyUrl
})

Load-PolicyToForm -Policy (Read-Policy)
[void][System.Windows.Forms.Application]::Run($script:form)
