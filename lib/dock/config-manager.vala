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

        private bool is_valid_id(string id) {
            if (id.length == 0 || id.length > 64) return false;
            for (int i = 0; i < id.length; i++) {
                char c = id[i];
                if (!c.isalnum() && c != '_' && c != '-') return false;
            }
            return true;
        }

        public string[] get_pinned_apps() {
            try {
                return keyfile.get_string_list("Dock", "pinned");
            } catch (Error e) {
                return {"org.gnome.Nautilus", "org.gnome.Terminal", "firefox"};
            }
        }

        public void set_pinned_apps(string[] apps) {
            keyfile.set_string_list("Dock", "pinned", apps);
            save();
        }

        public int get_icon_size() {
            try { return keyfile.get_integer("Dock", "icon_size").clamp(16, 128); }
            catch (Error e) { return 48; }
        }

        public void set_icon_size(int size) {
            keyfile.set_integer("Dock", "icon_size", size);
            save();
        }

        public bool get_auto_hide() {
            try { return keyfile.get_boolean("Dock", "auto_hide"); }
            catch (Error e) { return false; }
        }

        public void set_auto_hide(bool enabled) {
            keyfile.set_boolean("Dock", "auto_hide", enabled);
            save();
        }

        public string get_position() {
            try { return keyfile.get_string("Dock", "position"); }
            catch (Error e) { return "bottom"; }
        }

        public void set_position(string pos) {
            keyfile.set_string("Dock", "position", pos);
            save();
        }

        public double get_magnification() {
            try { return keyfile.get_double("Dock", "magnification").clamp(1.0, 3.0); }
            catch (Error e) { return 1.5; }
        }

        public void set_magnification(double mag) {
            keyfile.set_double("Dock", "magnification", mag);
            save();
        }
        public string get_theme() {
            try { return keyfile.get_string("Dock", "theme"); }
            catch (Error e) { return "default"; }
        }

        public void set_theme(string theme) {
            keyfile.set_string("Dock", "theme", theme);
            save();
        }

        public int get_hide_delay() {
            try { return keyfile.get_integer("Dock", "hide_delay").clamp(100, 5000); }
            catch (Error e) { return 500; }
        }

        public void set_hide_delay(int delay) {
            keyfile.set_integer("Dock", "hide_delay", delay);
            save();
        }

        public bool get_multi_monitor() {
            try { return keyfile.get_boolean("Dock", "multi_monitor"); }
            catch (Error e) { return false; }
        }

        public void set_multi_monitor(bool enabled) {
            keyfile.set_boolean("Dock", "multi_monitor", enabled);
            save();
        }

        public bool get_rounded_corners() {
            try { return keyfile.get_boolean("Dock", "rounded_corners"); }
            catch (Error e) { return true; }
        }

        public void set_rounded_corners(bool enabled) {
            keyfile.set_boolean("Dock", "rounded_corners", enabled);
            save();
        }

        public double get_dock_opacity() {
            try { return keyfile.get_double("Dock", "dock_opacity").clamp(0.1, 1.0); }
            catch (Error e) { return 0.55; }
        }

        public void set_dock_opacity(double opacity) {
            keyfile.set_double("Dock", "dock_opacity", opacity);
            save();
        }

        public bool get_notification_badges() {
            try { return keyfile.get_boolean("Dock", "notification_badges"); }
            catch (Error e) { return true; }
        }

        public void set_notification_badges(bool enabled) {
            keyfile.set_boolean("Dock", "notification_badges", enabled);
            save();
        }

        public bool get_launch_bounce() {
            try { return keyfile.get_boolean("Dock", "launch_bounce"); }
            catch (Error e) { return true; }
        }

        public void set_launch_bounce(bool enabled) {
            keyfile.set_boolean("Dock", "launch_bounce", enabled);
            save();
        }

        public bool get_blur_enabled() {
            try { return keyfile.get_boolean("Dock", "blur_enabled"); }
            catch (Error e) { return false; }
        }

        public void set_blur_enabled(bool enabled) {
            keyfile.set_boolean("Dock", "blur_enabled", enabled);
            save();
        }


        public bool get_dodge_windows() {
            try { return keyfile.get_boolean("Dock", "dodge_windows"); }
            catch (Error e) { return false; }
        }

        public void set_dodge_windows(bool enabled) {
            keyfile.set_boolean("Dock", "dodge_windows", enabled);
            save();
        }

        public bool get_media_widget() {
            try { return keyfile.get_boolean("Dock", "media_widget"); }
            catch (Error e) { return true; }
        }

        public void set_media_widget(bool enabled) {
            keyfile.set_boolean("Dock", "media_widget", enabled);
            save();
        }

        public bool get_plugin_enabled(string plugin_id) {
            try {
                return keyfile.get_boolean("Plugins", plugin_id);
            } catch (Error e) {
                return true; // Default enabled
            }
        }

        public void set_plugin_enabled(string plugin_id, bool enabled) {
            keyfile.set_boolean("Plugins", plugin_id, enabled);
            save();
        }
        public bool get_launcher_fade() {
            try { return keyfile.get_boolean("Launcher", "fade_effect"); }
            catch (Error e) { return true; }
        }

        public void set_launcher_fade(bool enabled) {
            keyfile.set_boolean("Launcher", "fade_effect", enabled);
            save();
        }

        // Collect big categories into one folder each in the launcher's All view
        public bool get_group_apps() {
            try { return keyfile.get_boolean("Launcher", "group_apps"); }
            catch (Error e) { return true; }
        }

        public void set_group_apps(bool enabled) {
            keyfile.set_boolean("Launcher", "group_apps", enabled);
            save();
        }

        public string[] get_hidden_apps() {
            try {
                return keyfile.get_string_list("Launcher", "hidden");
            } catch (Error e) {
                return {};
            }
        }

        public void set_hidden_apps(string[] apps) {
            _hidden_apps_set = null;  // invalidate cache
            keyfile.set_string_list("Launcher", "hidden", apps);
            save();
        }

        public void hide_app(string app_id) {
            var hidden = get_hidden_apps();
            foreach (var id in hidden) {
                if (id == app_id) return;
            }
            hidden += app_id;
            set_hidden_apps(hidden);
        }

        public void unhide_app(string app_id) {
            var hidden = get_hidden_apps();
            string[] new_hidden = {};
            foreach (var id in hidden) {
                if (id != app_id) new_hidden += id;
            }
            set_hidden_apps(new_hidden);
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

        // Folder management
        public string[] get_folder_ids() {
            try {
                return keyfile.get_string_list("Folders", "ids");
            } catch (Error e) {
                return {};
            }
        }

        public string get_folder_name(string folder_id) {
            try {
                return keyfile.get_string("Folder_" + folder_id, "name");
            } catch (Error e) {
                return "Folder";
            }
        }

        public string[] get_folder_apps(string folder_id) {
            try {
                return keyfile.get_string_list("Folder_" + folder_id, "apps");
            } catch (Error e) {
                return {};
            }
        }

        public void create_folder(string folder_id, string name, string[] apps) {
            if (!is_valid_id(folder_id)) {
                warning("Invalid folder ID rejected: %s", folder_id);
                return;
            }
            var ids = get_folder_ids();
            bool exists = false;
            foreach (var id in ids) {
                if (id == folder_id) { exists = true; break; }
            }
            if (!exists) {
                ids += folder_id;
                keyfile.set_string_list("Folders", "ids", ids);
            }
            keyfile.set_string("Folder_" + folder_id, "name", name);
            keyfile.set_string_list("Folder_" + folder_id, "apps", apps);
            save();
        }

        public void rename_folder(string folder_id, string name) {
            if (!is_valid_id(folder_id)) return;
            keyfile.set_string("Folder_" + folder_id, "name", name);
            save();
        }

        public void add_app_to_folder(string folder_id, string app_id) {
            var apps = get_folder_apps(folder_id);
            foreach (var a in apps) {
                if (a == app_id) return;
            }
            apps += app_id;
            keyfile.set_string_list("Folder_" + folder_id, "apps", apps);
            save();
        }

        public void remove_app_from_folder(string folder_id, string app_id) {
            var apps = get_folder_apps(folder_id);
            string[] new_apps = {};
            foreach (var a in apps) {
                if (a != app_id) new_apps += a;
            }
            keyfile.set_string_list("Folder_" + folder_id, "apps", new_apps);
            save();
        }

        public void delete_folder(string folder_id) {
            var ids = get_folder_ids();
            string[] new_ids = {};
            foreach (var id in ids) {
                if (id != folder_id) new_ids += id;
            }
            keyfile.set_string_list("Folders", "ids", new_ids);
            try {
                keyfile.remove_group("Folder_" + folder_id);
            } catch (Error e) {}
            save();
        }

        public void move_folder_to_position(string folder_id, int position) {
            var ids = get_folder_ids();
            string[] without = {};
            foreach (var id in ids) {
                if (id != folder_id) without += id;
            }
            if (position < 0) position = 0;
            if (position > without.length) position = without.length;
            string[] result = {};
            for (int i = 0; i < without.length; i++) {
                if (i == position) result += folder_id;
                result += without[i];
            }
            if (position >= without.length) result += folder_id;
            keyfile.set_string_list("Folders", "ids", result);
            save();
        }

        public string? get_app_folder(string app_id) {
            foreach (var folder_id in get_folder_ids()) {
                foreach (var a in get_folder_apps(folder_id)) {
                    if (a == app_id) return folder_id;
                }
            }
            return null;
        }

        // Custom icon overrides
        public string? get_custom_icon(string app_id) {
            try {
                return keyfile.get_string("Icons", app_id);
            } catch (Error e) {
                return null;
            }
        }

        public void set_custom_icon(string app_id, string icon_name) {
            keyfile.set_string("Icons", app_id, icon_name);
            save();
        }

        public void clear_custom_icon(string app_id) {
            try {
                keyfile.remove_key("Icons", app_id);
                save();
            } catch (Error e) {}
        }

        // Hotkey configuration methods
        public string get_launcher_hotkey() {
            try {
                return keyfile.get_string("Hotkeys", "launcher");
            } catch (Error e) {
                return "Super_L";
            }
        }

        public void set_launcher_hotkey(string hotkey) {
            keyfile.set_string("Hotkeys", "launcher", hotkey);
            save();
        }

        public string get_app_hotkey_id(int slot) {
            try {
                return keyfile.get_string("Hotkeys", "app_%d_id".printf(slot));
            } catch (Error e) {
                return "";
            }
        }

        public void set_app_hotkey_id(int slot, string app_id) {
            keyfile.set_string("Hotkeys", "app_%d_id".printf(slot), app_id);
            save();
        }

        public string get_app_hotkey(int slot) {
            try {
                return keyfile.get_string("Hotkeys", "app_%d_hotkey".printf(slot));
            } catch (Error e) {
                return "";
            }
        }

        public void set_app_hotkey(int slot, string hotkey) {
            keyfile.set_string("Hotkeys", "app_%d_hotkey".printf(slot), hotkey);
            save();
        }

        // --- Usage Tracking [Usage] group ---

        public int get_usage_count(string app_id) {
            try {
                return keyfile.get_integer("Usage", app_id);
            } catch (Error e) {
                return 0;
            }
        }

        public void increment_usage(string app_id) {
            int count = get_usage_count(app_id);
            keyfile.set_integer("Usage", app_id, count + 1);
        }

        // --- Custom Shortcuts [Shortcuts] group ---

        public string[] get_shortcut_ids() {
            try {
                return keyfile.get_string_list("Shortcuts", "ids");
            } catch (Error e) {
                return {};
            }
        }

        public string get_shortcut_name(string shortcut_id) {
            try {
                return keyfile.get_string("Shortcut_" + shortcut_id, "name");
            } catch (Error e) {
                return "Untitled";
            }
        }

        public string get_shortcut_command(string shortcut_id) {
            try {
                return keyfile.get_string("Shortcut_" + shortcut_id, "command");
            } catch (Error e) {
                return "";
            }
        }

        public string get_shortcut_icon(string shortcut_id) {
            try {
                return keyfile.get_string("Shortcut_" + shortcut_id, "icon");
            } catch (Error e) {
                return "application-x-executable";
            }
        }

        public void create_shortcut(string shortcut_id, string name, string command, string icon) {
            if (!is_valid_id(shortcut_id)) {
                warning("Invalid shortcut ID rejected: %s", shortcut_id);
                return;
            }
            var ids = get_shortcut_ids();
            bool exists = false;
            foreach (var id in ids) {
                if (id == shortcut_id) { exists = true; break; }
            }
            if (!exists) {
                ids += shortcut_id;
                keyfile.set_string_list("Shortcuts", "ids", ids);
            }
            keyfile.set_string("Shortcut_" + shortcut_id, "name", name);
            keyfile.set_string("Shortcut_" + shortcut_id, "command", command);
            keyfile.set_string("Shortcut_" + shortcut_id, "icon", icon);
            save();
        }

        public void update_shortcut(string shortcut_id, string name, string command, string icon) {
            keyfile.set_string("Shortcut_" + shortcut_id, "name", name);
            keyfile.set_string("Shortcut_" + shortcut_id, "command", command);
            keyfile.set_string("Shortcut_" + shortcut_id, "icon", icon);
            save();
        }

        public void delete_shortcut(string shortcut_id) {
            var ids = get_shortcut_ids();
            string[] new_ids = {};
            foreach (var id in ids) {
                if (id != shortcut_id) new_ids += id;
            }
            keyfile.set_string_list("Shortcuts", "ids", new_ids);
            try {
                keyfile.remove_group("Shortcut_" + shortcut_id);
            } catch (Error e) {}
            save();
        }
    }
}
