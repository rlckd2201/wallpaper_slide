@echo off
setlocal
chcp 65001 >nul

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
if "%ROOT:~-1%"==":" set "ROOT=%ROOT%\"
set "PORT=28080"
set "MAX_IMAGE_DOWNLOADS=5"
set "PREFIX=http://+:%PORT%/"
set "FIREWALL_RULE=Safety Wallpaper Server 28080"

netsh http add urlacl url=%PREFIX% user=Everyone >nul 2>nul

if errorlevel 1 (
    netsh http show urlacl | findstr /C:"%PREFIX%" >nul 2>nul

    if errorlevel 1 (
        echo 주소 사용 권한 등록 실패: %PREFIX%
        echo 서버에서 이 배치 파일을 관리자 권한으로 실행하세요.
        pause
        exit /b 1
    )
)

netsh advfirewall firewall show rule name="%FIREWALL_RULE%" >nul 2>nul

if errorlevel 1 (
    netsh advfirewall firewall add rule name="%FIREWALL_RULE%" dir=in action=allow protocol=TCP localport=%PORT% profile=any >nul 2>nul

    if errorlevel 1 (
        echo Windows 방화벽 TCP %PORT% 허용 실패.
        echo 서버에서 이 배치 파일을 관리자 권한으로 실행하거나 아래 명령을 실행하세요.
        echo netsh advfirewall firewall add rule name="%FIREWALL_RULE%" dir=in action=allow protocol=TCP localport=%PORT% profile=any
        pause
        exit /b 1
    )
)

echo 안전 배경화면 서버 시작: 포트 %PORT%
echo 관리자 페이지: http://172.16.19.35:%PORT%/safety-wallpaper/admin
echo 정책 주소: http://172.16.19.35:%PORT%/safety-wallpaper/policy.json
echo 이미지 다운로드 동시 처리: 최대 %MAX_IMAGE_DOWNLOADS%명
echo 종료하려면 Ctrl+C를 누르세요.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\SafetyWallpaperStaticServer.ps1" -Root "%ROOT%" -Port %PORT% -MaxImageDownloads %MAX_IMAGE_DOWNLOADS%

endlocal
exit /b 0
