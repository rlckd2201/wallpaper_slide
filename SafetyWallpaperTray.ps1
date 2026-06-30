Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot 'config.json'
$RuntimeDir = Join-Path $ScriptRoot '.runtime'
$LogDir = Join-Path $ScriptRoot 'logs'
$LogPath = Join-Path $LogDir 'wallpaper-slideshow.log'
$RefreshSignalPath = Join-Path $RuntimeDir 'refresh.signal'
$TrayStopSignalPath = Join-Path $RuntimeDir 'tray.stop.signal'
$MutexName = 'Local\SafetyWallpaperTray'

New-Item -ItemType Directory -Force -Path $RuntimeDir, $LogDir | Out-Null

function ConvertFrom-CodePointHex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hex
    )

    -join (($Hex -split ' ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        [char][Convert]::ToInt32($_, 16)
    })
}

$UiText = @{
    AgentTitle = ConvertFrom-CodePointHex 'C548 C804 0020 BC30 ACBD D654 BA74 0020 C5D0 C774 C804 D2B8'
    Refresh = ConvertFrom-CodePointHex 'C815 CC45 0020 C0C8 B85C ACE0 CE68'
    RefreshRequested = ConvertFrom-CodePointHex 'C815 CC45 0020 C0C8 B85C ACE0 CE68 C744 0020 C694 CCAD D588 C2B5 B2C8 B2E4 002E'
    Status = ConvertFrom-CodePointHex 'C0C1 D0DC 0020 BCF4 AE30'
    OpenLog = ConvertFrom-CodePointHex 'B85C ADF8 0020 C5F4 AE30'
    OpenPolicyUrl = ConvertFrom-CodePointHex 'C815 CC45 0020 0055 0052 004C 0020 C5F4 AE30'
    CloseTray = ConvertFrom-CodePointHex 'D2B8 B808 C774 0020 C544 C774 CF58 0020 B2EB AE30'
    PolicyUrl = ConvertFrom-CodePointHex 'C815 CC45 0020 C8FC C18C 003A'
    RecentLog = ConvertFrom-CodePointHex 'CD5C ADFC 0020 B85C ADF8 003A'
    NoLog = ConvertFrom-CodePointHex 'C544 C9C1 0020 B85C ADF8 0020 D30C C77C C774 0020 C5C6 C2B5 B2C8 B2E4 002E'
}

function Get-PolicyUrl {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return 'http://172.16.19.35:28080/safety-wallpaper/policy.json'
    }

    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($null -ne $config.PSObject.Properties['serverPolicyUrl'] -and
            -not [string]::IsNullOrWhiteSpace([string]$config.serverPolicyUrl)) {
            return [string]$config.serverPolicyUrl
        }
    }
    catch {
    }

    return 'http://172.16.19.35:28080/safety-wallpaper/policy.json'
}

function Write-RefreshSignal {
    Set-Content -LiteralPath $RefreshSignalPath -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding UTF8
}

function Show-Status {
    $policyUrl = Get-PolicyUrl
    $logText = ''

    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        $logText = (Get-Content -LiteralPath $LogPath -Tail 8 -Encoding UTF8) -join [Environment]::NewLine
    }
    else {
        $logText = $UiText.NoLog
    }

    $message = "$($UiText.PolicyUrl)`r`n$policyUrl`r`n`r`n$($UiText.RecentLog)`r`n$logText"
    [void][System.Windows.Forms.MessageBox]::Show($message, $UiText.AgentTitle, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$hasLock = $false

try {
    $hasLock = $mutex.WaitOne(0, $false)

    if (-not $hasLock) {
        Write-RefreshSignal
        exit 0
    }

    if (Test-Path -LiteralPath $TrayStopSignalPath -PathType Leaf) {
        Remove-Item -LiteralPath $TrayStopSignalPath -Force
    }

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
    $notifyIcon.Text = $UiText.AgentTitle
    $notifyIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $refreshItem.Text = $UiText.Refresh
    $refreshItem.Add_Click({
        Write-RefreshSignal
        $notifyIcon.BalloonTipTitle = $UiText.AgentTitle
        $notifyIcon.BalloonTipText = $UiText.RefreshRequested
        $notifyIcon.ShowBalloonTip(2000)
    })
    [void]$menu.Items.Add($refreshItem)

    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Text = $UiText.Status
    $statusItem.Add_Click({ Show-Status })
    [void]$menu.Items.Add($statusItem)

    $logItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $logItem.Text = $UiText.OpenLog
    $logItem.Add_Click({
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            Start-Process notepad.exe -ArgumentList "`"$LogPath`""
        }
    })
    [void]$menu.Items.Add($logItem)

    $policyItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $policyItem.Text = $UiText.OpenPolicyUrl
    $policyItem.Add_Click({ Start-Process (Get-PolicyUrl) })
    [void]$menu.Items.Add($policyItem)

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = $UiText.CloseTray
    $exitItem.Add_Click({
        $notifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    [void]$menu.Items.Add($exitItem)

    $notifyIcon.ContextMenuStrip = $menu
    $notifyIcon.Add_DoubleClick({ Show-Status })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $timer.Add_Tick({
        if (Test-Path -LiteralPath $TrayStopSignalPath -PathType Leaf) {
            Remove-Item -LiteralPath $TrayStopSignalPath -Force -ErrorAction SilentlyContinue
            $notifyIcon.Visible = $false
            [System.Windows.Forms.Application]::Exit()
        }
    })
    $timer.Start()

    [System.Windows.Forms.Application]::Run()
}
finally {
    if ($null -ne $notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }

    if ($hasLock) {
        $mutex.ReleaseMutex() | Out-Null
    }

    $mutex.Dispose()
}
