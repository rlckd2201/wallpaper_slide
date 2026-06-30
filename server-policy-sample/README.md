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
StartSafetyWallpaperAdminGui.bat
StartSafetyWallpaperServer.bat
```

Run the batch as Administrator the first time so it can reserve URL `http://+:28080/` and add a Windows Firewall inbound rule for TCP `28080`.

Git-based install/update on `172.16.19.35`:

```bat
InstallOrUpdateSafetyWallpaperServerFromGit.bat https://github.com/rlckd2201/wallpaper_slide.git main C:\SafetyWallpaperRepo
```

After that, update only:

```bat
C:\SafetyWallpaperRepo\server-policy-sample\UpdateOnlyFromGit.bat C:\SafetyWallpaperRepo main
```

The repository must contain this project with `server-policy-sample\StartSafetyWallpaperServer.bat`.

Admin GUI:
- Run `StartSafetyWallpaperAdminGui.bat` on the server.
- Add images through `Add Images`.
- Check only the images that should be distributed.
- Set posting period, slide wait time, polling interval, shuffle, and taskbar-safe layout.
- Click `Save Policy`.
- User agents check the policy every 10 minutes by default and apply changes when `policy.json` changes.

Quick test on the server:

```bat
powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing http://127.0.0.1:28080/safety-wallpaper/policy.json"
```

Quick test from a user PC:

```bat
tcping 172.16.19.35 28080
```

Manual firewall command on the server:

```bat
netsh advfirewall firewall add rule name="Safety Wallpaper Server 28080" dir=in action=allow protocol=TCP localport=28080 profile=any
```

Agent behavior:
- Each user PC reads `policy.json` every `policyPollSeconds` seconds.
- Default poll interval is 600 seconds, which is 10 minutes.
- Image URLs may be relative to `policy.json`, absolute HTTP URLs, file paths, or UNC paths.
- The agent downloads images into `.runtime/policy-cache/images`.
- The server allows up to 5 concurrent image downloads; additional image requests wait in a queue.
- Policy JSON requests are not counted as image downloads and continue to respond immediately.
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
