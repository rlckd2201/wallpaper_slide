param(
    [switch]$DryRun,
    [switch]$Once,
    [string]$PolicyUrlOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot 'config.json'
$RuntimeDir = Join-Path $ScriptRoot '.runtime'
$RenderedWallpaperDir = Join-Path $RuntimeDir 'rendered'
$LogDir = Join-Path $ScriptRoot 'logs'
$LogPath = Join-Path $LogDir 'wallpaper-slideshow.log'
$StopSignalPath = Join-Path $RuntimeDir 'stop.signal'
$BlackWallpaperPath = Join-Path $RuntimeDir 'black.bmp'
$MutexName = 'Local\SafetyWallpaperSlideshow'

New-Item -ItemType Directory -Force -Path $RuntimeDir, $RenderedWallpaperDir, $LogDir | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Import-WallpaperNativeApi {
    if ('WallpaperNativeApi' -as [type]) {
        return
    }

    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WallpaperNativeApi
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
}

function Test-ObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if (Test-ObjectProperty -Object $Object -Name $Name) {
        return $Object.PSObject.Properties[$Name].Value
    }

    return $DefaultValue
}

function Get-DefaultAgentConfig {
    [pscustomobject]@{
        serverPolicyUrl = 'http://172.16.19.35:28080/safety-wallpaper/policy.json'
        serverPollSeconds = 600
        requestTimeoutSeconds = 20
        cacheFolder = '.runtime\policy-cache'
    }
}

function Get-DefaultPolicy {
    [pscustomobject]@{
        policyVersion = 'none'
        enabled = $false
        campaignStart = $null
        campaignEnd = $null
        slideIntervalSeconds = 30
        configReloadSeconds = 10
        policyPollSeconds = 600
        wallpaperStyle = 'Fit'
        avoidTaskbar = $true
        safeAreaPaddingPixels = 24
        shuffle = $false
        maxSlides = 0
        slides = @()
    }
}

function Resolve-AppPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $ScriptRoot $Path
}

function Read-AgentConfig {
    $config = Get-DefaultAgentConfig

    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8

        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $loaded = $raw | ConvertFrom-Json

            foreach ($property in $loaded.PSObject.Properties) {
                $config | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PolicyUrlOverride)) {
        $config.serverPolicyUrl = $PolicyUrlOverride
    }

    $config.serverPollSeconds = [Math]::Max(60, [int]$config.serverPollSeconds)
    $config.requestTimeoutSeconds = [Math]::Max(5, [int]$config.requestTimeoutSeconds)

    if ([string]::IsNullOrWhiteSpace([string]$config.cacheFolder)) {
        $config.cacheFolder = '.runtime\policy-cache'
    }

    return $config
}

function Get-CachePaths {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$AgentConfig
    )

    $root = Resolve-AppPath -Path ([string]$AgentConfig.cacheFolder)
    $imageDir = Join-Path $root 'images'

    New-Item -ItemType Directory -Force -Path $root, $imageDir | Out-Null

    [pscustomobject]@{
        Root = $root
        PolicyPath = Join-Path $root 'policy.json'
        ImageDir = $imageDir
    }
}

function ConvertTo-OptionalDateTime {
    param(
        [object]$Value,
        [string]$Name
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return [DateTime]::Parse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal
        )
    }
    catch {
        throw "Invalid $Name value '$text'. Use a value like 2026-06-30T09:00:00."
    }
}

function Get-CampaignState {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Policy
    )

    if (-not [bool]$Policy.enabled) {
        return 'Disabled'
    }

    $now = Get-Date
    $start = ConvertTo-OptionalDateTime -Value $Policy.campaignStart -Name 'campaignStart'
    $end = ConvertTo-OptionalDateTime -Value $Policy.campaignEnd -Name 'campaignEnd'

    if ($null -ne $start -and $now -lt $start) {
        return 'NotStarted'
    }

    if ($null -ne $end -and $now -gt $end) {
        return 'Expired'
    }

    return 'Active'
}

