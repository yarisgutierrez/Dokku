# Dokku

A macOS/GNOME-style dock and full-screen app launcher for XFCE4, running on both X11 and
Wayland. Written in Vala (GTK3, Cairo).

![Dokku](screenshots/1.png)

## Features

- **Dock** with magnification, running-app indicators, and Cairo-drawn themes
- **Positioning** on any screen edge (bottom, top, left, right), with multi-monitor support
- **Visibility:** auto-hide, and "dodge windows" (hide when windows overlap; X11)
- **Drag and drop:** reorder icons, or drag a pinned app off the dock to unpin it
- **Folders:** group pinned apps into dock folders
- **Window previews** on hover for apps with several windows (X11)
- **Notification badges, progress bars and launch/attention bounce**
- **Recent files** in the right-click menu
- **Media widget** (MPRIS2) with album art
- **Frosted glass** blur via a compositor such as picom (X11)
- **Launcher:** full-screen app grid with search and keyboard navigation
- **Plugins:** built-in Trash, Show Desktop and Separator, plus user scripts
- **Global hotkeys** through keybinder (X11; on Wayland bind a key in your compositor)

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
./build/src/dokku      # run without installing
```

## Install

```sh
meson setup build --prefix=/usr
ninja -C build
sudo ninja -C build install
```

This installs the `dokku` binary, the desktop entry, the app icon, the man page
and an autostart entry.

**Choosing a prefix:** use `--prefix=/usr` if you want Dokku to start
automatically at login. The autostart entry is installed under
`<prefix>/etc/xdg/autostart`, and desktop environments read autostart entries
from `/etc/xdg/autostart` (and the other `XDG_CONFIG_DIRS`). With the default prefix (`/usr/local`) the entry is
installed where nothing looks for it. In that case copy it by hand instead:

```sh
mkdir -p ~/.config/autostart
cp data/dokku-autostart.desktop ~/.config/autostart/
```

You may need to refresh the icon cache to see the app icon in menus:

```sh
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor
```

### Start, restart and autostart

Dokku starts from your application menu, from `dokku` in a terminal, or at login
if autostart is set up. It is a single-instance application: running `dokku`
again while it's running only forwards the request to the running copy. To
restart it, for example after reinstalling:

```sh
pkill dokku; dokku &
```

To turn autostart off for your user without uninstalling, copy the autostart
file to `~/.config/autostart/` and change `Hidden=false` to `Hidden=true` in it.

### Update

Pull the new source, then rebuild and reinstall with the same commands. Your
settings in `~/.config/dokku/` are kept.

### Uninstall

Meson has no uninstall target, but it records what it installed. From the build
directory you installed from:

```sh
grep -v '^#' build/meson-logs/install-log.txt | while read -r f; do
    [ -f "$f" ] && sudo rm -v "$f"
done
```

Your settings, themes and plugins are left in place. Remove them too if you
want a clean slate:

```sh
rm -r ~/.config/dokku ~/.local/share/dokku
```

## Files

| Path | Purpose |
|------|---------|
| `~/.config/dokku/config.ini` | settings, pinned apps, folders, enabled plugins |
| `~/.local/share/dokku/themes/` | user-installed themes |
| `~/.local/share/dokku/plugins/` | user script plugins |

## X11 and Wayland

Dokku detects the session when it starts; there is no setting to switch. Features
that depend on X11-only libraries are turned off on Wayland, and the Settings
window shows why next to each one.

| Feature | X11 | Wayland |
|---------|-----|---------|
| Dock, magnification, folders, drag and drop, themes | yes | yes (layer-shell) |
| Launcher, Settings | yes | yes |
| Media widget, notification badges (both use D-Bus) | yes | should work, untested |
| Running-app indicators, window previews, attention bounce | yes | not yet |
| Dodge windows, Show Desktop button | yes | not yet |
| Global hotkeys | yes | no: bind a key in your compositor to `dokku --launcher` |
| Frosted glass | yes (picom) | not yet |

Window tracking on Wayland would need the `zwlr_foreign_toplevel_manager_v1`
protocol, which labwc and sway provide. It isn't implemented yet.

**Both sessions are supported.** The dock, its popups and tooltips, folders, drag and
drop, themes, the launcher and Settings work on each. Tested on X11 under XFCE (xfwm4)
and on Wayland under sway and labwc, which is XFCE's Wayland compositor. Multi-monitor
and vertical docks have had less testing on Wayland than on X11.

On Wayland the compositor must support the `wlr-layer-shell` protocol. sway, labwc,
Wayfire, Hyprland and KDE Plasma do. GNOME's Mutter does not, so Dokku can't place
its dock there. The features marked "not yet" in the table need a window tracker
that isn't written, and are turned off on Wayland.

## Usage

```
dokku                # start the dock
dokku --launcher     # open the app launcher
dokku --settings     # open the settings window
dokku --version      # print the version
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
| `data/` | desktop files, man page, icon |

## Troubleshooting

- **No album art in the media widget:** install `gvfs-backends` (see Build).
- **Trash plugin does nothing:** it runs `gio trash`; install `libglib2.0-bin`.
- **The dock doesn't appear on Wayland:** your compositor needs `wlr-layer-shell`
  (see above). GNOME's Mutter doesn't provide it.
- **Frosted glass has no effect:** it needs a compositor with blur support. See
  the compositor notes above.
- **Dock doesn't appear at login:** see the autostart note under Install.
- **Something looks wrong after an upgrade:** restart the dock. A running dock
  keeps using the old binary until it is restarted.

## Contributing

Issues and pull requests are welcome at
<https://github.com/yarisgutierrez/Dokku>.

## License

GPL-3.0, see [LICENSE](LICENSE).
