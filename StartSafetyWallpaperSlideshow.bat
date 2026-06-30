@echo off
setlocal

set "ROOT=%~dp0"
set "LAUNCHER=%ROOT%RunSafetyWallpaperSlideshowHidden.vbs"
set "RUN_KEY=HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
set "RUN_VALUE=SafetyWallpaperSlideshow"
set "RUN_COMMAND=wscript.exe //B //Nologo \"%LAUNCHER%\""

reg add "%RUN_KEY%" /v "%RUN_VALUE%" /t REG_SZ /d "%RUN_COMMAND%" /f >nul 2>nul
wscript.exe //B //Nologo "%LAUNCHER%"

endlocal
exit /b 0
