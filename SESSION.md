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
- `StopSafetyWallpaperSlideshow.bat` requests shutdown through `.runtime/stop.signal`.
- `TestSafetyWallpaperSlideshow.bat` runs one dry-run cycle without changing the real wallpaper.
- `SafetyWallpaperSlideshow.ps1` reads local bootstrap settings from `config.json`, checks `http://172.16.19.35:28080/safety-wallpaper/policy.json` by default, caches server images, and falls back to a generated black wallpaper.
- Active slide images are rendered into `.runtime/rendered` before wallpaper application so the full source image stays inside the Windows working area above the taskbar.
- Slide order now cycles through every available slide and then restarts from the first slide; shuffle mode reshuffles only after a full cycle.
- Sample slide images and the unused local `images` folder were removed; real user-provided safety images are used instead.
- Runtime logs are written to `logs/wallpaper-slideshow.log`.
- `graphify` is installed and available.
- Server-side git install/update batches are available under `server-policy-sample`.

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
- The hidden background agent was restarted after the slide cycle update.
- Local workspace was initialized as a git repository and pushed to `https://github.com/rlckd2201/wallpaper_slide.git` on branch `main`.
