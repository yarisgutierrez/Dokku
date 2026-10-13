# Changelog

All notable changes to Dokku are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Per-monitor dock settings.** With more than one monitor, Settings, Behavior, Monitors lists
  each one with its own edge, icon size and auto-hide; "Default" follows the settings for all
  monitors. They are kept in `[Monitor:<make> <model> <size>]` sections of `config.ini`
  (identical monitors are numbered `#1`, `#2` from left to right). Turn on Show on all
  monitors to get a dock on each one.
- **Clock, Battery and Volume widgets.** Three plugins ship with Dokku and start switched off;
  enable them under Settings, Behavior. The clock shows the time with the date as its tooltip,
  the battery shows the charge (and hides itself on a machine without one), and the volume
  widget shows the output level, mutes on click and changes the volume on scroll (PipeWire's
  `wpctl`, or `pactl`).
- **Widget plugins can scroll, explain themselves and hide.** In `plugin.ini`: `scroll_up` and
  `scroll_down` commands, `tooltip_format` for clocks, `hide_when_empty`, and
  `default_enabled`. A script's first line goes on the icon and the lines after it become the
  tooltip. A widget refreshes as soon as its click or scroll command finishes. Plugins that
  ship with Dokku are read from `/usr/share/dokku/plugins`; one of yours with the same id wins.
- **`.deb` packages and CI.** `packaging/build-deb.sh` builds a package, a GitHub Actions
  workflow builds it on every push, and pushing a `v*` tag publishes a release with it.
- **Back up and restore your settings.** Settings, Behavior, Backup has Export (save
  `config.ini` to a file), Import (load one back) and Reset (back to the defaults). Import
  refuses a file that is too large, not settings, or has a value of the wrong kind, and
  changes nothing when it does. Import and Reset keep what they replace as `config.ini.bak`.
- **Launcher quick results.** Typing a calculation such as `2+3*4` or `sqrt(16)+1` shows the
  answer, and Enter (or a click) copies it. Matching recent files appear as rows you can open.
  When nothing in the grid matches, a "Search the web" row opens the words in your browser.
  The address is set under Settings, Behavior, Web search (`[Launcher] web_search_url`, with
  `%s` for the search words); leave it empty to turn the row off. Nothing is sent anywhere
  until you choose the row.
- **Dock icon interactions.** Middle-click an app icon to open a new window. Scroll over an app
  with several windows to switch between them (scroll down for the next, up for the previous).
  Click the icon of the focused app to minimize it; Settings, Behavior, Minimize on click turns
  that off. On the media widget, scroll changes the volume (a short "Volume 60%" label shows
  it) and middle-click plays or pauses.
- **Drop files on an app icon to open them with it.** Dragging a file over an app that takes
  files enlarges its icon; dropping opens the file in that app. Dragging a file over the
  dock no longer opens a pin gap, which is now only for `.desktop` files.
- **The media widget follows the player that is playing.** With several MPRIS players open, a
  player that is playing wins over the fixed priority list, and the widget stays with it until
  another player starts. Pausing does not hand the widget to a different player.
- **Ignored players setting.** Settings, Behavior, Ignored players (or `[Media] blocked_players`
  in `config.ini`) lists the players the media widget skips. It takes effect without a restart.
- **Now-playing popup with a seek bar.** Resting the pointer on the media widget for 0.6 s, or clicking
  its art or text, opens a card with the album art, song, artist, album, the player's logo,
  elapsed and total time, a seek bar you can click or drag, and previous, play/pause and next.
  The card is tinted with the album art's colour, which also colours the seek bar and the
  play button. It follows the
  player live and works on horizontal and vertical docks. The play/pause and skip buttons on
  the widget still work; clicking its art or text opens the popup, or closes it if it is already
  open (it stays closed until the pointer leaves), and no longer toggles playback. The bar is
  left out for streams with no length or players that can't seek.
- **Window tracking on Wayland.** Running-app indicators, the window list for apps with
  several windows, click to focus, Hide and Quit, clearing a notification badge when the app
  is focused, and the Show Desktop button now work on compositors that provide
  `wlr-foreign-toplevel-management` (sway, labwc, Wayfire, Hyprland). Dodge windows works
  there too for maximized and fullscreen windows, per screen. Attention bounce and Force
  Close stay X11-only, since Wayland does not report them. Sway ignores minimize requests,
  so Show Desktop does nothing under sway. Building needs `wayland-scanner`
  (`libwayland-bin`); without it Dokku still builds, with window tracking left out.
