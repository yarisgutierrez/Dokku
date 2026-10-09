namespace Dokku {
    // Click-to-expand grid of the apps in a dock folder.
    public class FolderPopup : GLib.Object {
        private PopupHost host;
        private AppManager app_manager;
        private ConfigManager config;
        private UsageTracker usage_tracker;

        // An app was launched from the folder `folder_item`.
        public signal void launched(DockItem folder_item);

        public FolderPopup(PopupHost host, AppManager app_manager,
                           ConfigManager config, UsageTracker usage_tracker) {
            this.host = host;
            this.app_manager = app_manager;
            this.config = config;
            this.usage_tracker = usage_tracker;
        }

        public void shutdown() {
            if (popup != null) { popup.destroy(); popup = null; }
        }

        private Gtk.Window? popup = null;

        public void show(DockItem folder_item, int index) {
            if (popup != null) {
                popup.destroy();
                popup = null;
            }

            string[] folder_apps = config.get_folder_apps(folder_item.folder_id);

            popup = PopupHelper.create_window(Gdk.WindowTypeHint.POPUP_MENU, host.popup_parent());

            var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
            vbox.margin = 12;

            var title_label = new Gtk.Label("<b>" + GLib.Markup.escape_text(folder_item.name) + "</b>");
            title_label.use_markup = true;
            title_label.margin_bottom = 8;
            vbox.pack_start(title_label, false, false, 0);

            int cols = 4;
            var grid = new Gtk.Grid();
            grid.row_spacing = 8;
            grid.column_spacing = 8;
            grid.halign = Gtk.Align.CENTER;

            int col = 0;
            int row_n = 0;
            foreach (var app_id in folder_apps) {
                var app = app_manager.get_app(app_id);
                if (app == null) continue;

                var btn_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);

                var icon_img = new Gtk.Image.from_icon_name(app.icon, Gtk.IconSize.DIALOG);
                btn_box.pack_start(icon_img, false, false, 0);

                var name_label = new Gtk.Label(app.name);
                name_label.ellipsize = Pango.EllipsizeMode.END;
                name_label.max_width_chars = 10;
                name_label.set_size_request(64, -1);
                btn_box.pack_start(name_label, false, false, 0);

                var event_box = new Gtk.EventBox();
                event_box.add(btn_box);
                event_box.button_press_event.connect((ev) => {
                    usage_tracker.record_launch(app.id);
                    app.launch();
                    launched(folder_item);
                    if (popup != null) {
                        popup.destroy();
                        popup = null;
                    }
                    return true;
                });

                grid.attach(event_box, col, row_n, 1, 1);
                col++;
                if (col >= cols) { col = 0; row_n++; }
            }

            vbox.pack_start(grid, false, false, 0);

            var theme_ref = host.popup_theme();
            popup.draw.connect((cr) => {
                PopupHelper.draw_background(cr, popup, theme_ref, 12);
                return false;
            });

            popup.add(vbox);
            host.show_popup(popup, index, 4);

            popup.focus_out_event.connect(() => {
                if (popup != null) {
                    popup.destroy();
                    popup = null;
                }
                return false;
            });
        }
    }
}
