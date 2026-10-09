namespace Dokku {
    public class TrashPlugin : Object, Plugin {
        public string id { get { return "trash"; } }
        public string name { get { return "Trash"; } }
        public string icon { owned get { return get_current_icon(); } }
        public bool has_action { get { return true; } }
        public bool has_menu { get { return true; } }

        private string trash_path;
        private FileMonitor? monitor;

        public signal void changed();

        public TrashPlugin() {
            trash_path = Path.build_filename(Environment.get_home_dir(), ".local/share/Trash/files");
            setup_monitor();
        }

        private void setup_monitor() {
            try {
                var dir = File.new_for_path(trash_path);
                monitor = dir.monitor_directory(FileMonitorFlags.NONE, null);
                monitor.changed.connect(() => changed());
            } catch (Error e) {
                warning("Failed to monitor trash: %s", e.message);
            }
        }

        public string get_current_icon() {
            return is_empty() ? "user-trash" : "user-trash-full";
        }

        private bool is_empty() {
            try {
                var dir = Dir.open(trash_path);
                return dir.read_name() == null;
            } catch (Error e) {
                return true;
            }
        }

        public void activate() {
            try {
                string[] argv = {"xdg-open", "trash://"};
                Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
            } catch (Error e) {
                warning("Failed to open trash: %s", e.message);
            }
        }

        public Gtk.Menu? get_menu() {
            var menu = new Gtk.Menu();

            var open = new Gtk.MenuItem.with_label("Open Trash");
            open.activate.connect(() => activate());
            menu.append(open);

            if (!is_empty()) {
                var empty = new Gtk.MenuItem.with_label("Empty Trash");
                empty.activate.connect(() => empty_trash());
                menu.append(empty);
            }

            menu.show_all();
            return menu;
        }

        private void empty_trash() {
            try {
                // Use gio to properly empty trash
                string[] argv = {"gio", "trash", "--empty"};
                Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
            } catch (Error e) {
                // Fallback to manual deletion
                var trash_files = Path.build_filename(Environment.get_home_dir(), ".local/share/Trash/files");
                var trash_info = Path.build_filename(Environment.get_home_dir(), ".local/share/Trash/info");
                clear_directory(trash_files);
                clear_directory(trash_info);
            }
        }

        private void clear_directory(string dir_path) {
            try {
                var dir = Dir.open(dir_path);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var full_path = Path.build_filename(dir_path, name);
                    var file = File.new_for_path(full_path);
                    var file_type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                    if (file_type == FileType.DIRECTORY) {
                        FileUtil.recursive_delete(full_path);
                    } else {
                        FileUtils.remove(full_path);
                    }
                }
            } catch (Error e) {
                warning("Failed to clear directory %s: %s", dir_path, e.message);
            }
        }

        ~TrashPlugin() {
            if (monitor != null) {
                monitor.cancel();
                monitor = null;
            }
        }

    }
}