function Get-TextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-PolicyTextFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $uri = $null
    if ([System.Uri]::TryCreate($Source, [System.UriKind]::Absolute, [ref]$uri) -and
        ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')) {
        $response = Invoke-WebRequest -Uri $uri.AbsoluteUri -UseBasicParsing -TimeoutSec $TimeoutSeconds
        return [string]$response.Content
    }

    $localPath = Resolve-AppPath -Path $Source
    return Get-Content -LiteralPath $localPath -Raw -Encoding UTF8
}

function Normalize-Policy {
    param(
        [Parameter(Mandatory = $true)]
        [object]$LoadedPolicy,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AgentConfig
    )

    $policy = Get-DefaultPolicy

    foreach ($property in $LoadedPolicy.PSObject.Properties) {
        $policy | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
    }

    $policy.slideIntervalSeconds = [Math]::Max(5, [int]$policy.slideIntervalSeconds)
    $policy.configReloadSeconds = [Math]::Max(5, [int]$policy.configReloadSeconds)
    $policy.policyPollSeconds = [Math]::Max(60, [int](Get-ObjectPropertyValue -Object $policy -Name 'policyPollSeconds' -DefaultValue $AgentConfig.serverPollSeconds))
    $policy.safeAreaPaddingPixels = [Math]::Max(0, [int]$policy.safeAreaPaddingPixels)
    $policy.maxSlides = [Math]::Max(0, [int]$policy.maxSlides)

    $validStyles = @('Fill', 'Fit', 'Stretch', 'Center', 'Tile', 'Span')
    if ($validStyles -notcontains ([string]$policy.wallpaperStyle)) {
        Write-Log "Invalid wallpaperStyle '$($policy.wallpaperStyle)'. Fallback to Fit." 'WARN'
        $policy.wallpaperStyle = 'Fit'
    }

    if ($null -eq $policy.slides) {
        $policy.slides = @()
    }
    else {
        $policy.slides = @($policy.slides)
    }

    return $policy
}

function Read-EffectivePolicy {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$AgentConfig
    )

    $cachePaths = Get-CachePaths -AgentConfig $AgentConfig

    try {
        $policyText = Read-PolicyTextFromSource -Source ([string]$AgentConfig.serverPolicyUrl) -TimeoutSeconds ([int]$AgentConfig.requestTimeoutSeconds)
        $loadedPolicy = $policyText | ConvertFrom-Json
        $policy = Normalize-Policy -LoadedPolicy $loadedPolicy -AgentConfig $AgentConfig
        Set-Content -LiteralPath $cachePaths.PolicyPath -Value $policyText -Encoding UTF8

        Write-Log "Policy synced from '$($AgentConfig.serverPolicyUrl)' version '$($policy.policyVersion)'."

        return [pscustomobject]@{
            Policy = $policy
            PolicyHash = Get-TextSha256 -Text $policyText
            Source = 'server'
            CachePaths = $cachePaths
        }
    }
    catch {
        Write-Log "Policy sync failed from '$($AgentConfig.serverPolicyUrl)': $($_.Exception.Message)" 'WARN'

        if (Test-Path -LiteralPath $cachePaths.PolicyPath -PathType Leaf) {
            $cachedText = Get-Content -LiteralPath $cachePaths.PolicyPath -Raw -Encoding UTF8
            $cachedPolicy = Normalize-Policy -LoadedPolicy ($cachedText | ConvertFrom-Json) -AgentConfig $AgentConfig
            Write-Log "Using cached policy version '$($cachedPolicy.policyVersion)'."

            return [pscustomobject]@{
                Policy = $cachedPolicy
                PolicyHash = Get-TextSha256 -Text $cachedText
                Source = 'cache'
                CachePaths = $cachePaths
            }
        }

        throw "No server policy and no cached policy are available."
    }
}

