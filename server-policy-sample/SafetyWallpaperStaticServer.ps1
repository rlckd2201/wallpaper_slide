param(
    [string]$Root = $PSScriptRoot,
    [int]$Port = 28080
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = (Resolve-Path -LiteralPath $Root).Path
$Prefix = "http://+:$Port/"
$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Prefix)

function Get-ContentType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.json' { return 'application/json; charset=utf-8' }
        '.png' { return 'image/png' }
        '.jpg' { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.bmp' { return 'image/bmp' }
        '.gif' { return 'image/gif' }
        default { return 'application/octet-stream' }
    }
}

function Send-Text {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'text/plain; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

$Listener.Start()
Write-Host "Safety wallpaper policy server started."
Write-Host "URL: http://172.16.19.35:$Port/safety-wallpaper/policy.json"
Write-Host "Root: $RootPath"
Write-Host "Press Ctrl+C to stop."

try {
    while ($Listener.IsListening) {
        $context = $Listener.GetContext()
        $requestPath = [System.Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart('/'))

        if ($requestPath -eq '') {
            $requestPath = 'safety-wallpaper/policy.json'
        }

        if (-not $requestPath.StartsWith('safety-wallpaper/')) {
            Send-Text -Response $context.Response -StatusCode 404 -Text 'Not found'
            $context.Response.Close()
            continue
        }

        $relativePath = $requestPath.Substring('safety-wallpaper/'.Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RootPath $relativePath))

        if (-not $fullPath.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Send-Text -Response $context.Response -StatusCode 403 -Text 'Forbidden'
            $context.Response.Close()
            continue
        }

        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Send-Text -Response $context.Response -StatusCode 404 -Text 'Not found'
            $context.Response.Close()
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        $context.Response.StatusCode = 200
        $context.Response.ContentType = Get-ContentType -Path $fullPath
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()
    }
}
finally {
    if ($Listener.IsListening) {
        $Listener.Stop()
    }

    $Listener.Close()
}
