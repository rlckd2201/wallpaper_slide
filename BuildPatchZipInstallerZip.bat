@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "ROOT=%~dp0"
set "DIST=%ROOT%dist"
set "SOURCE=%ROOT%nac-patch-bootstrap\InstallSafetyWallpaperAgentFromZip.bat"
set "STARTUP_SOURCE=%ROOT%SafetyWallpaperSlideshowStartup.vbs"
set "ZIP_PATH=%DIST%\InstallSafetyWallpaperAgentFromZip.zip"
set "SW_SOURCE=%SOURCE%"
set "SW_STARTUP_SOURCE=%STARTUP_SOURCE%"
set "SW_ZIP=%ZIP_PATH%"

if not exist "%DIST%" mkdir "%DIST%" >nul 2>nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $source=$env:SW_SOURCE; $startupSource=$env:SW_STARTUP_SOURCE; $zip=$env:SW_ZIP; $paths=@($source,$startupSource); foreach($path in $paths){ if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ throw \"Missing package file: $path\" } }; if(Test-Path -LiteralPath $zip){ Remove-Item -LiteralPath $zip -Force }; Compress-Archive -LiteralPath $paths -DestinationPath $zip -CompressionLevel Optimal"

if errorlevel 1 (
    echo Bootstrap ZIP build failed.
    exit /b 1
)

echo Built: %ZIP_PATH%
exit /b 0
