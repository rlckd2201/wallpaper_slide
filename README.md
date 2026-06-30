# 안전 배경화면 슬라이드쇼

사내 안전 홍보 이미지를 Windows 바탕화면 배경으로 슬라이드 쇼처럼 순환 설정하는 실행형 배포 묶음입니다.

## 실행
- 시작 및 자동시작 등록: `StartSafetyWallpaperSlideshow.bat`
- 중지: `StopSafetyWallpaperSlideshow.bat`
- 자동시작 해제 및 중지: `UnregisterSafetyWallpaperStartup.bat`
- 실제 배경화면 변경 없이 1회 점검: `TestSafetyWallpaperSlideshow.bat`

## 관리자 변경 항목
- 관리자 페이지: `http://172.16.19.35:28080/safety-wallpaper/admin`
- 서버 정책 파일: `http://172.16.19.35:28080/safety-wallpaper/policy.json`
- Git 저장소: `https://github.com/rlckd2201/wallpaper_slide.git`
- 사용자 PC 로컬 설정: `config.json`에서 정책 URL, 10분 동기화 간격, 캐시 폴더만 관리합니다.
- 이미지와 캠페인 정책은 관리자 웹페이지에서 관리합니다.
- 서버에서 바로 띄울 때: `server-policy-sample/StartSafetyWallpaperServer.bat`
- 서버 이미지 다운로드 동시 처리: 최대 5개, 초과 요청은 대기
- 서버에서 git으로 받을 때: `server-policy-sample/InstallOrUpdateSafetyWallpaperServerFromGit.bat`

## 동작 규칙
- 사용자는 `StartSafetyWallpaperSlideshow.bat` 실행 순간부터 백그라운드 에이전트로 동작합니다.
- 시작 배치는 현재 사용자 시작프로그램에 자동 등록합니다.
- 임직원 PC에는 트레이 아이콘이 표시됩니다.
- 트레이 아이콘의 `정책 새로고침`을 누르면 10분 주기를 기다리지 않고 정책을 즉시 다시 확인합니다.
- 에이전트는 기본 10분마다 `172.16.19.35:28080` 서버 정책을 확인합니다.
- 슬라이드는 마지막 이미지까지 표시한 뒤 다시 첫 이미지부터 반복합니다.
- `shuffle`이 `true`여도 한 바퀴 안에서 모든 이미지를 한 번씩 표시한 뒤 다음 바퀴에서 다시 섞습니다.
- `campaignStart` 전이거나 `campaignEnd` 이후이면 검은 배경화면을 적용합니다.
- 이미지가 없거나 오류가 나면 검은 배경화면을 적용합니다.
- 서버가 잠시 죽어도 마지막으로 받은 정책과 이미지 캐시가 있으면 계속 적용합니다.
- `avoidTaskbar`가 `true`이면 작업표시줄에 이미지 하단이 가려지지 않도록 보정본을 만들어 적용합니다.
- 로그는 `logs/wallpaper-slideshow.log`에 남습니다.
