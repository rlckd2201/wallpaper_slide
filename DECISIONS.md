# Decisions

## Confirmed
- The program is for internal safety education and promotional display.
- The deployment target is all users through NAC deployment/install.
- Images must be administrator-replaceable after deployment.
- The app must stop showing expired campaign images and return to a plain black background.
- Use `.bat + PowerShell` as the first executable deployment format because the user allowed `.exe` or `.bat`.
- Change the actual current-user Windows wallpaper rather than drawing a separate overlay window.
- Use `http://172.16.19.35:28080/safety-wallpaper/policy.json` as the default central control policy endpoint.
- Store only agent bootstrap settings in `config.json`.
- Store campaign period, slide timing, taskbar behavior, slide count, and image list in server `policy.json`.
- Manage server `policy.json` and uploaded images through a Windows PowerShell WinForms administrator GUI.
- Use a campaign-wide schedule for the first version.
- Keep `avoidTaskbar` enabled by default and render active slides into the primary screen working area before applying them.
- `StartSafetyWallpaperSlideshow.bat` registers a current-user startup entry and launches the agent through hidden VBS.

## Pending
- Whether production startup registration should use HKCU Run, HKLM Run, or Task Scheduler under NAC.
- Whether to build a compiled `.exe` wrapper later.
- Exact Windows version support target.