function Get-SourceExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [string]$FallbackName = ''
    )

    $candidate = $Source
    $uri = $null

    if ([System.Uri]::TryCreate($Source, [System.UriKind]::Absolute, [ref]$uri)) {
        $candidate = $uri.LocalPath
    }

    $extension = [System.IO.Path]::GetExtension($candidate)

    if ([string]::IsNullOrWhiteSpace($extension) -and -not [string]::IsNullOrWhiteSpace($FallbackName)) {
        $extension = [System.IO.Path]::GetExtension($FallbackName)
    }

    if ([string]::IsNullOrWhiteSpace($extension)) {
        return '.png'
    }

    return $extension.ToLowerInvariant()
}

function Resolve-PolicyAssetSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyUrl,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $uri = $null
    if ([System.Uri]::TryCreate($Source, [System.UriKind]::Absolute, [ref]$uri)) {
        if ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https' -or $uri.Scheme -eq 'file') {
            return $uri.AbsoluteUri
        }
    }

    if ([System.IO.Path]::IsPathRooted($Source)) {
        return $Source
    }

    $baseUri = $null
    if ([System.Uri]::TryCreate($PolicyUrl, [System.UriKind]::Absolute, [ref]$baseUri) -and
        ($baseUri.Scheme -eq 'http' -or $baseUri.Scheme -eq 'https')) {
        return ([System.Uri]::new($baseUri, $Source)).AbsoluteUri
    }

    return Resolve-AppPath -Path $Source
}

function Get-SlideSource {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Slide
    )

    if ($Slide -is [string]) {
        return $Slide
    }

    $url = [string](Get-ObjectPropertyValue -Object $Slide -Name 'url' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($url)) {
        return $url
    }

    return [string](Get-ObjectPropertyValue -Object $Slide -Name 'file' -DefaultValue '')
}

function Get-SlideVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Slide,

        [Parameter(Mandatory = $true)]
        [string]$PolicyVersion
    )

    if ($Slide -is [string]) {
        return $PolicyVersion
    }

    return [string](Get-ObjectPropertyValue -Object $Slide -Name 'version' -DefaultValue $PolicyVersion)
}

function Get-SlideSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Slide
    )

    if ($Slide -is [string]) {
        return ''
    }

    return ([string](Get-ObjectPropertyValue -Object $Slide -Name 'sha256' -DefaultValue '')).Trim().ToLowerInvariant()
}

function Get-SlideDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Slide,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    if ($Slide -isnot [string]) {
        $name = [string](Get-ObjectPropertyValue -Object $Slide -Name 'name' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name
        }

        $file = [string](Get-ObjectPropertyValue -Object $Slide -Name 'file' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($file)) {
            return $file
        }
    }

    return [System.IO.Path]::GetFileName($Source)
}

function Get-CacheFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    $hash = Get-TextSha256 -Text $Identity
    return "$hash$Extension"
}

function Copy-PolicyAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedSource,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $tempPath = "$DestinationPath.download"

    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
        Remove-Item -LiteralPath $tempPath -Force
    }

    $uri = $null
    if ([System.Uri]::TryCreate($ResolvedSource, [System.UriKind]::Absolute, [ref]$uri) -and
        ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')) {
        Invoke-WebRequest -Uri $uri.AbsoluteUri -UseBasicParsing -TimeoutSec $TimeoutSeconds -OutFile $tempPath
    }
    elseif ($null -ne $uri -and $uri.Scheme -eq 'file') {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $tempPath -Force
    }
    else {
        $localSource = Resolve-AppPath -Path $ResolvedSource
        Copy-Item -LiteralPath $localSource -Destination $tempPath -Force
    }

    Move-Item -LiteralPath $tempPath -Destination $DestinationPath -Force
}

function Test-ImageCacheValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        return $true
    }

    return (Get-FileSha256 -Path $Path) -eq $ExpectedSha256
}

