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
- Manage server `policy.json` and uploaded images through the web administrator page served by the same server.
- Treat `/safety-wallpaper/admin` as the primary administrator UI for safety staff.
- Require web admin login before policy/image management API calls.
- Keep `policy.json` and image files publicly readable inside the internal network so employee agents can keep polling/downloading without credentials.
- Keep seeded admin users in `admin-users.sample.json`; copy to ignored `admin-users.json` on first server start so changed passwords survive Git updates.
- Password reset does not reveal the old password; it generates a temporary password, stores only its hash, emails it, and sets `mustChangePassword=true`.
- If SMTP settings are missing or sending fails, password reset does not leave a new unknown password active; send failure rolls back the previous hash.
- Keep SMTP credentials out of Git by using ignored `server-policy-sample/mail-settings.json`.
- Use a campaign-wide schedule for the first version.
- Keep `avoidTaskbar` enabled by default and render active slides into the primary screen working area before applying them.
- `StartSafetyWallpaperSlideshow.bat` registers a current-user startup entry and launches the agent through hidden VBS.
- Employee startup launches both the hidden wallpaper agent and a tray controller.
- Tray `정책 새로고침` writes `.runtime/refresh.signal`; the agent detects it and syncs policy immediately.
- Server static file service limits concurrent image downloads to 5; policy JSON requests are not throttled.
- Uploaded image requests return the saved `images/...` URL so the web page can select the actual stored file.
- Store admin passwords as PBKDF2 hashes only; do not store the initial password as plaintext in the repo.

## Pending
- Whether production startup registration should use HKCU Run, HKLM Run, or Task Scheduler under NAC.
- Whether to build a compiled `.exe` wrapper later.
- Exact Windows version support target.
