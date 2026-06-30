@echo off
setlocal

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
if "%ROOT:~-1%"==":" set "ROOT=%ROOT%\"
set "PORT=28080"
set "PREFIX=http://+:%PORT%/"
set "FIREWALL_RULE=Safety Wallpaper Server 28080"

netsh http add urlacl url=%PREFIX% user=Everyone >nul 2>nul

if errorlevel 1 (
    netsh http show urlacl | findstr /C:"%PREFIX%" >nul 2>nul

    if errorlevel 1 (
        echo Failed to reserve %PREFIX%.
        echo Run this batch as Administrator on the server first.
        pause
        exit /b 1
    )
)

netsh advfirewall firewall show rule name="%FIREWALL_RULE%" >nul 2>nul

if errorlevel 1 (
    netsh advfirewall firewall add rule name="%FIREWALL_RULE%" dir=in action=allow protocol=TCP localport=%PORT% profile=any >nul 2>nul

    if errorlevel 1 (
        echo Failed to add Windows Firewall rule for TCP %PORT%.
        echo Run this batch as Administrator, or run:
        echo netsh advfirewall firewall add rule name="%FIREWALL_RULE%" dir=in action=allow protocol=TCP localport=%PORT% profile=any
        pause
        exit /b 1
    )
)

echo Safety wallpaper server starting on port %PORT%.
echo Policy URL: http://172.16.19.35:%PORT%/safety-wallpaper/policy.json
echo Press Ctrl+C to stop.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\SafetyWallpaperStaticServer.ps1" -Root "%ROOT%" -Port %PORT%

endlocal
exit /b 0