function Sync-PolicyAssets {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Policy,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$AgentConfig,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$CachePaths
    )

    $localImages = @()
    $enabledSlides = @()

    foreach ($slide in @($Policy.slides)) {
        if ($slide -isnot [string]) {
            $enabled = [bool](Get-ObjectPropertyValue -Object $slide -Name 'enabled' -DefaultValue $true)
            if (-not $enabled) {
                continue
            }
        }

        $enabledSlides += $slide
    }

    if ([int]$Policy.maxSlides -gt 0) {
        $enabledSlides = @($enabledSlides | Select-Object -First ([int]$Policy.maxSlides))
    }

    foreach ($slide in $enabledSlides) {
        $source = Get-SlideSource -Slide $slide

        if ([string]::IsNullOrWhiteSpace($source)) {
            Write-Log 'Policy slide skipped because it has no url or file value.' 'WARN'
            continue
        }

        $displayName = Get-SlideDisplayName -Slide $slide -Source $source
        $version = Get-SlideVersion -Slide $slide -PolicyVersion ([string]$Policy.policyVersion)
        $expectedSha256 = Get-SlideSha256 -Slide $slide
        $resolvedSource = Resolve-PolicyAssetSource -PolicyUrl ([string]$AgentConfig.serverPolicyUrl) -Source $source
        $extension = Get-SourceExtension -Source $source -FallbackName $displayName
        $cacheIdentity = '{0}|{1}|{2}|{3}|{4}' -f $Policy.policyVersion, $version, $source, $displayName, $expectedSha256
        $localPath = Join-Path $CachePaths.ImageDir (Get-CacheFileName -Identity $cacheIdentity -Extension $extension)

        if (-not (Test-ImageCacheValid -Path $localPath -ExpectedSha256 $expectedSha256)) {
            try {
                Copy-PolicyAsset -ResolvedSource $resolvedSource -DestinationPath $localPath -TimeoutSeconds ([int]$AgentConfig.requestTimeoutSeconds)

                if (-not (Test-ImageCacheValid -Path $localPath -ExpectedSha256 $expectedSha256)) {
                    Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
                    Write-Log "Downloaded image hash mismatch for '$displayName'." 'WARN'
                    continue
                }

                Write-Log "Image cached '$displayName' from '$resolvedSource'."
            }
            catch {
                if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                    Write-Log "Image download failed for '$displayName'; using existing cache. $($_.Exception.Message)" 'WARN'
                }
                else {
                    Write-Log "Image download failed for '$displayName'; skipped. $($_.Exception.Message)" 'WARN'
                    continue
                }
            }
        }

        $localImages += (Get-Item -LiteralPath $localPath)
    }

    return @($localImages)
}

function Sync-PolicyState {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$AgentConfig
    )

    $policyResult = Read-EffectivePolicy -AgentConfig $AgentConfig
    $images = @(Sync-PolicyAssets -Policy $policyResult.Policy -AgentConfig $AgentConfig -CachePaths $policyResult.CachePaths)

    Write-Log "Policy state ready from '$($policyResult.Source)': version '$($policyResult.Policy.policyVersion)', slides=$($images.Count), interval=$($policyResult.Policy.slideIntervalSeconds)s, poll=$($policyResult.Policy.policyPollSeconds)s."

    return [pscustomobject]@{
        Policy = $policyResult.Policy
        Images = @($images)
        PolicyHash = $policyResult.PolicyHash
        Source = $policyResult.Source
    }
}

