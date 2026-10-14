namespace Dokku {
    // An entry for an icon name or image path, with a live preview and a button that
    // browses for an image file
    public class IconPicker : Gtk.Box {
        public Gtk.Entry entry { get; private set; }
        public Gtk.Button browse_button { get; private set; }
        private Gtk.Image preview;
        private string fallback_icon;
        private Gtk.Window parent_window;

        public string text {
            owned get { return entry.text.strip(); }
            set { entry.text = value; }
        }

        public IconPicker(Gtk.Window parent_window, string fallback_icon, string initial = "",
                          string placeholder = "") {
            Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: 8);
            this.parent_window = parent_window;
            this.fallback_icon = fallback_icon;

            entry = new Gtk.Entry();
            entry.placeholder_text = placeholder;
            entry.hexpand = true;
            entry.activates_default = true;
            pack_start(entry, true, true, 0);

            browse_button = new Gtk.Button.from_icon_name("document-open-symbolic", Gtk.IconSize.BUTTON);
            browse_button.tooltip_text = "Browse for icon";
            browse_button.clicked.connect(browse);
            pack_start(browse_button, false, false, 0);

            preview = new Gtk.Image.from_icon_name(fallback_icon, Gtk.IconSize.LARGE_TOOLBAR);
            pack_start(preview, false, false, 0);

            entry.changed.connect(update_preview);
            if (initial != "") entry.text = initial;
        }

        // Handles both theme names and image paths
        private void update_preview() {
            string name = text == "" ? fallback_icon : text;
            if (name.has_prefix("/") && FileUtils.test(name, FileTest.EXISTS)) {
                try {
                    preview.set_from_pixbuf(new Gdk.Pixbuf.from_file_at_size(name, 24, 24));
                    return;
                } catch (Error e) {}
            }
            preview.set_from_icon_name(name, Gtk.IconSize.LARGE_TOOLBAR);
        }

        public void browse() {
            var chooser = new Gtk.FileChooserDialog("Choose Icon", parent_window,
                Gtk.FileChooserAction.OPEN,
                "_Cancel", Gtk.ResponseType.CANCEL,
                "_Open", Gtk.ResponseType.ACCEPT);

            var images = new Gtk.FileFilter();
            images.set_filter_name("Image files");
            foreach (var pattern in new string[] { "*.png", "*.svg", "*.xpm", "*.ico" }) {
                images.add_pattern(pattern);
            }
            chooser.add_filter(images);

            var everything = new Gtk.FileFilter();
            everything.set_filter_name("All files");
            everything.add_pattern("*");
            chooser.add_filter(everything);

            chooser.set_current_folder("/usr/share/icons");

            var chosen_preview = new Gtk.Image();
            chosen_preview.set_size_request(64, 64);
            chooser.set_preview_widget(chosen_preview);
            chooser.update_preview.connect(() => {
                string? path = chooser.get_preview_filename();
                if (path == null) return;
                try {
                    chosen_preview.set_from_pixbuf(new Gdk.Pixbuf.from_file_at_size(path, 64, 64));
                    chooser.set_preview_widget_active(true);
                } catch (Error e) {
                    chooser.set_preview_widget_active(false);
                }
            });

            if (chooser.run() == Gtk.ResponseType.ACCEPT) {
                entry.text = chooser.get_filename();
            }
            chooser.destroy();
        }
    }
}
