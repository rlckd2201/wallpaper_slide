@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "ROOT=%~dp0"
set "DIST=%ROOT%dist"
set "ZIP_PATH=%DIST%\SafetyWallpaperAgent.zip"
set "SW_ROOT=%ROOT%"
set "SW_ZIP=%ZIP_PATH%"

if not exist "%DIST%" mkdir "%DIST%" >nul 2>nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $root=$env:SW_ROOT; $zip=$env:SW_ZIP; $files=@('StartSafetyWallpaperSlideshow.bat','RunSafetyWallpaperSlideshowHidden.vbs','SafetyWallpaperSlideshow.ps1','SafetyWallpaperTray.ps1','StopSafetyWallpaperSlideshow.bat','UnregisterSafetyWallpaperStartup.bat','config.json'); $paths=$files | ForEach-Object { Join-Path $root $_ }; foreach($path in $paths){ if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ throw \"Missing package file: $path\" } }; if(Test-Path -LiteralPath $zip){ Remove-Item -LiteralPath $zip -Force }; Compress-Archive -LiteralPath $paths -DestinationPath $zip -CompressionLevel Optimal"

if errorlevel 1 (
    echo ZIP build failed.
    exit /b 1
)

echo Built: %ZIP_PATH%
exit /b 0
