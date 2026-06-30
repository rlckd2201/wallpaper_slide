@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "ZIP_PATH="
set "INSTALL_DIR=%ProgramData%\SafetyWallpaper"
set "NO_START="

if /I "%~1"=="/?" goto usage
if /I "%~1"=="-h" goto usage

for %%A in (%*) do (
    if /I "%%~A"=="/no-start" set "NO_START=1"
)

if not "%~1"=="" if /I not "%~1"=="/no-start" set "ZIP_PATH=%~1"
if not "%~2"=="" if /I not "%~2"=="/no-start" set "INSTALL_DIR=%~2"

if not defined ZIP_PATH if exist "%SCRIPT_DIR%SafetyWallpaperAgent.zip" set "ZIP_PATH=%SCRIPT_DIR%SafetyWallpaperAgent.zip"

if not defined ZIP_PATH (
    set "SW_SCRIPT_DIR=%SCRIPT_DIR%"
    for /f "usebackq delims=" %%Z in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$zip = Get-ChildItem -LiteralPath $env:SW_SCRIPT_DIR -Filter '*.zip' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName; if ($zip) { $zip }"`) do set "ZIP_PATH=%%Z"
)

if not defined ZIP_PATH (
    echo ZIP file not found.
    exit /b 10
)

if not exist "%ZIP_PATH%" (
    echo ZIP file not found: %ZIP_PATH%
    exit /b 11
)

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%" >nul 2>nul
if errorlevel 1 (
    echo Install directory create failed: %INSTALL_DIR%
    exit /b 12
)

set "LOG_FILE=%INSTALL_DIR%\install.log"
call :log "Install started."
call :log "ZIP=%ZIP_PATH%"
call :log "INSTALL_DIR=%INSTALL_DIR%"

if exist "%INSTALL_DIR%\.runtime" (
    echo stop>"%INSTALL_DIR%\.runtime\stop.signal" 2>nul
    echo stop>"%INSTALL_DIR%\.runtime\tray.stop.signal" 2>nul
    timeout /t 2 /nobreak >nul 2>nul
)

set "SW_ZIP=%ZIP_PATH%"
set "SW_INSTALL_DIR=%INSTALL_DIR%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $zip=$env:SW_ZIP; $dest=$env:SW_INSTALL_DIR; New-Item -ItemType Directory -Force -Path $dest | Out-Null; Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force"
if errorlevel 1 (
    call :log "ZIP extract failed."
    echo ZIP extract failed.
    exit /b 20
)

icacls "%INSTALL_DIR%" /grant *S-1-5-32-545:(OI)(CI)M /T >nul 2>nul

set "START_BAT=%INSTALL_DIR%\StartSafetyWallpaperSlideshow.bat"
if not exist "%START_BAT%" (
    set "SW_INSTALL_DIR=%INSTALL_DIR%"
    for /f "usebackq delims=" %%B in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$bat = Get-ChildItem -LiteralPath $env:SW_INSTALL_DIR -Filter 'StartSafetyWallpaperSlideshow.bat' -File -Recurse | Sort-Object FullName | Select-Object -First 1 -ExpandProperty FullName; if ($bat) { $bat }"`) do set "START_BAT=%%B"
)

if not exist "%START_BAT%" (
    call :log "StartSafetyWallpaperSlideshow.bat not found after extract."
    echo StartSafetyWallpaperSlideshow.bat not found after extract.
    exit /b 21
)

call :log "START_BAT=%START_BAT%"

if defined NO_START (
    call :log "Install completed without starting."
    exit /b 0
)

call "%START_BAT%"
set "START_EXIT=%ERRORLEVEL%"
call :log "Install completed. Start exit=%START_EXIT%"
exit /b %START_EXIT%

:usage
echo Usage: InstallSafetyWallpaperAgentFromZip.bat [zip_path] [install_dir] [/no-start]
exit /b 0

:log
echo [%date% %time%] %~1>>"%LOG_FILE%"
exit /b 0
