# Server Policy Sample

Place this folder's contents under the web root that serves:

`http://172.16.19.35:28080/safety-wallpaper/policy.json`

Recommended server layout:

```text
safety-wallpaper/
  policy.json
  images/
    no-yangrae-pinch.png
    no-yangrae-fall.png
```

If this folder itself is used as the server root, keep the files like this:

```text
server-policy-sample/
  StartSafetyWallpaperServer.bat
  SafetyWallpaperStaticServer.ps1
  policy.json
  images/
    no-yangrae-pinch.png
    no-yangrae-fall.png
```

Run on `172.16.19.35`:

```bat
cd /d C:\SafetyWallpaperServer
StartSafetyWallpaperServer.bat
```

Run the batch as Administrator the first time so `netsh http add urlacl` can reserve port `28080`.

Git-based install/update on `172.16.19.35`:

```bat
InstallOrUpdateSafetyWallpaperServerFromGit.bat https://github.com/rlckd2201/wallpaper_slide.git main C:\SafetyWallpaperRepo
```

After that, update only:

```bat
C:\SafetyWallpaperRepo\server-policy-sample\UpdateOnlyFromGit.bat C:\SafetyWallpaperRepo main
```

The repository must contain this project with `server-policy-sample\StartSafetyWallpaperServer.bat`.

Quick test on the server:

```bat
powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing http://127.0.0.1:28080/safety-wallpaper/policy.json"
```

Quick test from a user PC:

```bat
tcping 172.16.19.35 28080
```

Agent behavior:
- Each user PC reads `policy.json` every `policyPollSeconds` seconds.
- Default poll interval is 600 seconds, which is 10 minutes.
- Image URLs may be relative to `policy.json`, absolute HTTP URLs, file paths, or UNC paths.
- The agent downloads images into `.runtime/policy-cache/images`.
- If the server is temporarily unavailable, the agent keeps using the last cached policy and images.
- If no valid policy or image cache exists, the agent applies a plain black wallpaper.

Policy controls:
- `enabled`: turn the campaign on or off.
- `campaignStart`, `campaignEnd`: active posting period.
- `slideIntervalSeconds`: wait time between wallpaper changes.
- `policyPollSeconds`: server check interval.
- `maxSlides`: `0` means use every enabled slide; a positive number limits the slide count from the top of the list.
- `shuffle`: randomize slide order. Every enabled slide is shown once per cycle before the next reshuffle.
- `avoidTaskbar`: keep slide content above the taskbar.
- `safeAreaPaddingPixels`: extra black margin inside the taskbar-safe area.
