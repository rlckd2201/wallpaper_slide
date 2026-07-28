@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "AGENT_ZIP=C:\Program Files\Geni\Genian\Patch\2BC78C2AD6C147057FC9CBDE61757BBAD64C306E.zip"
set "INSTALL_DIR=%ProgramData%\SafetyWallpaper"
set "NO_START="

if /I "%~1"=="/no-start" set "NO_START=1"

if not exist "%AGENT_ZIP%" (
    echo Agent ZIP not found: %AGENT_ZIP%
    exit /b 10
)

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%" >nul 2>nul
if errorlevel 1 (
    echo Install directory create failed: %INSTALL_DIR%
    exit /b 11
)

set "LOG_FILE=%INSTALL_DIR%\install.log"
call :log "Patch ZIP installer started."
call :log "ZIP=%AGENT_ZIP%"

if exist "%INSTALL_DIR%\.runtime" (
    echo stop>"%INSTALL_DIR%\.runtime\stop.signal" 2>nul
    echo stop>"%INSTALL_DIR%\.runtime\tray.stop.signal" 2>nul
    timeout /t 2 /nobreak >nul 2>nul
)

set "SW_AGENT_ZIP=%AGENT_ZIP%"
set "SW_INSTALL_DIR=%INSTALL_DIR%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $zip=$env:SW_AGENT_ZIP; $dest=$env:SW_INSTALL_DIR; New-Item -ItemType Directory -Force -Path $dest | Out-Null; Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force"
if errorlevel 1 (
    call :log "Agent ZIP extract failed."
    echo Agent ZIP extract failed.
    exit /b 20
)

icacls "%INSTALL_DIR%" /grant *S-1-5-32-545:(OI)(CI)M /T >nul 2>nul

set "START_BAT=%INSTALL_DIR%\StartSafetyWallpaperSlideshow.bat"
if not exist "%START_BAT%" (
    call :log "StartSafetyWallpaperSlideshow.bat not found after extract."
    echo StartSafetyWallpaperSlideshow.bat not found after extract.
    exit /b 21
)

if defined NO_START (
    call :log "Install completed without starting."
    exit /b 0
)

call "%START_BAT%"
set "START_EXIT=%ERRORLEVEL%"
call :log "Install completed. Start exit=%START_EXIT%"
exit /b %START_EXIT%

:log
echo [%date% %time%] %~1>>"%LOG_FILE%"
exit /b 0
