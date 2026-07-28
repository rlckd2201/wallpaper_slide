@echo off
setlocal

set "ROOT=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%SafetyWallpaperSlideshow_v2.ps1" -DryRun -Once
pause

endlocal
