@echo off
setlocal

set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%SafetyWallpaperAdminGui.ps1"

endlocal
exit /b 0
