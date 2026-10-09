namespace Dokku {
    public class AppInfo : Object {
        public string id { get; set; }
        public string name { get; set; }
        public string icon { get; set; }
        public string exec { get; set; }
        public string desktop_file { get; set; }
        public string[] categories { get; set; }
        public string display_category { get; set; default = "Other"; }

        // Pre-cached lowercase strings for O(n) matching in find_by_window slow path
        public string id_lower { get; set; default = ""; }
        public string name_lower { get; set; default = ""; }
        public string exec_base { get; set; default = ""; }

        // Set to true when NoDisplay=true — these apps should not appear in the launcher
        public bool no_display { get; set; default = false; }

        // Lazily initialized category map. Thread-safe because all callers
        // run on the main GTK thread (from load_applications → from_desktop_file).
        private static HashTable<string, string>? _category_map = null;

        private static unowned HashTable<string, string> get_category_map() {
            if (_category_map == null) {
                _category_map = new HashTable<string, string>(str_hash, str_equal);
                // Accessories
                _category_map.set("Utility", "Accessories");
                _category_map.set("Accessibility", "Accessories");
                _category_map.set("Calculator", "Accessories");
                _category_map.set("Clock", "Accessories");
                _category_map.set("TextTools", "Accessories");
                _category_map.set("Archiving", "Accessories");
                _category_map.set("Compression", "Accessories");
                _category_map.set("FileTools", "Accessories");
                _category_map.set("TextEditor", "Accessories");
                // Audio
                _category_map.set("Audio", "Audio");
                _category_map.set("Midi", "Audio");
                _category_map.set("Mixer", "Audio");
                _category_map.set("Sequencer", "Audio");
                _category_map.set("Music", "Audio");
                // Development
                _category_map.set("Development", "Development");
                _category_map.set("IDE", "Development");
                _category_map.set("Debugger", "Development");
                _category_map.set("RevisionControl", "Development");
                _category_map.set("Building", "Development");
                _category_map.set("Translation", "Development");
                _category_map.set("GUIDesigner", "Development");
                _category_map.set("Profiling", "Development");
                _category_map.set("WebDevelopment", "Development");
                // Education
                _category_map.set("Education", "Education");
                // Games
                _category_map.set("Game", "Games");
                _category_map.set("ActionGame", "Games");
                _category_map.set("AdventureGame", "Games");
                _category_map.set("ArcadeGame", "Games");
                _category_map.set("BoardGame", "Games");
                _category_map.set("BlocksGame", "Games");
                _category_map.set("CardGame", "Games");
                _category_map.set("LogicGame", "Games");
                _category_map.set("Simulation", "Games");
                _category_map.set("StrategyGame", "Games");
                _category_map.set("SportsGame", "Games");
                _category_map.set("Amusement", "Games");
                // Graphics
                _category_map.set("Graphics", "Graphics");
                _category_map.set("2DGraphics", "Graphics");
                _category_map.set("3DGraphics", "Graphics");
                _category_map.set("RasterGraphics", "Graphics");
                _category_map.set("VectorGraphics", "Graphics");
                _category_map.set("Photography", "Graphics");
                _category_map.set("Scanning", "Graphics");
                _category_map.set("ImageProcessing", "Graphics");
                // Internet
                _category_map.set("Network", "Internet");
                _category_map.set("WebBrowser", "Internet");
                _category_map.set("Email", "Internet");
                _category_map.set("Chat", "Internet");
                _category_map.set("InstantMessaging", "Internet");
                _category_map.set("IRCClient", "Internet");
                _category_map.set("Feed", "Internet");
                _category_map.set("FileTransfer", "Internet");
                _category_map.set("P2P", "Internet");
                _category_map.set("RemoteAccess", "Internet");
                _category_map.set("Telephony", "Internet");
                _category_map.set("VideoConference", "Internet");
                // Multimedia (apps tagged as both audio+video)
                _category_map.set("AudioVideo", "Multimedia");
                _category_map.set("Player", "Multimedia");
                _category_map.set("Recorder", "Multimedia");
                // Office
                _category_map.set("Office", "Office");
                _category_map.set("WordProcessor", "Office");
                _category_map.set("Spreadsheet", "Office");
                _category_map.set("Presentation", "Office");
                _category_map.set("Calendar", "Office");
                _category_map.set("ContactManagement", "Office");
                _category_map.set("Finance", "Office");
                _category_map.set("ProjectManagement", "Office");
                // Science
                _category_map.set("Science", "Science");
                // Settings
                _category_map.set("Settings", "Settings");
                _category_map.set("DesktopSettings", "Settings");
                _category_map.set("HardwareSettings", "Settings");
                // System
                _category_map.set("System", "System");
                _category_map.set("Monitor", "System");
                _category_map.set("Security", "System");
                _category_map.set("PackageManager", "System");
                _category_map.set("Emulator", "System");
                _category_map.set("TerminalEmulator", "System");
                _category_map.set("Filesystem", "System");
                _category_map.set("FileManager", "System");
                // Video
                _category_map.set("Video", "Video");
                _category_map.set("Tuner", "Video");
            }
            return _category_map;
        }

        private void resolve_display_category() {
            var map = get_category_map();
            foreach (var cat in categories) {
                string trimmed = cat.strip();
                if (trimmed == "") continue;
                string? mapped = map.get(trimmed);
                if (mapped != null) {
                    display_category = mapped;
                    return;
                }
            }
            display_category = "Other";
        }

        public AppInfo.from_desktop_file(string path) {
            desktop_file = path;
            id = Path.get_basename(path).replace(".desktop", "");

            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(path, KeyFileFlags.NONE);

                name = keyfile.get_locale_string("Desktop Entry", "Name");
                icon = keyfile.get_string("Desktop Entry", "Icon");
                exec = keyfile.get_string("Desktop Entry", "Exec");
                // Remove field codes from exec
                exec = exec.replace("%U", "").replace("%u", "")
                           .replace("%F", "").replace("%f", "")
                           .replace("%i", "").replace("%c", "")
                           .replace("%k", "").replace("%d", "")
                           .replace("%D", "").replace("%n", "")
                           .replace("%N", "").replace("%v", "")
                           .replace("%m", "").strip();

                if (keyfile.has_key("Desktop Entry", "Categories")) {
                    categories = keyfile.get_string("Desktop Entry", "Categories").split(";");
                } else {
                    categories = new string[0];
                }
                resolve_display_category();

                // Read NoDisplay in the same KeyFile pass — avoids a second file open
                if (keyfile.has_key("Desktop Entry", "NoDisplay")) {
                    no_display = keyfile.get_boolean("Desktop Entry", "NoDisplay");
                }
            } catch (Error e) {
                name = id;
                icon = "application-x-executable";
                exec = "";
                categories = new string[0];
            }

            // Cache lowercase strings for fast matching
            id_lower = id != null ? id.down() : "";
            name_lower = name != null ? name.down() : "";
            if (exec != null && exec != "") {
                exec_base = Path.get_basename(exec.split(" ")[0]).down();
            } else {
                exec_base = "";
            }
        }

        public void launch() {
            // Let GLib launch the entry: it honours Terminal=true, Path=, D-Bus
            // activation and the Exec field codes, none of which a hand-built argv does,
            // and the launch context carries focus/startup-notification (and, on
            // Wayland, the activation token) so the new window is raised correctly.
            if (desktop_file != null && desktop_file != "") {
                var info = new DesktopAppInfo.from_filename(desktop_file);
                if (info != null) {
                    try {
                        var display = Gdk.Display.get_default();
                        info.launch(null, display != null ? display.get_app_launch_context() : null);
                    } catch (Error e) {
                        warning("Failed to launch %s: %s", name, e.message);
                    }
                    return;
                }
            }

            // No usable .desktop file: run the Exec line directly
            try {
                string[] argv;
                Shell.parse_argv(exec, out argv);
                Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
            } catch (Error e) {
                warning("Failed to launch %s: %s", name, e.message);
            }
        }
    }

    public class AppManager : Object {
        private HashTable<string, AppInfo> apps;
        private HashTable<string, AppInfo> class_name_index;
        private HashTable<string, AppInfo> exec_base_index;
        private HashTable<string, GenericArray<weak AppInfo>> category_index;
        private GenericArray<FileMonitor> dir_monitors;
        private uint reload_timeout_id = 0;
        private const uint RELOAD_DELAY_MS = 2000;
        private string[] app_dirs = {
            "/usr/share/applications",
            "/usr/local/share/applications"
        };

        private const string[] CATEGORY_ORDER = {
            "Accessories", "Audio", "Development", "Education",
            "Games", "Graphics", "Internet", "Multimedia",
            "Office", "Science", "Settings", "System", "Video", "Other"
        };

        public signal void apps_changed();

        public AppManager() {
            apps = new HashTable<string, AppInfo>(str_hash, str_equal);
            class_name_index = new HashTable<string, AppInfo>(str_hash, str_equal);
            exec_base_index = new HashTable<string, AppInfo>(str_hash, str_equal);
            category_index = new HashTable<string, GenericArray<weak AppInfo>>(str_hash, str_equal);
            dir_monitors = new GenericArray<FileMonitor>();
            var home = Environment.get_home_dir();
            app_dirs += Path.build_filename(home, ".local/share/applications");
            load_applications();
            setup_directory_monitors();
        }

        private void setup_directory_monitors() {
            foreach (var dir_path in app_dirs) {
                try {
                    var dir = File.new_for_path(dir_path);
                    if (!dir.query_exists()) continue;
                    var monitor = dir.monitor_directory(FileMonitorFlags.NONE, null);
                    monitor.changed.connect(on_dir_changed);
                    dir_monitors.add(monitor);
                } catch (Error e) {
                    warning("Failed to monitor %s: %s", dir_path, e.message);
                }
            }
        }

        private void on_dir_changed(File file, File? other_file, FileMonitorEvent event_type) {
            if (!file.get_basename().has_suffix(".desktop")) return;
            if (event_type != FileMonitorEvent.CREATED &&
                event_type != FileMonitorEvent.DELETED &&
                event_type != FileMonitorEvent.CHANGES_DONE_HINT) return;
            schedule_reload();
        }

        private void schedule_reload() {
            if (reload_timeout_id != 0) return;
            reload_timeout_id = Timeout.add(RELOAD_DELAY_MS, () => {
                reload_timeout_id = 0;
                reload();
                return false;
            });
        }

        public void reload() {
            // Keep old data alive until rebuild completes to prevent
            // dangling weak references during synchronous signal handlers
            var old_apps = apps;
            apps = new HashTable<string, AppInfo>(str_hash, str_equal);
            load_applications();
            apps_changed();
            old_apps = null;
        }

        private void load_applications() {
            foreach (var dir in app_dirs) {
                try {
                    var directory = Dir.open(dir);
                    string? name;
                    while ((name = directory.read_name()) != null) {
                        if (name.has_suffix(".desktop")) {
                            var path = Path.build_filename(dir, name);
                            var app = new AppInfo.from_desktop_file(path);
                            if (app.exec != "" && !app.no_display) {
                                apps.set(app.id, app);
                            }
                        }
                    }
                } catch (Error e) {
                    warning("Failed to scan app directory %s: %s", dir, e.message);
                }
            }
            build_indices();
        }

        private void build_indices() {
            class_name_index.remove_all();
            exec_base_index.remove_all();
            category_index.remove_all();
            foreach (var app in apps.get_values()) {
                // Use the pre-cached lowercase fields computed in from_desktop_file()
                // instead of recomputing them (avoids redundant string allocations)
                class_name_index.set(app.id_lower, app);
                if (app.exec_base != "") {
                    exec_base_index.set(app.exec_base, app);
                }
                // Build category index
                string cat = app.display_category;
                if (!category_index.contains(cat)) {
                    category_index.set(cat, new GenericArray<weak AppInfo>());
                }
                category_index.get(cat).add(app);
            }
        }

        public string[] get_populated_categories() {
            string[] result = {};
            foreach (var cat in CATEGORY_ORDER) {
                if (category_index.contains(cat) && category_index.get(cat).length > 0) {
                    result += cat;
                }
            }
            return result;
        }

        public AppInfo? get_app(string id) {
            return apps.get(id);
        }

        public List<weak AppInfo> get_all_apps() {
            return apps.get_values();
        }

        public AppInfo? find_by_window(Wnck.Window window) {
            var wnck_app = window.get_application();
            if (wnck_app == null) return null;

            string? class_group = window.get_class_group_name();
            string? class_instance = window.get_class_instance_name();
            string cg = class_group != null ? class_group.down() : "";
            string ci = class_instance != null ? class_instance.down() : "";

            // Fast path: O(1) exact match on class_group or class_instance
            AppInfo? match = null;
            if (cg != "") {
                match = class_name_index.get(cg);
                if (match == null) match = exec_base_index.get(cg);
            }
            if (match == null && ci != "") {
                match = class_name_index.get(ci);
                if (match == null) match = exec_base_index.get(ci);
            }
            if (match != null) return match;

            // Slow path: fall back to full scan for partial matches
            // Uses pre-cached lowercase fields (id_lower, name_lower, exec_base)
            string app_name = wnck_app.get_name().down();
            AppInfo? best_match = null;
            int best_score = 0;

            foreach (var app in apps.get_values()) {
                int score = 0;

                if (app_name == app.id_lower || app_name == app.name_lower) score = 80;
                else if (cg != "" && (cg.has_prefix(app.id_lower) || app.id_lower.has_prefix(cg))) score = 50;
                else if (ci != "" && (ci.has_prefix(app.id_lower) || app.id_lower.has_prefix(ci))) score = 50;
                else if (cg != "" && (cg.has_prefix(app.exec_base) || app.exec_base.has_prefix(cg))) score = 40;
                else if (app_name.contains(app.id_lower) || app.id_lower.contains(app_name)) score = 30;
                else if (app.name_lower.contains(app_name) || app_name.contains(app.name_lower)) score = 20;

                if (score > best_score || (score == best_score && best_match != null && app.id_lower.length < best_match.id_lower.length)) {
                    best_score = score;
                    best_match = app;
                }
            }
            return best_match;
        }

        public AppInfo? find_by_name(string name) {
            string lower = name.down();

            // Fast path: O(1) exact match on indices
            AppInfo? match = class_name_index.get(lower);
            if (match != null) return match;
            match = exec_base_index.get(lower);
            if (match != null) return match;

            // Slow path: scan by display name
            foreach (var app in apps.get_values()) {
                if (app.name.down() == lower) return app;
            }
            return null;
        }
    }
}
