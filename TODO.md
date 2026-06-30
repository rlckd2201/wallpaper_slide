# TODO

## Requirements To Design
- [x] Choose implementation stack and packaging method for Windows desktop deployment.
- [x] Define image storage location that administrators can update without rebuilding the app.
- [x] Define metadata/config format for posting period, slide order, duration, and fallback behavior.
- [x] Implement slide show renderer for desktop/background display.
- [x] Implement automatic expiration handling that switches to a plain black background.
- [x] Add basic startup behavior through a `.bat` launcher.
- [x] Add logging and failure fallback rules.
- [x] Prevent taskbar from covering the bottom of slide images by rendering taskbar-safe wallpapers.
- [x] Convert user PC runtime into a server-controlled policy/image listener agent.
- [x] Add hidden launcher so the persistent PowerShell window does not stay open.
- [x] Register current-user startup entry when the start batch is executed.
- [x] Add employee tray icon with manual policy refresh action.
- [x] Select non-conflicting server policy port with `tcping`; fixed to `28080`.
- [x] Ensure slides restart from the first image after the final image in the list.
- [x] Add simple server-side batch and PowerShell static server for `172.16.19.35:28080`.
- [x] Add server-side git clone/pull install/update batches.
- [x] Add server-side administrator GUI for image upload, selection, posting period, and slide policy management.
- [x] Limit server image download concurrency to 5 and queue additional image requests.
- Add installer/update strategy and uninstall behavior.
- Add tests or manual verification checklist for image change, date expiry, startup, and black background fallback.

## Open Questions
- Confirm administrator GUI workflow on `172.16.19.35`.
- Server can now clone `https://github.com/rlckd2201/wallpaper_slide.git`.
- Should users be allowed to close/pause the slide show?
- Which Windows versions must be supported?
