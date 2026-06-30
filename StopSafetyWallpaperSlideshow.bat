@echo off
setlocal

set "ROOT=%~dp0"
set "RUNTIME_DIR=%ROOT%.runtime"

if not exist "%RUNTIME_DIR%" mkdir "%RUNTIME_DIR%"
type nul > "%RUNTIME_DIR%\stop.signal"

echo Safety wallpaper slideshow stop requested.
echo It will exit after the current wait interval.

endlocal
