# Changelog

All notable changes to Dokku are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-10-09

### Added
- **Wayland support.** Dokku now runs on Wayland compositors that provide
  `wlr-layer-shell` (tested on sway and labwc), as well as on X11. The session is
  detected at startup. Tooltips, the folder popup and menus are anchored to the dock.
  Features that need X11-only libraries (window tracking, global hotkeys, compositor
  blur, dodge windows, Show Desktop) are turned off on Wayland, and the Settings
  window says why. See the README for the full table.
- **Folder popup closes on any outside click**, on Escape, or when the folder is
  clicked again, on both X11 and Wayland.
- **Application icon**, installed into the hicolor theme and used for Dokku's windows.
  The desktop entries already referred to an icon that didn't exist.
- `dokku --version` (and `-v`). The version now comes from a single place in
  `meson.build`; the Settings "About" page and the man page are generated from it.
- README with build, install, autostart, update, uninstall and troubleshooting notes,
  and a `CHANGELOG`.

### Changed
- `dock-window.vala` was split (3,363 to about 2,100 lines). The properties dialog,
  recent-files menu, hover tooltip and window list, media popup, folder popup,
  drag-to-remove floating icon, blur backdrop and compositor hints now live in their
  own files.
- The Properties dialog: **Reset Icon** is always visible (enabled while a custom icon
  is set) and updates immediately, **Close** sits on the left of the button row, and the
  dialog opens centred on the monitor instead of on the dock.
- The folder popup's text colour follows the theme, so it is readable on dark and light
  themes.
- Failures to load album art are now logged. They were silently ignored.

### Fixed
- Themes missing a section (such as `[Border]` or `[Style]`) lost their name and every
  later value. Each value is now read independently.
- The dock's rounded corners and border were clipped while dragging an icon to reorder,
  because the window had no room for the gap that opens. This showed up when
  magnification was off.
- The dock window was sized before its dimensions were known. X11 corrected it later,
  but on Wayland it produced a 1-pixel-tall dock.
- The dock never drew on Wayland (an empty GTK3 layer-shell window needs an explicit
  size request).
- Popups on Wayland appeared in the middle of the screen instead of beside the dock.
- A tooltip could stay on screen underneath an open folder popup.
- Icon cache entries were cleared for the wrong icon when applying or resetting a
  custom icon.
- The show-desktop plugin could crash where there is no X11 screen.
- The dock background was needlessly transparent when frosted glass was on but its
  backdrop could not be created.
- The unavailable-hotkey error notification appeared on every launch on Wayland.

### Removed
- Leftover software-blur and wallpaper-monitor sources that were no longer built or
  used.
- Debug lines printed at startup.

[0.2.0]: https://github.com/yarisgutierrez/Dokku/releases/tag/v0.2.0
