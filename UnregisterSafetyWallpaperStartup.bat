@echo off
setlocal

set "ROOT=%~dp0"
set "RUNTIME_DIR=%ROOT%.runtime"
set "COMMON_STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup"
set "COMMON_STARTUP_FILE=%COMMON_STARTUP%\SafetyWallpaperSlideshowStartup.vbs"
set "RUN_KEY=HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
set "RUN_VALUE=SafetyWallpaperSlideshow"

reg delete "%RUN_KEY%" /v "%RUN_VALUE%" /f >nul 2>nul
del /f /q "%COMMON_STARTUP_FILE%" >nul 2>nul

if not exist "%RUNTIME_DIR%" mkdir "%RUNTIME_DIR%"
type nul > "%RUNTIME_DIR%\stop.signal"

echo Safety wallpaper slideshow startup entry removed.
echo Stop requested for the running agent.

endlocal
exit /b 0
