namespace Dokku {
    public class RecentFilesMenu : GLib.Object {
        public static Gtk.Menu? build(DockItem item, AppManager app_manager, Gtk.Window parent) {
            var recent_manager = Gtk.RecentManager.get_default();
            var all_items = recent_manager.get_items();

            string? exec_base = null;
            var app = app_manager.get_app(item.id);
            if (app != null && app.exec != null && app.exec != "") {
                exec_base = Path.get_basename(app.exec.split(" ")[0]);
            }

            string? desktop_id = null;
            if (item.desktop_file != null) {
                desktop_id = Path.get_basename(item.desktop_file);
            }

            var matched = new List<Gtk.RecentInfo>();
            foreach (var info in all_items) {
                if (!info.exists()) continue;
                bool matches = false;
                if (exec_base != null && info.has_application(exec_base)) matches = true;
                if (!matches && desktop_id != null && info.has_application(desktop_id)) matches = true;
                if (!matches && info.has_application(item.id)) matches = true;
                if (matches) matched.append(info);
            }

            if (matched.length() == 0) {
                var menu = new Gtk.Menu();
                var empty = new Gtk.MenuItem.with_label("No recent files");
                empty.sensitive = false;
                menu.append(empty);
                return menu;
            }

            matched.sort((a, b) => {
                long at = (long)a.get_modified();
                long bt = (long)b.get_modified();
                if (at > bt) return -1;
                if (at < bt) return 1;
                return 0;
            });

            var menu = new Gtk.Menu();
            int count = 0;
            foreach (var info in matched) {
                if (count >= 10) break;
                string display_name = info.get_display_name();
                string uri = info.get_uri();
                var mi = new Gtk.MenuItem.with_label(display_name);
                mi.activate.connect(() => {
                    try {
                        Gtk.show_uri_on_window(parent, uri, Gdk.CURRENT_TIME);
                    } catch (Error e) {
                        warning("Failed to open recent file: %s", e.message);
                    }
                });
                menu.append(mi);
                count++;
            }
            return menu;
        }
    }
}