function Ensure-BlackWallpaper {
    if (Test-Path -LiteralPath $BlackWallpaperPath -PathType Leaf) {
        return
    }

    Add-Type -AssemblyName System.Drawing

    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.Clear([System.Drawing.Color]::Black)
        $bitmap.Save($BlackWallpaperPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Remove-OldRenderedWallpapers {
    if (-not (Test-Path -LiteralPath $RenderedWallpaperDir -PathType Container)) {
        return
    }

    $oldFiles = @(
        Get-ChildItem -LiteralPath $RenderedWallpaperDir -File -Filter '*.bmp' |
            Sort-Object -Property LastWriteTimeUtc -Descending |
            Select-Object -Skip 20
    )

    foreach ($file in $oldFiles) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-TaskbarSafeWallpaper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [int]$PaddingPixels
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Source image does not exist: $SourcePath"
    }

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $bounds = $screen.Bounds
    $workArea = $screen.WorkingArea

    $canvasWidth = [int]$bounds.Width
    $canvasHeight = [int]$bounds.Height
    $safeX = [Math]::Max(0, [int]($workArea.X - $bounds.X))
    $safeY = [Math]::Max(0, [int]($workArea.Y - $bounds.Y))
    $safeWidth = [Math]::Min([int]$workArea.Width, $canvasWidth - $safeX)
    $safeHeight = [Math]::Min([int]$workArea.Height, $canvasHeight - $safeY)
    $padding = [Math]::Max(0, $PaddingPixels)

    $targetX = [Math]::Min($canvasWidth - 1, $safeX + $padding)
    $targetY = [Math]::Min($canvasHeight - 1, $safeY + $padding)
    $targetWidth = [Math]::Max(1, $safeWidth - ($padding * 2))
    $targetHeight = [Math]::Max(1, $safeHeight - ($padding * 2))

    $timestamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $outputPath = Join-Path $RenderedWallpaperDir "wallpaper_$timestamp.bmp"
    $sourceImage = [System.Drawing.Image]::FromFile($SourcePath)
    $bitmap = New-Object System.Drawing.Bitmap $canvasWidth, $canvasHeight
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.Clear([System.Drawing.Color]::Black)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        $scaleX = $targetWidth / $sourceImage.Width
        $scaleY = $targetHeight / $sourceImage.Height
        $scale = [Math]::Min($scaleX, $scaleY)
        $drawWidth = [Math]::Max(1, [int][Math]::Round($sourceImage.Width * $scale))
        $drawHeight = [Math]::Max(1, [int][Math]::Round($sourceImage.Height * $scale))
        $drawX = [int]($targetX + (($targetWidth - $drawWidth) / 2))
        $drawY = [int]($targetY + (($targetHeight - $drawHeight) / 2))

        $graphics.DrawImage($sourceImage, $drawX, $drawY, $drawWidth, $drawHeight)
        $bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
        $sourceImage.Dispose()
    }

    Remove-OldRenderedWallpapers
    Write-Log "Rendered taskbar-safe wallpaper '$outputPath' from '$SourcePath'."

    return $outputPath
}

function Set-WallpaperStyle {
    param(
        [ValidateSet('Fill', 'Fit', 'Stretch', 'Center', 'Tile', 'Span')]
        [string]$Style
    )

    $styleMap = @{
        Fill = @{ WallpaperStyle = '10'; TileWallpaper = '0' }
        Fit = @{ WallpaperStyle = '6'; TileWallpaper = '0' }
        Stretch = @{ WallpaperStyle = '2'; TileWallpaper = '0' }
        Center = @{ WallpaperStyle = '0'; TileWallpaper = '0' }
        Tile = @{ WallpaperStyle = '0'; TileWallpaper = '1' }
        Span = @{ WallpaperStyle = '22'; TileWallpaper = '0' }
    }

    $selected = $styleMap[$Style]
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value $selected.WallpaperStyle
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value $selected.TileWallpaper
}

function Set-DesktopBackgroundColor {
    Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Value '0 0 0'
}