- Windows are matched to apps by the desktop file's `StartupWMClass` as well, on X11 and
  Wayland.
- Keyboard navigation in the launcher. Down from the search box moves into the grid, the
  arrow keys move between icons (Right and Left at the edge turn the page), Up from the
  top row returns to search, Enter opens the focused icon, and Page Up/Page Down,
  Home and End turn pages. The focused icon is now clearly highlighted.
- The right-click menu has an Open entry and lists the app's own actions from its
  `.desktop` file (such as New Window or New Private Window). It also opens from the
  keyboard with the Menu key or Shift+F10.

### Changed
- **App menu reworked.** Pin and Unpin now sit in an Options submenu with Properties.
  Hide minimizes the app's windows (sway ignores that), and Quit asks the app to quit
  through its GApplication `quit` action when it has one, or closes all its windows. Force
  Close appears only when Shift is held as the menu opens. "Open New Window" is now "New
  Window". Dock Settings moved to the Applications button's menu (folders keep it).
- Apps are now filed into categories by the desktop's own application menu
  (`/etc/xdg/menus/xfce-applications.menu`, read directly, with no new library) instead of a
  table of Dokku's own. Settings entries stay together even when they also claim another
  category (Volume Control), editors that list "Utility" first land under Development (Zed),
  and the category tabs and folder names follow the menu, so Dokku matches the panel menu.
  Without a menu file, Dokku falls back to its previous table.
- In the launcher's All view, a category with three or more apps is collected into one folder.
  Your ten most-used apps also stay in the grid, outside the folder, and entries the menu
  lists at the top level (Terminal Emulator, File Manager, Web Browser, ...) and uncategorised
  apps are never folded. Searching or choosing a category still shows every app. It is on by
  default and can be turned off under Settings > Launcher > Group apps by category.
- The launcher no longer lists the Xfce "preferred application" wrappers (Mail Reader, Web
  Browser, File Manager, Terminal Emulator) or Log Out and About Xfce. They only duplicate other apps. They are
  still known to Dokku, so a pinned dock icon for one keeps working.
- Search results are ranked by how well they match: an exact name first, then names that
  start with what you typed, then a word within the name, then anywhere in the name, then
  the app id or command. Launch count only breaks ties.

### Fixed
- **A wheel notch counted twice on Wayland.** Wayland delivers each notch as a discrete and a
  smooth scroll event with the same timestamp, so the volume widget moved about twice as far as
  intended. A repeat with the same timestamp is now ignored.
- **`Reload` over D-Bus only reloaded the main dock.** It now does what changing a setting does:
  every dock (one per monitor), the launcher and the hotkeys pick up the new settings.
- **Launcher fade-out stuttered under picom.** The fade repainted the whole fullscreen window
  every frame, which picom's GL backend could not keep up with. On X11 the launcher now fades
  through `_NET_WM_WINDOW_OPACITY` and the compositor does the blending. It is also tagged
  `_DOKKU_WINDOW`, so picom rules for Dokku windows (no shadow) apply to it. With picom
  `fading = true`, add `fade = false;` to the Dokku rule (see the README).
- **Launcher opens faster the first time.** Its widgets are built shortly after startup.
- **`DOKKU_TIMING=1`** logs the launcher's open and fade timings to the terminal, for
  tracking down lag.
- Apps launched from Dokku inherited the directory Dokku was started from, so a file
  manager such as Thunar opened there instead of in your home directory. Dokku now
  switches to your home directory at startup.
- The Applications menu listed apps that are no longer installed, because a leftover
  `.desktop` file was enough. Apps are now discovered through GLib, so an entry whose
  `TryExec` binary is missing is hidden, as are entries marked `Hidden` or limited to
  other desktops with `OnlyShowIn`/`NotShowIn`. A `.desktop` file in
  `~/.local/share/applications` can now hide a system app, and every directory in
  `XDG_DATA_DIRS` (Flatpak exports, for one) is scanned.
- Paging through the launcher was jerky. One touchpad swipe could flip several pages, or
  restart the slide halfway, because its inertia tail kept counting, and a fast mouse
  wheel restarted the slide on every notch. A swipe now flips one page and the rest of
  that gesture is ignored, and wheel notches are spaced out. The page dots are no longer
  rebuilt during the slide.

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
