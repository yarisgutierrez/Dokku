#!/bin/sh
# Builds a .deb of Dokku from this source tree.
#
#   packaging/build-deb.sh [output-dir]      (default: dist/)
#
# Needs the build dependencies from the README, plus dpkg-dev for dpkg-shlibdeps.
# The library dependencies in the package are worked out from the built binary, so
# they match the system it was built on: build on the oldest release you support.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-"$ROOT/dist"}
WORK="$ROOT/build-deb"

VERSION=$(sed -n "s/^ *version: *'\([0-9][0-9.]*\)'.*/\1/p" "$ROOT/meson.build" | head -n 1)
[ -n "$VERSION" ] || { echo "could not read the version from meson.build" >&2; exit 1; }
ARCH=$(dpkg --print-architecture)
PKG="dokku_${VERSION}_${ARCH}"

rm -rf "$WORK"
meson setup "$WORK/build" "$ROOT" --prefix=/usr --sysconfdir=/etc --buildtype=minsize >/dev/null
ninja -C "$WORK/build" >/dev/null
DESTDIR="$WORK/root" meson install -C "$WORK/build" --no-rebuild --strip >/dev/null

# Documentation the packaging rules ask for: compressed man page, copyright, changelog
DOC="$WORK/root/usr/share/doc/dokku"
mkdir -p "$DOC"
gzip -9n "$WORK/root/usr/share/man/man1/dokku.1"
gzip -9n -c "$ROOT/CHANGELOG.md" > "$DOC/changelog.gz"
cat > "$DOC/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Dokku
Source: https://github.com/yarisgutierrez/Dokku

Files: *
Copyright: Yaris Gutierrez
License: GPL-3
 This program is free software: you can redistribute it and/or modify it under
 the terms of the GNU General Public License version 3 as published by the Free
 Software Foundation.
 .
 On Debian systems, the full text of the GNU General Public License version 3
 can be found in /usr/share/common-licenses/GPL-3.
COPYRIGHT
chmod 644 "$DOC/copyright" "$DOC/changelog.gz"

# Library dependencies, from what the binary links against. dpkg-shlibdeps wants a
# debian/control in the current directory, so give it a throwaway one.
mkdir -p "$WORK/shlibs/debian"
printf 'Source: dokku\n\nPackage: dokku\nArchitecture: any\n' > "$WORK/shlibs/debian/control"
DEPENDS=$(cd "$WORK/shlibs" && dpkg-shlibdeps -O -e"$WORK/root/usr/bin/dokku" 2>/dev/null \
          | sed -n 's/^shlibs:Depends=//p')

SIZE=$(du -sk "$WORK/root" | cut -f1)
mkdir -p "$WORK/root/DEBIAN"
cat > "$WORK/root/DEBIAN/control" <<CONTROL
Package: dokku
Version: $VERSION
Architecture: $ARCH
Maintainer: Yaris Gutierrez <2343927+yarisgutierrez@users.noreply.github.com>
Installed-Size: $SIZE
Depends: $DEPENDS
Recommends: gvfs-backends
Suggests: picom
Section: x11
Priority: optional
Homepage: https://github.com/yarisgutierrez/Dokku
Description: dock and app launcher for Linux
 Dokku is a macOS-style dock with magnification, running-app indicators,
 folders, window previews, a media widget and a full-screen app launcher
 with search. It works on X11 and, with a compositor that offers
 wlr-layer-shell, on Wayland.
CONTROL

# The postinst refreshes the icon cache
cat > "$WORK/root/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = configure ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
POSTINST
chmod 755 "$WORK/root/DEBIAN/postinst"

mkdir -p "$OUT"
dpkg-deb --build --root-owner-group "$WORK/root" "$OUT/$PKG.deb" >/dev/null
echo "$OUT/$PKG.deb"
