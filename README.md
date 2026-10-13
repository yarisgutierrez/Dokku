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
- **Mouse shortcuts:** middle-click opens a new window, scroll switches an app's windows,
  clicking the focused app minimizes it, and dropping a file on an icon opens it there
- **Media widget** (MPRIS2) with album art; rest the pointer on it for a popup with the
  artist, song, album, a seek bar and playback controls. Scroll on it for volume and
  middle-click to play or pause. It follows the player that is playing, and Settings can
  list players to ignore
- **Frosted glass** blur via a compositor such as picom (X11)
- **Launcher:** full-screen app grid with search and keyboard navigation; the search box also
  calculates (`2+3*4`), finds recent files and can search the web
- **Backup:** export, import and reset your settings from the Settings window
- **Plugins:** built-in Trash, Show Desktop and Separator, plus user scripts
- **Global hotkeys** through keybinder (X11; on Wayland bind a key in your compositor)

## Build

Dependencies (Debian/Ubuntu package names):

```sh
sudo apt install valac meson ninja-build libgtk-3-dev libwnck-3-dev \
    libgtk-layer-shell-dev libkeybinder-3.0-dev libx11-dev libwayland-dev libwayland-bin
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

**Debian, Ubuntu and derivatives:** download the `.deb` from the
[releases page](https://github.com/yarisgutierrez/Dokku/releases) and install it with
`sudo apt install ./dokku_*.deb`. It starts at login and pulls in the libraries it needs. It is
built on Ubuntu 24.04, so it needs a system at least as new as that (glibc 2.38; Debian 13 and
Ubuntu 24.04 qualify). On an older system, build from source as below.

**From source:**

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
| `~/.config/dokku/config.ini.bak` | what the last Import or Reset replaced |
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
| Media widget, notification badges (both use D-Bus) | yes | yes (undergoing testing) |
| Running-app indicators, window list, focus and close | yes | yes, if the compositor has `wlr-foreign-toplevel-management` (undergoing testing) |
| Show Desktop button | yes | yes, if the compositor lets clients minimize windows (labwc does; sway does not) (undergoing testing) |
| Dodge windows | when a window overlaps the dock | when a window is maximized or fullscreen on the dock's screen (undergoing testing) |
| Attention bounce, Force Close | yes | no: Wayland tells clients neither urgency nor other windows' PIDs |
| Global hotkeys | yes | no: bind a key in your compositor to `dokku --launcher` |
| Frosted glass | yes (picom) | not yet |

On Wayland, windows are listed through the `wlr-foreign-toplevel-management` protocol,
which sway, labwc, Wayfire and Hyprland provide. Dokku asks for it on a connection of its
own; where the compositor lacks it, the features above are turned off and Settings says
why. Dodge can only react to maximized and fullscreen windows there, because the
protocol does not say where a window is.

**X11 is the well-tested session; Wayland support is undergoing testing.** The dock, its
popups and tooltips, folders, drag and drop, themes, the launcher and Settings work on
both. Wayland has been checked in nested sway and labwc (labwc is XFCE's Wayland
compositor): the media widget, notification badges, vertical and right-hand docks,
several monitors (including plugging one in and out) and window tracking. Testing on
real hardware and in a full XFCE Wayland session is still under way, so expect rough
edges there and please report them.

On Wayland the compositor must support the `wlr-layer-shell` protocol. sway, labwc,
Wayfire, Hyprland and KDE Plasma do. GNOME's Mutter does not, so Dokku can't place
its dock there.

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

- `_DOKKU_WINDOW` on every Dokku window (dock, blur backdrop, launcher, settings):
  use it to disable blur and shadow for Dokku by default.
- `_DOKKU_BLUR` on the capsule-shaped backdrop window only: enable blur for
  windows matching both `_DOKKU_WINDOW` and `_DOKKU_BLUR`.

`_COMPTON_SHADOW` is set to 0 so picom draws no shadow.

**picom and the launcher fade:** on X11 the launcher fades in and out by changing the
window's `_NET_WM_WINDOW_OPACITY`, so the compositor does the blending. If picom has
`fading = true`, it also smooths those changes at its own pace, and the launcher
fades slowly and then pops out. Turn picom's fade off for Dokku windows with a rule:

```
rules: ({
  match = "_DOKKU_WINDOW@";
  shadow = false;
  blur-background = false;
  fade = false;
}, ...)
```

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
