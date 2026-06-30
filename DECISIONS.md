# Decisions

## Confirmed
- The program is for internal safety education and promotional display.
- The deployment target is all users through NAC deployment/install.
- Images must be administrator-replaceable after deployment.
- The app must stop showing expired campaign images and return to a plain black background.
- Use `.bat + PowerShell` as the first executable deployment format because the user allowed `.exe` or `.bat`.
- NAC employee deployment uses two artifacts: `SafetyWallpaperAgent.zip` plus `InstallSafetyWallpaperAgentFromZip.bat`; the BAT extracts the ZIP to `%ProgramData%\SafetyWallpaper` and then starts/registers the agent.
- Change the actual current-user Windows wallpaper rather than drawing a separate overlay window.
- Use `http://172.16.19.35:28080/safety-wallpaper/policy.json` as the default central control policy endpoint.
- Store only agent bootstrap settings in `config.json`.
- Store campaign period, slide timing, taskbar behavior, slide count, and image list in server `policy.json`.
- Manage server `policy.json` and uploaded images through the web administrator page served by the same server.
- Treat `/safety-wallpaper/admin` as the primary administrator UI for safety staff.
- Require web admin login before policy/image management API calls.
- Use `operator` for safety team administrators and `super` for top-level administrators.
- Super admin menus are restricted server-side as well as hidden client-side.
- Existing ignored `admin-users.json` is merged with missing seed accounts on server start, but existing password hashes are not overwritten.
- Keep `policy.json` and image files publicly readable inside the internal network so employee agents can keep polling/downloading without credentials.
- Keep seeded admin users in `admin-users.sample.json`; copy to ignored `admin-users.json` on first server start so changed passwords survive Git updates.
- Password reset does not reveal the old password; it generates a temporary password, stores only its hash, emails it, and sets `mustChangePassword=true`.
- If SMTP settings are missing or sending fails, password reset does not leave a new unknown password active; send failure rolls back the previous hash.
- Keep SMTP credentials out of Git by using ignored `server-policy-sample/mail-settings.json`.
- Use a campaign-wide schedule for the first version.
- Keep `avoidTaskbar` enabled by default and render active slides into the primary screen working area before applying them.
- `StartSafetyWallpaperSlideshow.bat` registers a current-user startup entry and launches the agent through hidden VBS.
- Employee startup launches both the hidden wallpaper agent and a tray controller.
- Tray policy refresh writes `.runtime/refresh.signal`; the agent detects it and syncs policy immediately.
- Tray UI Korean labels are built from Unicode code points instead of literal Korean strings to avoid Windows PowerShell 5.1 ANSI decoding corruption.
- Web admin uploads send Korean filenames as a UTF-8 Base64 HTTP header instead of a URL query parameter to avoid `HttpListener` query-string decoding corruption.
- Web admin image deletion removes the physical image file and automatically removes matching slide references from `policy.json`.
- Server static file service limits concurrent image downloads to 5; policy JSON requests are not throttled.
- Treat queue status as an operational live queue, not a peak chart. Show current downloading IPs, current waiting IPs, and recent completed request history with PC/user details.
- Log employee-facing policy and image GET requests to `logs/client-download.log`; super admins can inspect the last 200 records from the web UI.
- Add `X-Safety-Wallpaper-Agent`, `X-Safety-Wallpaper-Computer`, and `X-Safety-Wallpaper-User` to employee agent HTTP requests to distinguish and identify agent traffic.
- Uploaded image requests return the saved `images/...` URL so the web page can select the actual stored file.
- Store admin passwords as PBKDF2 hashes only; do not store the initial password as plaintext in the repo.

## Pending
- Whether production startup registration should use HKCU Run, HKLM Run, or Task Scheduler under NAC.
- Whether to build a compiled `.exe` wrapper later.
- Exact Windows version support target.
