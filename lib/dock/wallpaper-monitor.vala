namespace Dokku {
    /**
     * Detects the current desktop wallpaper and monitors for changes.
     * The loaded pixbuf is always scaled to screen resolution so that
     * screen-pixel coordinates can be used directly for cropping.
     *
     * Detection priority:
     *   1) X11 root window capture (always screen-res, always correct)
     *   2) xfconf D-Bus (XFCE — file path, scaled to screen)
     *   3) GSettings (GNOME — file path, scaled to screen)
     */
    public class WallpaperMonitor : Object {
        private string? current_path = null;
        private Gdk.Pixbuf? wallpaper_pixbuf = null;
        private Gdk.Pixbuf? blurred_cache = null;
        private int cached_blur_radius = 0;
        private int screen_width = 0;
        private int screen_height = 0;
        private DBusConnection? xfconf_bus = null;
        private uint xfconf_signal_id = 0;
        private Settings? bg_settings = null;

        public signal void wallpaper_changed();

        public WallpaperMonitor() {
            // Cache screen dimensions for scaling
            var screen = Gdk.Screen.get_default();
            if (screen != null) {
                screen_width = screen.get_width();
                screen_height = screen.get_height();
            }
            detect_wallpaper();
            setup_monitors();
        }

        ~WallpaperMonitor() {
            if (xfconf_bus != null && xfconf_signal_id != 0) {
                xfconf_bus.signal_unsubscribe(xfconf_signal_id);
            }
        }

        /**
         * Get the blurred wallpaper pixbuf for the given radius.
         * Returns cached version if radius hasn't changed.
         */
        public Gdk.Pixbuf? get_blurred(int radius) {
            if (wallpaper_pixbuf == null) return null;
            if (blurred_cache != null && cached_blur_radius == radius) {
                return blurred_cache;
            }
            blurred_cache = BlurUtil.blur_pixbuf(wallpaper_pixbuf, radius);
            cached_blur_radius = radius;
            return blurred_cache;
        }

        public Gdk.Pixbuf? get_pixbuf() {
            return wallpaper_pixbuf;
        }

        public void refresh() {
            blurred_cache = null;
            cached_blur_radius = 0;
            detect_wallpaper();
        }

        // ---- Detection (root pixmap first, then file-based fallbacks) ----

        private void detect_wallpaper() {
            // 1) X11 root window capture — always screen-resolution
            if (load_from_root_pixmap()) return;

            // 2) xfconf (XFCE) — file path, scale to screen
            string? path = detect_xfconf();
            if (path != null && load_wallpaper_file(path)) return;

            // 3) GSettings (GNOME/Cinnamon) — file path, scale to screen
            path = detect_gsettings();
            if (path != null && load_wallpaper_file(path)) return;

            warning("WallpaperMonitor: could not detect wallpaper from any source");
        }

        private bool load_from_root_pixmap() {
            var screen = Gdk.Screen.get_default();
            if (screen == null) return false;

            var root = screen.get_root_window();
            if (root == null) return false;

            int w = screen.get_width();
            int h = screen.get_height();
            if (w <= 0 || h <= 0) return false;

            var pixbuf = Gdk.pixbuf_get_from_window(root, 0, 0, w, h);
            if (pixbuf == null) {
                warning("WallpaperMonitor: root pixmap capture returned null");
                return false;
            }

            wallpaper_pixbuf = pixbuf;
            current_path = "__root_pixmap__";
            blurred_cache = null;
            cached_blur_radius = 0;
            return true;
        }

        private bool load_wallpaper_file(string path) {
            if (!FileUtils.test(path, FileTest.EXISTS)) {
                warning("WallpaperMonitor: file does not exist: %s", path);
                return false;
            }

            try {
                var raw = new Gdk.Pixbuf.from_file(path);

                // Scale to screen resolution so coordinates match screen pixels
                if (screen_width > 0 && screen_height > 0 &&
                    (raw.get_width() != screen_width || raw.get_height() != screen_height)) {
                    wallpaper_pixbuf = raw.scale_simple(
                        screen_width, screen_height, Gdk.InterpType.BILINEAR);
                } else {
                    wallpaper_pixbuf = raw;
                }

                current_path = path;
                blurred_cache = null;
                cached_blur_radius = 0;
                return true;
            } catch (Error e) {
                warning("WallpaperMonitor: failed to load %s: %s", path, e.message);
                return false;
            }
        }

        // ---- xfconf detection ----

        private string? detect_xfconf() {
            // Scan all backdrop properties for any monitor's last-image
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                var reply = bus.call_sync(
                    "org.xfce.Xfconf",
                    "/org/xfce/Xfconf",
                    "org.xfce.Xfconf",
                    "GetAllProperties",
                    new Variant("(ss)", "xfce4-desktop", "/backdrop"),
                    new VariantType("(a{sv})"),
                    DBusCallFlags.NONE,
                    2000,
                    null
                );

                Variant dict;
                reply.get("(@a{sv})", out dict);
                var iter = dict.iterator();
                string key;
                Variant value;
                while (iter.next("{sv}", out key, out value)) {
                    if (key.has_suffix("/last-image") && value.is_of_type(VariantType.STRING)) {
                        string path = value.get_string();
                        if (path != "" && FileUtils.test(path, FileTest.EXISTS)) {
                            return path;
                        }
                    }
                }
            } catch (Error e) {
                // xfconf not available or channel doesn't exist
            }
            return null;
        }

        // ---- GSettings detection ----

        private string? detect_gsettings() {
            var source = SettingsSchemaSource.get_default();
            if (source == null) return null;
            var schema = source.lookup("org.gnome.desktop.background", true);
            if (schema == null) return null;

            var settings = new Settings("org.gnome.desktop.background");
            string uri = settings.get_string("picture-uri");
            if (uri != null && uri.has_prefix("file://")) {
                return uri.substring(7);
            }
            return uri;
        }

        // ---- Change monitors ----

        private void setup_monitors() {
            // xfconf property changes
            try {
                xfconf_bus = Bus.get_sync(BusType.SESSION);
                xfconf_signal_id = xfconf_bus.signal_subscribe(
                    "org.xfce.Xfconf",
                    "org.xfce.Xfconf",
                    "PropertyChanged",
                    "/org/xfce/Xfconf",
                    null,
                    DBusSignalFlags.NONE,
                    on_xfconf_changed
                );
            } catch (Error e) {
                // xfconf not available
            }

            // GSettings changes
            var source = SettingsSchemaSource.get_default();
            if (source != null) {
                var schema = source.lookup("org.gnome.desktop.background", true);
                if (schema != null) {
                    bg_settings = new Settings("org.gnome.desktop.background");
                    bg_settings.changed["picture-uri"].connect(() => {
                        Idle.add(() => {
                            refresh();
                            wallpaper_changed();
                            return false;
                        });
                    });
                }
            }
        }

        private void on_xfconf_changed(DBusConnection conn, string? sender,
                                         string object_path, string interface_name,
                                         string signal_name, Variant parameters) {
            string channel, property;
            Variant val;
            parameters.get("(ssv)", out channel, out property, out val);

            if (channel == "xfce4-desktop" && property.has_suffix("/last-image")) {
                Idle.add(() => {
                    refresh();
                    wallpaper_changed();
                    return false;
                });
            }
        }
    }
}
