namespace Dokku {
    // The one way Dokku turns an icon into pixels. A .desktop file's Icon= key is either
    // a theme icon name ("firefox") or an absolute path to an image file
    // ("/opt/firefox/.../default128.png"); GTK's named-icon APIs only understand the
    // first, so every caller goes through here instead of handling paths itself.
    public class IconLoader : GLib.Object {
        public const string FALLBACK = "application-x-executable";

        // Pixbuf for `icon_name` at `size`, or the fallback icon if it can't be loaded.
        // Null only if even the fallback is missing from the theme.
        public static Gdk.Pixbuf? load(string? icon_name, int size) {
            string name = (icon_name == null || icon_name == "") ? FALLBACK : icon_name;

            if (name.has_prefix("/")) {
                try {
                    return new Gdk.Pixbuf.from_file_at_size(name, size, size);
                } catch (Error e) {
                    // not a readable image: fall through to the fallback icon
                }
            } else {
                try {
                    return Gtk.IconTheme.get_default().load_icon(name, size, Gtk.IconLookupFlags.FORCE_SIZE);
                } catch (Error e) {
                    // unknown to the theme: fall through to the fallback icon
                }
            }

            try {
                return Gtk.IconTheme.get_default().load_icon(FALLBACK, size, Gtk.IconLookupFlags.FORCE_SIZE);
            } catch (Error e) {
                return null;
            }
        }

        // Point `image` at `icon_name`. Theme icons keep GTK's own (HiDPI-aware) rendering;
        // only file paths, which GTK can't render by name, are loaded as pixbufs.
        public static void apply(Gtk.Image image, string? icon_name, Gtk.IconSize size) {
            if (icon_name != null && icon_name.has_prefix("/")) {
                int px = 48;
                Gtk.icon_size_lookup(size, out px, null);
                var pixbuf = load(icon_name, px);
                if (pixbuf != null) {
                    image.set_from_pixbuf(pixbuf);
                    return;
                }
            }
            image.set_from_icon_name((icon_name == null || icon_name == "" || icon_name.has_prefix("/"))
                                         ? FALLBACK : icon_name, size);
        }

        public static Gtk.Image image(string? icon_name, Gtk.IconSize size) {
            var img = new Gtk.Image();
            apply(img, icon_name, size);
            return img;
        }
    }
}
