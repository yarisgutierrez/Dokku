namespace Dokku {
    public class ConfigManager : Object {
        private string config_dir;
        private string config_file;
        private KeyFile keyfile;

        public ConfigManager() {
            config_dir = Path.build_filename(Environment.get_home_dir(), ".config", "dokku");
            config_file = Path.build_filename(config_dir, "config.ini");
            keyfile = new KeyFile();

            DirUtils.create_with_parents(config_dir, 0700);
            load();
        }

        private bool batch_mode = false;

        public void reload() {
            keyfile = new KeyFile();
            load();
        }

        public void begin_batch() {
            batch_mode = true;
        }

        public void end_batch() {
            batch_mode = false;
            save();
        }

        private void load() {
            try {
                keyfile.load_from_file(config_file, KeyFileFlags.NONE);
            } catch (Error e) {
                if (FileUtils.test(config_file, FileTest.EXISTS)) {
                    warning("Failed to load config %s: %s", config_file, e.message);
                }
            }
        }

        public void save() {
            if (batch_mode) return;
            try {
                // Atomic write: save to temp file, then rename
                var tmp_file = config_file + ".tmp";
                keyfile.save_to_file(tmp_file);
                Posix.chmod(tmp_file, 0600);
                FileUtils.rename(tmp_file, config_file);
            } catch (Error e) {
                warning("Failed to save config: %s", e.message);
                // Clean up temp file on failure
                FileUtils.remove(config_file + ".tmp");
            }
        }

        // --- Per-monitor settings ---
        //
        // A monitor can override the position, the icon size and auto-hide. A setting
        // that is not overridden follows the one for all monitors. Monitors are named by
        // MonitorKey and kept in a [Monitor:<name>] section.

        private static string monitor_group(string key) {
            return "Monitor:" + key;
        }

        private static bool valid_position(string position) {
            return position == "bottom" || position == "top" || position == "left" || position == "right";
        }

        // null when this monitor has no override
        public string? get_monitor_position(string key) {
            try {
                string value = keyfile.get_string(monitor_group(key), "position");
                return valid_position(value) ? value : null;
            } catch (Error e) {
                return null;
            }
        }

        // 0 when this monitor has no override
        public int get_monitor_icon_size(string key) {
            try { return keyfile.get_integer(monitor_group(key), "icon_size").clamp(16, 128); }
            catch (Error e) { return 0; }
        }

        // -1 when this monitor has no override, otherwise 0 (off) or 1 (on)
        public int get_monitor_auto_hide(string key) {
            try { return keyfile.get_boolean(monitor_group(key), "auto_hide") ? 1 : 0; }
            catch (Error e) { return -1; }
        }

        // null clears the override
        public void set_monitor_position(string key, string? position) {
            set_monitor_value(key, "position", position != null && valid_position(position) ? position : null);
        }

        // 0 clears the override
        public void set_monitor_icon_size(string key, int size) {
            set_monitor_value(key, "icon_size", size > 0 ? size.clamp(16, 128).to_string() : null);
        }

        // -1 clears the override
        public void set_monitor_auto_hide(string key, int state) {
            set_monitor_value(key, "auto_hide", state < 0 ? null : (state > 0 ? "true" : "false"));
        }

        private void set_monitor_value(string key, string name, string? value) {
            if (key == "") return;
            string group = monitor_group(key);
            if (value == null) {
                try {
                    if (keyfile.has_group(group) && keyfile.has_key(group, name)) {
                        keyfile.remove_key(group, name);
                        // An empty section is just clutter
                        if (keyfile.get_keys(group).length == 0) keyfile.remove_group(group);
                    }
                } catch (Error e) {}
            } else {
                keyfile.set_value(group, name, value);
            }
            save();
        }

        // What a dock on this monitor uses: the override, or the setting for all monitors
        public string get_position_for(string monitor_key) {
            return get_monitor_position(monitor_key) ?? get_position();
        }

        public int get_icon_size_for(string monitor_key) {
            int size = get_monitor_icon_size(monitor_key);
            return size > 0 ? size : get_icon_size();
        }

        public bool get_auto_hide_for(string monitor_key) {
            int state = get_monitor_auto_hide(monitor_key);
            return state < 0 ? get_auto_hide() : state > 0;
        }

        // --- Backup, restore and reset ---

        private const int64 MAX_IMPORT_BYTES = 1048576;

        private static bool is_known_group(string group) {
            switch (group) {
                case "Dock": case "Launcher": case "Plugins": case "Icons": case "Usage":
                case "Media": case "Hotkeys": case "Folders": case "Shortcuts":
                    return true;
                default:
                    return group.has_prefix("Folder_") || group.has_prefix("Shortcut_") ||
                           group.has_prefix("Monitor:");
            }
        }

        // Writes the current settings to a file of the user's choosing
        public void export_to(string path) throws Error {
            FileUtils.set_contents(path, keyfile.to_data());
        }

        // Replaces the settings with those in a file. The file must be small, parse as
        // settings and hold only sections Dokku knows, so a wrong file is refused before
        // anything changes. The settings being replaced are kept as config.ini.bak.
        public void import_from(string path) throws Error {
            var info = File.new_for_path(path).query_info("standard::size", FileQueryInfoFlags.NONE);
            if (info.get_size() > MAX_IMPORT_BYTES) {
                throw new KeyFileError.PARSE("That file is too large to be Dokku settings.");
            }
            var incoming = new KeyFile();
            incoming.load_from_file(path, KeyFileFlags.NONE);

            string[] groups = incoming.get_groups();
            if (groups.length == 0) {
                throw new KeyFileError.GROUP_NOT_FOUND("That file has no settings in it.");
            }
            foreach (var group in groups) {
                if (!is_known_group(group)) {
                    throw new KeyFileError.GROUP_NOT_FOUND("That is not a Dokku settings file (section [%s]).".printf(group));
                }
            }
            // A value of the wrong kind would only fail later; catch it now
            Dokku.ConfigManager.check_values(incoming);

            keep_backup();
            keyfile = incoming;
            save();
        }

        // Starts over with the defaults. The old settings are kept as config.ini.bak.
        public void reset_to_defaults() {
            keep_backup();
            keyfile = new KeyFile();
            save();
        }

        private void keep_backup() {
            if (!FileUtils.test(config_file, FileTest.EXISTS)) return;
            try {
                File.new_for_path(config_file).copy(File.new_for_path(config_file + ".bak"),
                                                    FileCopyFlags.OVERWRITE);
                Posix.chmod(config_file + ".bak", 0600);
            } catch (Error e) {
                warning("Could not keep a backup of the settings: %s", e.message);
            }
        }

        // Reads the settings that must be a particular kind of value, and throws when one is not
        private static void check_values(KeyFile k) throws Error {
            string[,] bools = {
                {"Dock", "auto_hide"}, {"Dock", "media_widget"}, {"Dock", "minimize_on_click"},
                {"Dock", "notification_badges"}, {"Dock", "launch_bounce"}, {"Launcher", "fade_effect"}
            };
            for (int i = 0; i < bools.length[0]; i++) {
                if (k.has_group(bools[i, 0]) && k.has_key(bools[i, 0], bools[i, 1])) k.get_boolean(bools[i, 0], bools[i, 1]);
            }
            string[,] numbers = { {"Dock", "icon_size"}, {"Dock", "hide_delay"} };
            for (int i = 0; i < numbers.length[0]; i++) {
                if (k.has_group(numbers[i, 0]) && k.has_key(numbers[i, 0], numbers[i, 1])) k.get_integer(numbers[i, 0], numbers[i, 1]);
            }
            foreach (var group in k.get_groups()) {
                if (!group.has_prefix("Monitor:")) continue;
                if (k.has_key(group, "icon_size")) k.get_integer(group, "icon_size");
                if (k.has_key(group, "auto_hide")) k.get_boolean(group, "auto_hide");
            }
            string[,] fractions = { {"Dock", "magnification"}, {"Dock", "dock_opacity"} };
            for (int i = 0; i < fractions.length[0]; i++) {
                if (k.has_group(fractions[i, 0]) && k.has_key(fractions[i, 0], fractions[i, 1])) k.get_double(fractions[i, 0], fractions[i, 1]);
            }
        }

        private bool is_valid_id(string id) {
            if (id.length == 0 || id.length > 64) return false;
            for (int i = 0; i < id.length; i++) {
                char c = id[i];
                if (!c.isalnum() && c != '_' && c != '-') return false;
            }
            return true;
        }

        // --- Typed access to the key file: a missing or malformed key reads as `fallback` ---

        private bool read_bool(string group, string key, bool fallback) {
            try { return keyfile.get_boolean(group, key); } catch (Error e) { return fallback; }
        }

        private int read_int(string group, string key, int fallback) {
            try { return keyfile.get_integer(group, key); } catch (Error e) { return fallback; }
        }

        private double read_double(string group, string key, double fallback) {
            try { return keyfile.get_double(group, key); } catch (Error e) { return fallback; }
        }

        private string read_string(string group, string key, string fallback) {
            try { return keyfile.get_string(group, key); } catch (Error e) { return fallback; }
        }

        private string[] read_list(string group, string key, string[] fallback = {}) {
            try { return keyfile.get_string_list(group, key); } catch (Error e) { return fallback; }
        }

        private void write_bool(string group, string key, bool value) {
            keyfile.set_boolean(group, key, value);
            save();
        }

        private void write_int(string group, string key, int value) {
            keyfile.set_integer(group, key, value);
            save();
        }

        private void write_double(string group, string key, double value) {
            keyfile.set_double(group, key, value);
            save();
        }

        private void write_string(string group, string key, string value) {
            keyfile.set_string(group, key, value);
            save();
        }

        private void write_list(string group, string key, string[] value) {
            keyfile.set_string_list(group, key, value);
            save();
        }

        private static string[] without(string[] list, string item) {
            string[] result = {};
            foreach (var entry in list) {
                if (entry != item) result += entry;
            }
            return result;
        }

        // --- Dock ---

        public string[] get_pinned_apps() {
            return read_list("Dock", "pinned", {"org.gnome.Nautilus", "org.gnome.Terminal", "firefox"});
        }

        public void set_pinned_apps(string[] apps) { write_list("Dock", "pinned", apps); }

        public int get_icon_size() { return read_int("Dock", "icon_size", 48).clamp(16, 128); }
        public void set_icon_size(int size) { write_int("Dock", "icon_size", size); }

        public bool get_auto_hide() { return read_bool("Dock", "auto_hide", false); }
        public void set_auto_hide(bool enabled) { write_bool("Dock", "auto_hide", enabled); }

        public string get_position() { return read_string("Dock", "position", "bottom"); }
        public void set_position(string pos) { write_string("Dock", "position", pos); }

        public double get_magnification() { return read_double("Dock", "magnification", 1.5).clamp(1.0, 3.0); }
        public void set_magnification(double mag) { write_double("Dock", "magnification", mag); }

        public string get_theme() { return read_string("Dock", "theme", "default"); }
        public void set_theme(string theme) { write_string("Dock", "theme", theme); }

        public int get_hide_delay() { return read_int("Dock", "hide_delay", 500).clamp(100, 5000); }
        public void set_hide_delay(int delay) { write_int("Dock", "hide_delay", delay); }

        public bool get_multi_monitor() { return read_bool("Dock", "multi_monitor", false); }
        public void set_multi_monitor(bool enabled) { write_bool("Dock", "multi_monitor", enabled); }

        public bool get_rounded_corners() { return read_bool("Dock", "rounded_corners", true); }
        public void set_rounded_corners(bool enabled) { write_bool("Dock", "rounded_corners", enabled); }

        public double get_dock_opacity() { return read_double("Dock", "dock_opacity", 0.55).clamp(0.1, 1.0); }
        public void set_dock_opacity(double opacity) { write_double("Dock", "dock_opacity", opacity); }

        public bool get_notification_badges() { return read_bool("Dock", "notification_badges", true); }
        public void set_notification_badges(bool enabled) { write_bool("Dock", "notification_badges", enabled); }

        public bool get_launch_bounce() { return read_bool("Dock", "launch_bounce", true); }
        public void set_launch_bounce(bool enabled) { write_bool("Dock", "launch_bounce", enabled); }

        public bool get_blur_enabled() { return read_bool("Dock", "blur_enabled", false); }
        public void set_blur_enabled(bool enabled) { write_bool("Dock", "blur_enabled", enabled); }

        public bool get_dodge_windows() { return read_bool("Dock", "dodge_windows", false); }
        public void set_dodge_windows(bool enabled) { write_bool("Dock", "dodge_windows", enabled); }

        public bool get_media_widget() { return read_bool("Dock", "media_widget", true); }
        public void set_media_widget(bool enabled) { write_bool("Dock", "media_widget", enabled); }

        // Clicking the icon of the app that has focus minimizes it
        public bool get_minimize_on_click() { return read_bool("Dock", "minimize_on_click", true); }
        public void set_minimize_on_click(bool enabled) { write_bool("Dock", "minimize_on_click", enabled); }

        // Players the media widget ignores, matched against the MPRIS bus name
        public string[] get_media_blocked_players() {
            return read_list("Media", "blocked_players", MediaPlayerPicker.DEFAULT_BLOCKED);
        }

        public void set_media_blocked_players(string[] players) { write_list("Media", "blocked_players", players); }

        public bool get_plugin_enabled(string plugin_id, bool default_value = true) {
            return read_bool("Plugins", plugin_id, default_value);
        }

        public void set_plugin_enabled(string plugin_id, bool enabled) { write_bool("Plugins", plugin_id, enabled); }

        // --- Launcher ---

        // Where the launcher's "search the web" row goes; %s stands for the words.
        // Empty turns the row off.
        public string get_web_search_url() {
            return read_string("Launcher", "web_search_url", QuickResults.DEFAULT_WEB_SEARCH);
        }

        public void set_web_search_url(string url) { write_string("Launcher", "web_search_url", url); }

        public bool get_launcher_fade() { return read_bool("Launcher", "fade_effect", true); }
        public void set_launcher_fade(bool enabled) { write_bool("Launcher", "fade_effect", enabled); }

        // Collect big categories into one folder each in the launcher's All view
        public bool get_group_apps() { return read_bool("Launcher", "group_apps", true); }
        public void set_group_apps(bool enabled) { write_bool("Launcher", "group_apps", enabled); }

        public string[] get_hidden_apps() { return read_list("Launcher", "hidden"); }

        public void set_hidden_apps(string[] apps) {
            _hidden_apps_set = null;  // invalidate cache
            write_list("Launcher", "hidden", apps);
        }

        public void hide_app(string app_id) {
            var hidden = get_hidden_apps();
            if (app_id in hidden) return;
            hidden += app_id;
            set_hidden_apps(hidden);
        }

        public void unhide_app(string app_id) {
            set_hidden_apps(without(get_hidden_apps(), app_id));
        }

        // Lazily built set for O(1) repeated lookups; nulled whenever set_hidden_apps() writes
        private HashTable<string, bool>? _hidden_apps_set = null;

        public bool is_app_hidden(string app_id) {
            if (_hidden_apps_set == null) {
                _hidden_apps_set = new HashTable<string, bool>(str_hash, str_equal);
                foreach (var id in get_hidden_apps()) {
                    _hidden_apps_set.set(id, true);
                }
            }
            return _hidden_apps_set.contains(app_id);
        }

        // --- Folders ---

        public string[] get_folder_ids() { return read_list("Folders", "ids"); }

        public string get_folder_name(string folder_id) {
            return read_string("Folder_" + folder_id, "name", "Folder");
        }

        public string[] get_folder_apps(string folder_id) {
            return read_list("Folder_" + folder_id, "apps");
        }

        public void create_folder(string folder_id, string name, string[] apps) {
            if (!is_valid_id(folder_id)) {
                warning("Invalid folder ID rejected: %s", folder_id);
                return;
            }
            add_id("Folders", folder_id);
            keyfile.set_string("Folder_" + folder_id, "name", name);
            write_list("Folder_" + folder_id, "apps", apps);
        }

        // Add `id` to the list of ids kept in `group`, once
        private void add_id(string group, string id) {
            var ids = read_list(group, "ids");
            if (id in ids) return;
            ids += id;
            keyfile.set_string_list(group, "ids", ids);
        }

        public void rename_folder(string folder_id, string name) {
            if (!is_valid_id(folder_id)) return;
            write_string("Folder_" + folder_id, "name", name);
        }

        public void add_app_to_folder(string folder_id, string app_id) {
            var apps = get_folder_apps(folder_id);
            if (app_id in apps) return;
            apps += app_id;
            write_list("Folder_" + folder_id, "apps", apps);
        }

        public void remove_app_from_folder(string folder_id, string app_id) {
            write_list("Folder_" + folder_id, "apps", without(get_folder_apps(folder_id), app_id));
        }

        public void delete_folder(string folder_id) {
            remove_entry("Folders", "Folder_", folder_id);
        }

        // Drop `id` from the list in `list_group` and remove its own section, prefix + id
        private void remove_entry(string list_group, string section_prefix, string id) {
            keyfile.set_string_list(list_group, "ids", without(read_list(list_group, "ids"), id));
            try {
                keyfile.remove_group(section_prefix + id);
            } catch (Error e) {}
            save();
        }

        public void move_folder_to_position(string folder_id, int position) {
            string[] rest = without(get_folder_ids(), folder_id);
            position = position.clamp(0, rest.length);
            string[] result = {};
            for (int i = 0; i < rest.length; i++) {
                if (i == position) result += folder_id;
                result += rest[i];
            }
            if (position >= rest.length) result += folder_id;
            write_list("Folders", "ids", result);
        }

        public string? get_app_folder(string app_id) {
            foreach (var folder_id in get_folder_ids()) {
                if (app_id in get_folder_apps(folder_id)) return folder_id;
            }
            return null;
        }

        // --- Custom icon overrides ---

        public string? get_custom_icon(string app_id) {
            try {
                return keyfile.get_string("Icons", app_id);
            } catch (Error e) {
                return null;
            }
        }

        public void set_custom_icon(string app_id, string icon_name) { write_string("Icons", app_id, icon_name); }

        public void clear_custom_icon(string app_id) {
            try {
                keyfile.remove_key("Icons", app_id);
                save();
            } catch (Error e) {}
        }

        // --- Hotkeys ---

        public string get_launcher_hotkey() { return read_string("Hotkeys", "launcher", "Super_L"); }
        public void set_launcher_hotkey(string hotkey) { write_string("Hotkeys", "launcher", hotkey); }

        public string get_app_hotkey_id(int slot) { return read_string("Hotkeys", "app_%d_id".printf(slot), ""); }
        public void set_app_hotkey_id(int slot, string app_id) { write_string("Hotkeys", "app_%d_id".printf(slot), app_id); }

        public string get_app_hotkey(int slot) { return read_string("Hotkeys", "app_%d_hotkey".printf(slot), ""); }
        public void set_app_hotkey(int slot, string hotkey) { write_string("Hotkeys", "app_%d_hotkey".printf(slot), hotkey); }

        // --- Usage Tracking [Usage] group ---

        public int get_usage_count(string app_id) { return read_int("Usage", app_id, 0); }

        // Saved later by UsageTracker, in one write
        public void increment_usage(string app_id) {
            keyfile.set_integer("Usage", app_id, get_usage_count(app_id) + 1);
        }

        // --- Custom Shortcuts [Shortcuts] group ---

        public string[] get_shortcut_ids() { return read_list("Shortcuts", "ids"); }

        public string get_shortcut_name(string shortcut_id) {
            return read_string("Shortcut_" + shortcut_id, "name", "Untitled");
        }

        public string get_shortcut_command(string shortcut_id) {
            return read_string("Shortcut_" + shortcut_id, "command", "");
        }

        public string get_shortcut_icon(string shortcut_id) {
            return read_string("Shortcut_" + shortcut_id, "icon", "application-x-executable");
        }

        public void create_shortcut(string shortcut_id, string name, string command, string icon) {
            if (!is_valid_id(shortcut_id)) {
                warning("Invalid shortcut ID rejected: %s", shortcut_id);
                return;
            }
            add_id("Shortcuts", shortcut_id);
            update_shortcut(shortcut_id, name, command, icon);
        }

        public void update_shortcut(string shortcut_id, string name, string command, string icon) {
            string section = "Shortcut_" + shortcut_id;
            keyfile.set_string(section, "name", name);
            keyfile.set_string(section, "command", command);
            keyfile.set_string(section, "icon", icon);
            save();
        }

        public void delete_shortcut(string shortcut_id) {
            remove_entry("Shortcuts", "Shortcut_", shortcut_id);
        }
    }
}
