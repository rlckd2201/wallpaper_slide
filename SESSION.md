# Session Notes

## 2026-06-30

### Project Overview
- Purpose: show company safety-related educational/promotional materials on employee desktops.
- Distribution: deploy and install the program to all users through NAC deployment.
- Runtime behavior: display desktop images as a slide show.
- Image management: administrators must be able to replace/update images at any time.
- Posting period: when the configured posting period has passed, the desktop should return to a plain black background.

### Current Workspace State
- Initial source files were added.
- `StartSafetyWallpaperSlideshow.bat` registers current-user startup and launches the hidden wallpaper slideshow process through `RunSafetyWallpaperSlideshowHidden.vbs`.
- `RunSafetyWallpaperSlideshowHidden.vbs` launches both `SafetyWallpaperSlideshow.ps1` and `SafetyWallpaperTray.ps1`.
- `SafetyWallpaperTray.ps1` shows the employee tray icon and writes `.runtime/refresh.signal` when the user clicks policy refresh.
- `StopSafetyWallpaperSlideshow.bat` requests shutdown through `.runtime/stop.signal`.
- `TestSafetyWallpaperSlideshow.bat` runs one dry-run cycle without changing the real wallpaper.
- `SafetyWallpaperSlideshow.ps1` reads local bootstrap settings from `config.json`, checks `http://172.16.19.35:28080/safety-wallpaper/policy.json` by default, caches server images, and falls back to a generated black wallpaper.
- Active slide images are rendered into `.runtime/rendered` before wallpaper application so the full source image stays inside the Windows working area above the taskbar.
- Slide order now cycles through every available slide and then restarts from the first slide; shuffle mode reshuffles only after a full cycle.
- Sample slide images and the unused local `images` folder were removed; real user-provided safety images are used instead.
- Runtime logs are written to `logs/wallpaper-slideshow.log`.
- `graphify` is installed and available.
- Server-side git install/update batches are available under `server-policy-sample`.
- Server-side administrator web page is available at `http://172.16.19.35:28080/safety-wallpaper/admin`.
- The web administrator page is the primary admin UI; the older WinForms admin script remains in the repo but is no longer the requested workflow.
- Environment/safety team admin login is now required for web admin API actions.
- Admin seed users live in `server-policy-sample/admin-users.sample.json`; server first run copies this to ignored `admin-users.json`.
- Admin users now have roles: environment/safety team accounts are `operator`, the 6 added internal accounts are `super`.
- On server start, seed users missing from existing ignored `admin-users.json` are merged without overwriting existing password hashes.
- Super admins can access work history, access history, deployment status, queue status, and admin account create/update/delete.
- Admin passwords are stored as PBKDF2 hashes, and all seeded users must change the initial password on first login.
- Admin forgot-password flow issues a new temporary password, stores only its PBKDF2 hash, sends the temporary password to the registered email, and forces password change after login.
- SMTP settings are read from ignored `server-policy-sample/mail-settings.json`; `mail-settings.sample.json` is only a template.
- Admin uploads return the saved image URL, and the web page automatically selects newly uploaded images.
- Server static file service allows up to 5 concurrent image downloads and queues additional image requests.

### Next Session Start Checklist
- Read `SESSION.md`, `TODO.md`, `DECISIONS.md`, and `DEBUG.md`.
- Check `graphify-out/graph.json` if present.
- Use `graphify query` or `graphify explain` before opening broad source files once code exists.
- Open only files directly related to the current change.

### Implementation Notes
- This version changes the actual Windows wallpaper for the current user with `SystemParametersInfo`.
- The current running instance was restarted after adding taskbar-safe rendering.
- It does not show an installer UI.
- It can be distributed as a folder and started by running the start `.bat`.
- User PCs are now intended to operate as policy/image listener agents controlled by the central server.
- Employee PCs have a tray icon for status, log opening, policy URL opening, and manual policy refresh.
- Tray menu text is generated from Unicode code points in `SafetyWallpaperTray.ps1` so Windows PowerShell 5.1 cannot corrupt Korean menu labels when reading UTF-8 files without BOM.
- Admin image uploads now send the original browser filename through `X-File-Name-Base64`, and the server decodes it as UTF-8 before saving. This prevents Korean upload filenames from being corrupted on future uploads.
- Existing images already saved with corrupted names must be deleted/reuploaded or manually renamed on the server because the original filename is no longer recoverable from the corrupted saved filename.
- Administrators manage uploads, selected images, posting period, and slide policy through the web page.
- Server `StartSafetyWallpaperServer.bat` prints both the admin page URL and policy URL.
- The hidden background agent was restarted after the slide cycle update.
- Local workspace was initialized as a git repository and pushed to `https://github.com/rlckd2201/wallpaper_slide.git` on branch `main`.
