#!/bin/sh
# Builds Dokku and installs it.
#
#   ./install.sh                  install for your user, under ~/.local
#   ./install.sh --global         install for everyone, under /usr/local (uses sudo)
#   ./install.sh --prefix DIR     install under DIR
#
# Needs the build dependencies listed in the README. Set BUILD_DIR to build somewhere
# other than ./build.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD=${BUILD_DIR:-"$ROOT/build"}
PREFIX=

while [ $# -gt 0 ]; do
    case $1 in
        --global) PREFIX=/usr/local ;;
        --prefix) [ $# -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 1; }
                  PREFIX=$2; shift ;;
        --prefix=*) PREFIX=${1#--prefix=} ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [ -z "$PREFIX" ]; then
    if [ "$(id -u)" -eq 0 ]; then PREFIX=/usr/local; else PREFIX=$HOME/.local; fi
fi

for tool in meson ninja valac; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is not installed. See the build dependencies in the README." >&2
        exit 1
    }
done

if [ -d "$BUILD/meson-private" ]; then
    meson configure "$BUILD" --prefix="$PREFIX" >/dev/null
else
    meson setup "$BUILD" "$ROOT" --prefix="$PREFIX"
fi
ninja -C "$BUILD"

# Use sudo only when the prefix isn't writable by the current user
SUDO=
if ! { mkdir -p "$PREFIX" 2>/dev/null && [ -w "$PREFIX" ]; }; then
    SUDO=sudo
fi
$SUDO meson install -C "$BUILD" --no-rebuild

# Refresh the icon and menu caches when the tools are there. These are best effort.
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    $SUDO gtk-update-icon-cache -q -t -f "$PREFIX/share/icons/hicolor" 2>/dev/null || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    $SUDO update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true
fi

echo
echo "Dokku is installed in $PREFIX."
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) echo "Note: $PREFIX/bin is not on your PATH. Launch Dokku from the Applications menu," \
            "or run $PREFIX/bin/dokku." ;;
esac
