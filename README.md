# Dokku

A macOS/GNOME-style dock and full-screen app launcher for XFCE4, written in Vala (GTK3, Cairo).

![Dokku](screenshots/1.png)

## Features

- **Dock** with magnification, running-app indicators, and Cairo-drawn themes
- **Positioning** on any screen edge (bottom, top, left, right), with multi-monitor support
- **Visibility:** auto-hide and "dodge windows" (hide when windows overlap)
- **Drag and drop:** reorder icons, or drag a pinned app off the dock to unpin it
- **Folders:** group pinned apps into dock folders
- **Window previews** on hover for apps with several windows
- **Notification badges, progress bars and launch/attention bounce**
- **Recent files** in the right-click menu
- **Media widget** (MPRIS2) with album art
- **Frosted glass** blur via a compositor such as picom
- **Launcher:** full-screen app grid with search and keyboard navigation
- **Plugins:** built-in Trash, Show Desktop and Separator, plus user scripts
- **Global hotkeys** through keybinder

## Build

Dependencies (Debian/Ubuntu package names):

```sh
sudo apt install valac meson ninja-build libgtk-3-dev libwnck-3-dev \
    libgtk-layer-shell-dev libkeybinder-3.0-dev libx11-dev
# optional: libatspi2.0-dev
```

**Runtime:** `gvfs-backends` is needed for album art in the media widget. Players such as
Spotify publish `https://` art URLs, and GIO fetches them through the GVfs HTTP daemon.

```sh
meson setup build
ninja -C build
./build/src/dokku
```

Install system-wide with `sudo ninja -C build install`.

## Usage

```
dokku                # start the dock
dokku --launcher     # open the app launcher
dokku --settings     # open the settings window
```

Configuration lives in `~/.config/dokku/`. See `man dokku` for the config
format, theme format and file locations. User themes go in
`~/.local/share/dokku/themes/`.

## Compositor notes

Frosted glass needs a compositor with blur support. Dokku sets these X11
properties so compositor rules can target its windows:

- `_DOKKU_WINDOW` on every Dokku window (dock, blur backdrop, settings): use it
  to disable blur and shadow for Dokku by default.
- `_DOKKU_BLUR` on the capsule-shaped backdrop window only: enable blur for
  windows matching both `_DOKKU_WINDOW` and `_DOKKU_BLUR`.

`_COMPTON_SHADOW` is set to 0 so picom draws no shadow.

## Project layout

| Path | Contents |
|------|----------|
| `src/main.vala` | entry point |
| `lib/core/` | application, D-Bus service |
| `lib/dock/` | dock window, renderer, app/window/config managers, monitors |
| `lib/launcher/` | full-screen launcher, usage tracking |
| `lib/settings/` | settings window |
| `lib/plugins/` | plugin interface and built-in plugins |
| `lib/themes/` | theme loading |
| `lib/hotkeys/` | hotkey manager |
| `data/` | desktop files, man page, icons, default theme |

## License

GPL-3.0, see [LICENSE](LICENSE).
