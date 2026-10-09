# Changelog

All notable changes to Dokku are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.1] - 2026-10-09

### Fixed
- `dokku --launcher` and `dokku --settings` did nothing when a dock was already running,
  which is the normal case. The options were read in the process you typed the command
  in, not in the running dock. This also affects binding a compositor key to
  `dokku --launcher`, which is how to open the launcher on Wayland.
- Every settings change, pin, D-Bus property write or change to the installed apps added
  another handler to the media, trash and script plugins and never removed it, so after
  N reloads a single track change ran N+1 handlers.
- Apps whose `.desktop` file gives an absolute icon path (a tarball Firefox, vendor tools)
  showed a fallback or broken icon in the launcher, the folder popup, the window list and
  the drag-to-remove icon. Icons now load through one shared loader.
- Apps now launch through GLib, so `Terminal=true` apps open in a terminal, `Path=` is
  honoured, D-Bus activation works, `Exec` field codes follow the specification, and the new
  window is focused correctly on Wayland. Before, a terminal app ran with no terminal.
- Apps whose `.desktop` file has no `Icon=` (or no `Name=`) silently disappeared from the
  launcher and could not be launched. They now appear with a generic icon (or their file
  name).
- A monitor plugged in while Dokku is running now gets a dock, and one that is unplugged
  loses it. Docks were only synchronised at startup and when a setting changed.

### Changed
- Less repeated work per frame: the dock skips re-sending an unchanged input shape, and the
  indeterminate-progress animation is frame-synced like the others.
- libwnck's screen is requested in one place, and about 115 lines of unused code and two
  unused data files were removed.
- `gio-unix-2.0` is now listed as a dependency. It ships in `libgio-2.0-dev` with `gio-2.0`,
  so nothing new is needed to build.

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

[Unreleased]: https://github.com/yarisgutierrez/Dokku/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/yarisgutierrez/Dokku/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/yarisgutierrez/Dokku/releases/tag/v0.2.0
