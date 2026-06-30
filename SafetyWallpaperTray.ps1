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
        $logText = 'No log file yet.'
    }

    $message = "Policy URL:`r`n$policyUrl`r`n`r`nRecent log:`r`n$logText"
    [void][System.Windows.Forms.MessageBox]::Show($message, 'Safety Wallpaper Agent', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
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
    $notifyIcon.Text = 'Safety Wallpaper Agent'
    $notifyIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $refreshItem.Text = '정책 새로고침'
    $refreshItem.Add_Click({
        Write-RefreshSignal
        $notifyIcon.BalloonTipTitle = 'Safety Wallpaper Agent'
        $notifyIcon.BalloonTipText = '정책 새로고침을 요청했습니다.'
        $notifyIcon.ShowBalloonTip(2000)
    })
    [void]$menu.Items.Add($refreshItem)

    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Text = '상태 보기'
    $statusItem.Add_Click({ Show-Status })
    [void]$menu.Items.Add($statusItem)

    $logItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $logItem.Text = '로그 열기'
    $logItem.Add_Click({
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            Start-Process notepad.exe -ArgumentList "`"$LogPath`""
        }
    })
    [void]$menu.Items.Add($logItem)

    $policyItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $policyItem.Text = '정책 URL 열기'
    $policyItem.Add_Click({ Start-Process (Get-PolicyUrl) })
    [void]$menu.Items.Add($policyItem)

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = '트레이 아이콘 닫기'
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
