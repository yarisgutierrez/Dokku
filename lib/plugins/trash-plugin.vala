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
        // A drop onto the Trash is done (ok) or failed, and how many items it covered
        public signal void trash_finished(bool ok, int count);

        public TrashPlugin() {
            trash_path = Path.build_filename(Environment.get_home_dir(), ".local/share/Trash/files");
            setup_monitor();
        }

        private void setup_monitor() {
            // The folder only exists once something has been trashed; watching a folder that
            // is missing would leave the icon stale after the first file goes in
            DirUtils.create_with_parents(trash_path, 0700);
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

        // --- Trashing dropped files ---

        // A file: URI that names a file on this machine. GLib turns file://otherhost/etc/x
        // into the local path /etc/x without looking at the host, which here would mean
        // trashing the wrong file, so the host is checked: none, "localhost", or this one.
        public static bool is_local_file_uri(string uri) {
            if (!uri.has_prefix("file://")) return false;
            string rest = uri.substring(7);
            int slash = rest.index_of_char('/');
            if (slash < 0) return false;
            string host = rest.substring(0, slash).down();
            return host == "" || host == "localhost" || host == Environment.get_host_name().down();
        }

        // The local paths in a list of URIs, once each. Web addresses and files on remote
        // shares are left out.
        public static string[] local_paths(string[] uris) {
            string[] paths = {};
            foreach (var uri in uris) {
                if (!is_local_file_uri(uri)) continue;
                string path;
                try {
                    path = Filename.from_uri(uri);
                } catch (Error e) {
                    continue;
                }
                bool seen = false;
                foreach (var p in paths) {
                    if (p == path) { seen = true; break; }
                }
                if (!seen) paths += path;
            }
            return paths;
        }

        // An absolute path without doubled or trailing slashes or "." parts; "" for a path
        // that is not absolute or that climbs with "..", which nothing dropped should do
        private static string normalize(string path) {
            if (path == "" || !Path.is_absolute(path)) return "";
            var clean = new StringBuilder();
            foreach (var part in path.split("/")) {
                if (part == "" || part == ".") continue;
                if (part == "..") return "";
                clean.append_c('/').append(part);
            }
            return clean.len == 0 ? "/" : clean.str;
        }

        // Whether a path is something to move to the Trash. The root, the home folder and
        // anything above it are refused (a stray drop must not take your whole home with
        // it), and so is the Trash itself.
        public static bool is_safe_to_trash(string path, string home, string trash_root) {
            string clean = normalize(path);
            if (clean == "" || clean == "/") return false;
            string h = normalize(home);
            if (h != "" && (clean == h || h.has_prefix(clean + "/"))) return false;
            string t = normalize(trash_root);
            if (t != "" && (clean == t || clean.has_prefix(t + "/"))) return false;
            return true;
        }

        // Moves dropped files to the Trash with gio, the standard way, so the file manager's
        // Undo and Restore work. Returns how many items were sent; 0 means none were fit to
        // trash (nothing runs then). trash_finished says how it went.
        public int trash_uris(string[] uris) {
            string trash_root = Path.get_dirname(trash_path);
            string[] argv = { "gio", "trash", "--" };
            int count = 0;
            foreach (var path in local_paths(uris)) {
                if (!is_safe_to_trash(path, Environment.get_home_dir(), trash_root)) continue;
                argv += path;
                count++;
            }
            if (count == 0) return 0;
            try {
                Pid pid;
                Process.spawn_async(null, argv, null,
                    SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out pid);
                ChildWatch.add(pid, (child, status) => {
                    Process.close_pid(child);
                    bool ok = false;
                    try { ok = Process.check_wait_status(status); } catch (Error e) {}
                    trash_finished(ok, count);
                    changed();
                });
            } catch (Error e) {
                warning("Failed to run gio trash: %s", e.message);
                return 0;
            }
            return count;
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