function Set-DesktopWallpaper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateSet('Fill', 'Fit', 'Stretch', 'Center', 'Tile', 'Span')]
        [string]$Style,

        [switch]$DryRunMode
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Wallpaper file does not exist: $Path"
    }

    if ($DryRunMode) {
        Write-Log "DRY RUN: wallpaper would be set to '$Path' with style '$Style'."
        return
    }

    Set-WallpaperStyle -Style $Style
    Set-DesktopBackgroundColor

    $spiSetDeskWallpaper = 20
    $spifUpdateIniFile = 0x01
    $spifSendWinIniChange = 0x02
    $flags = $spifUpdateIniFile -bor $spifSendWinIniChange

    $ok = [WallpaperNativeApi]::SystemParametersInfo($spiSetDeskWallpaper, 0, $Path, $flags)

    if (-not $ok) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SystemParametersInfo failed with Win32 error $lastError."
    }

    Write-Log "Wallpaper set to '$Path' with style '$Style'."
}

function Remove-StopSignal {
    if (Test-Path -LiteralPath $StopSignalPath -PathType Leaf) {
        Remove-Item -LiteralPath $StopSignalPath -Force
    }
}

function Get-LoopSleepSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [int]$DesiredSeconds,

        [Parameter(Mandatory = $true)]
        [DateTime]$NextPolicySyncAt
    )

    $desired = [Math]::Max(1, $DesiredSeconds)
    $now = Get-Date

    if ($NextPolicySyncAt -le $now) {
        return 1
    }

    $untilSync = [Math]::Max(1, [int][Math]::Ceiling(($NextPolicySyncAt - $now).TotalSeconds))
    return [Math]::Max(1, [Math]::Min($desired, $untilSync))
}

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$hasLock = $false
$lastWallpaperKey = ''
$slideIndex = 0
$slideOrder = @()
$slideOrderKey = ''
$policyState = $null
$policyHash = ''
$nextPolicySyncAt = [DateTime]::MinValue

