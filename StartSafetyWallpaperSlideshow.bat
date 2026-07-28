@echo off
setlocal

set "ROOT=%~dp0"
set "LAUNCHER=%ROOT%RunSafetyWallpaperSlideshowHidden.vbs"
set "STARTUP_SOURCE=%ROOT%SafetyWallpaperSlideshowStartup.vbs"
set "COMMON_STARTUP=%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup"
set "COMMON_STARTUP_FILE=%COMMON_STARTUP%\SafetyWallpaperSlideshowStartup.vbs"
set "RUN_KEY=HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
set "RUN_VALUE=SafetyWallpaperSlideshow"
set "RUN_COMMAND=wscript.exe //B //Nologo \"%LAUNCHER%\""

if exist "%STARTUP_SOURCE%" (
    if not exist "%COMMON_STARTUP%" mkdir "%COMMON_STARTUP%" >nul 2>nul
    copy /y "%STARTUP_SOURCE%" "%COMMON_STARTUP_FILE%" >nul 2>nul
)

reg add "%RUN_KEY%" /v "%RUN_VALUE%" /t REG_SZ /d "%RUN_COMMAND%" /f >nul 2>nul
wscript.exe //B //Nologo "%LAUNCHER%"

endlocal
exit /b 0
