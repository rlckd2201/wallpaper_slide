# 서버 관리자 실행 안내

이 폴더는 `172.16.19.35:28080`에서 안전 배경화면 정책과 이미지를 배포하는 서버용 파일입니다.

## 서버에서 처음 실행

관리자 권한 PowerShell 또는 CMD에서 실행하세요.

```bat
cd /d C:\SafetyWallpaperRepo\server-policy-sample
StartSafetyWallpaperServer.bat
```

처음 실행할 때 배치 파일이 자동으로 처리하는 것:

- `http://+:28080/` 주소 사용 권한 등록
- Windows 방화벽 TCP `28080` 인바운드 허용
- 관리자 웹페이지 실행
- 정책 파일과 이미지 파일 배포
- 이미지 다운로드 동시 처리 최대 5명 제한

## 관리자 화면

브라우저에서 아래 주소를 여세요.

```text
http://172.16.19.35:28080/safety-wallpaper/admin
```

관리자가 할 일:

- 그림을 업로드합니다. 드래그 앤 드롭 가능
- 게시 시작일과 종료일을 정합니다.
- 배포할 그림만 체크합니다.
- `바로 적용`을 누릅니다.

임직원 PC는 기본 10분마다 정책을 다시 확인하고, 바뀐 내용이 있으면 자동 반영합니다.

## 서버 업데이트

Git에서 최신 파일을 받은 뒤 서버를 다시 실행하세요.

```bat
cd /d C:\SafetyWallpaperRepo
git pull
cd /d C:\SafetyWallpaperRepo\server-policy-sample
StartSafetyWallpaperServer.bat
```

## 확인 명령

서버 안에서 확인:

```bat
powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing http://127.0.0.1:28080/safety-wallpaper/policy.json"
```

사용자 PC에서 확인:

```bat
tcping 172.16.19.35 28080
```

사용자 PC에서 접속이 안 되면 서버 방화벽을 확인하세요.

```bat
netsh advfirewall firewall add rule name="Safety Wallpaper Server 28080" dir=in action=allow protocol=TCP localport=28080 profile=any
```

## 배포 정책 주소

임직원 PC 에이전트가 보는 주소입니다.

```text
http://172.16.19.35:28080/safety-wallpaper/policy.json
```