try {
    $hasLock = $mutex.WaitOne(0, $false)

    if (-not $hasLock) {
        Write-Log 'Another slideshow instance is already running. Exit.'
        exit 0
    }

    Remove-StopSignal
    Import-WallpaperNativeApi
    Ensure-BlackWallpaper

    Write-Log "Started. DryRun=$DryRun Once=$Once ScriptRoot='$ScriptRoot'."

    while ($true) {
        if (Test-Path -LiteralPath $StopSignalPath -PathType Leaf) {
            Write-Log 'Stop signal detected.'
            Remove-StopSignal
            break
        }

        $sleepSeconds = 10
        $agentConfig = Read-AgentConfig

        try {
            if ($null -eq $policyState -or (Get-Date) -ge $nextPolicySyncAt) {
                $newPolicyState = Sync-PolicyState -AgentConfig $agentConfig

                if ($newPolicyState.PolicyHash -ne $policyHash) {
                    $slideIndex = 0
                    $slideOrder = @()
                    $slideOrderKey = ''
                    $lastWallpaperKey = ''
                    $policyHash = $newPolicyState.PolicyHash
                    Write-Log 'Policy changed; slide index reset.'
                }

                $policyState = $newPolicyState
                $nextPolicySyncAt = (Get-Date).AddSeconds([int]$policyState.Policy.policyPollSeconds)
            }

            if ($null -eq $policyState) {
                throw 'Policy state is not available.'
            }

            $policy = $policyState.Policy
            $images = @($policyState.Images)
            $campaignState = Get-CampaignState -Policy $policy
            $style = [string]$policy.wallpaperStyle

            if ($campaignState -ne 'Active') {
                if ($lastWallpaperKey -ne $BlackWallpaperPath) {
                    Set-DesktopWallpaper -Path $BlackWallpaperPath -Style $style -DryRunMode:$DryRun
                    $lastWallpaperKey = $BlackWallpaperPath
                    Write-Log "Campaign state is '$campaignState'. Black wallpaper applied."
                }

                $sleepSeconds = Get-LoopSleepSeconds -DesiredSeconds ([int]$policy.configReloadSeconds) -NextPolicySyncAt $nextPolicySyncAt
            }
            elseif ($images.Count -eq 0) {
                if ($lastWallpaperKey -ne $BlackWallpaperPath) {
                    Set-DesktopWallpaper -Path $BlackWallpaperPath -Style $style -DryRunMode:$DryRun
                    $lastWallpaperKey = $BlackWallpaperPath
                    Write-Log 'Active policy has no cached images. Black wallpaper applied.' 'WARN'
                }

                $sleepSeconds = Get-LoopSleepSeconds -DesiredSeconds ([int]$policy.configReloadSeconds) -NextPolicySyncAt $nextPolicySyncAt
            }
            else {
                $imageSetKey = '{0}|{1}|{2}' -f $policyHash, [bool]$policy.shuffle, (($images | ForEach-Object { '{0}:{1}:{2}' -f $_.FullName, $_.LastWriteTimeUtc.Ticks, $_.Length }) -join ';')

                if ($slideOrderKey -ne $imageSetKey -or $slideOrder.Count -ne $images.Count) {
                    $slideOrder = @(0..($images.Count - 1))

                    if ([bool]$policy.shuffle -and $slideOrder.Count -gt 1) {
                        $slideOrder = @($slideOrder | Sort-Object { Get-Random })
                    }

                    $slideIndex = 0
                    $slideOrderKey = $imageSetKey
                }

                if ($slideIndex -ge $slideOrder.Count) {
                    $slideIndex = 0

                    if ([bool]$policy.shuffle -and $slideOrder.Count -gt 1) {
                        $slideOrder = @($slideOrder | Sort-Object { Get-Random })
                        Write-Log 'Slide cycle completed; shuffled order reset.'
                    }
                    else {
                        Write-Log 'Slide cycle completed; restarting from first image.'
                    }
                }

                $selectedImage = $images[[int]$slideOrder[$slideIndex]]
                $slideIndex++

                $selectedImageKey = '{0}|{1}|{2}|{3}|{4}' -f $policyHash, $selectedImage.FullName, $selectedImage.LastWriteTimeUtc.Ticks, $selectedImage.Length, $policy.safeAreaPaddingPixels

                if ($lastWallpaperKey -ne $selectedImageKey) {
                    $wallpaperPath = $selectedImage.FullName
                    $applyStyle = $style

                    if ([bool]$policy.avoidTaskbar) {
                        $wallpaperPath = ConvertTo-TaskbarSafeWallpaper -SourcePath $selectedImage.FullName -PaddingPixels ([int]$policy.safeAreaPaddingPixels)
                        $applyStyle = 'Stretch'
                    }

                    Set-DesktopWallpaper -Path $wallpaperPath -Style $applyStyle -DryRunMode:$DryRun
                    $lastWallpaperKey = $selectedImageKey
                }

                $sleepSeconds = Get-LoopSleepSeconds -DesiredSeconds ([int]$policy.slideIntervalSeconds) -NextPolicySyncAt $nextPolicySyncAt
            }
        }
        catch {
            Write-Log "Loop error: $($_.Exception.Message)" 'ERROR'

            try {
                Set-DesktopWallpaper -Path $BlackWallpaperPath -Style 'Fit' -DryRunMode:$DryRun
                $lastWallpaperKey = $BlackWallpaperPath
            }
            catch {
                Write-Log "Failed to apply black fallback: $($_.Exception.Message)" 'ERROR'
            }

            $nextPolicySyncAt = (Get-Date).AddSeconds([int]$agentConfig.serverPollSeconds)
            $sleepSeconds = Get-LoopSleepSeconds -DesiredSeconds 10 -NextPolicySyncAt $nextPolicySyncAt
        }

        if ($Once) {
            break
        }

        Start-Sleep -Seconds $sleepSeconds
    }
}
finally {
    if ($hasLock) {
        $mutex.ReleaseMutex() | Out-Null
    }

    $mutex.Dispose()
    Write-Log 'Stopped.'
}
