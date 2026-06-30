@echo off
setlocal

set "ROOT=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%SafetyWallpaperSlideshow.ps1" -DryRun -Once
pause

endlocal
