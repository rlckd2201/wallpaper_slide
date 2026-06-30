@echo off
setlocal

set "TARGET_DIR=%~1"
set "BRANCH=%~2"

if "%TARGET_DIR%"=="" set "TARGET_DIR=C:\SafetyWallpaperRepo"
if "%BRANCH%"=="" set "BRANCH=main"

if not exist "%TARGET_DIR%\.git" (
    echo Git repo not found: %TARGET_DIR%
    echo Run InstallOrUpdateSafetyWallpaperServerFromGit.bat first.
    exit /b 1
)

pushd "%TARGET_DIR%"
git fetch origin
git checkout "%BRANCH%"
git pull --ff-only origin "%BRANCH%"
set "GIT_RESULT=%ERRORLEVEL%"
popd

if not "%GIT_RESULT%"=="0" (
    echo Git update failed.
    exit /b %GIT_RESULT%
)

echo Git update complete.

endlocal
exit /b 0
