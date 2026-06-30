@echo off
setlocal

set "REPO_URL=%~1"
set "BRANCH=%~2"
set "TARGET_DIR=%~3"

if "%REPO_URL%"=="" (
    echo Usage:
    echo   InstallOrUpdateSafetyWallpaperServerFromGit.bat ^<git-repo-url^> [branch] [target-dir]
    echo.
    echo Example:
    echo   InstallOrUpdateSafetyWallpaperServerFromGit.bat https://github.com/ORG/REPO.git main C:\SafetyWallpaperRepo
    exit /b 1
)

if "%BRANCH%"=="" set "BRANCH=main"
if "%TARGET_DIR%"=="" set "TARGET_DIR=C:\SafetyWallpaperRepo"

git --version >nul 2>nul
if errorlevel 1 (
    echo Git is not installed or not in PATH.
    exit /b 1
)

if exist "%TARGET_DIR%\.git" (
    echo Updating existing repo: %TARGET_DIR%
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
) else (
    echo Cloning repo into: %TARGET_DIR%
    git clone --branch "%BRANCH%" "%REPO_URL%" "%TARGET_DIR%"

    if errorlevel 1 (
        echo Git clone failed.
        exit /b 1
    )
)

if not exist "%TARGET_DIR%\server-policy-sample\StartSafetyWallpaperServer.bat" (
    echo Cannot find server-policy-sample\StartSafetyWallpaperServer.bat in repo.
    echo Check that the repo contains this project folder.
    exit /b 1
)

echo.
echo Starting safety wallpaper server from git checkout.
echo Server folder: %TARGET_DIR%\server-policy-sample
echo.

call "%TARGET_DIR%\server-policy-sample\StartSafetyWallpaperServer.bat"

endlocal
exit /b 0
