namespace Dokku {
    public class PluginManager : Object {
        private HashTable<string, Plugin> plugins;
        private ConfigManager config;
        private string user_plugins_dir;

        public PluginManager(ConfigManager config) {
            this.config = config;
            plugins = new HashTable<string, Plugin>(str_hash, str_equal);
            user_plugins_dir = Path.build_filename(Environment.get_home_dir(), ".local/share/dokku/plugins");
            DirUtils.create_with_parents(user_plugins_dir, 0755);
            load_builtin_plugins();
            load_user_plugins();
        }

        private void load_builtin_plugins() {
            register_plugin(new TrashPlugin());
            register_plugin(new ShowDesktopPlugin());
            register_plugin(new SeparatorPlugin());
            register_plugin(new MediaPlugin());
        }

        private void load_user_plugins() {
            try {
                var dir = Dir.open(user_plugins_dir);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var plugin_file = Path.build_filename(user_plugins_dir, name, "plugin.ini");
                    if (FileUtils.test(plugin_file, FileTest.EXISTS)) {
                        var plugin = new ScriptPlugin.from_file(plugin_file);
                        if (plugin.id != null) {
                            register_plugin(plugin);
                        }
                    }
                }
            } catch (Error e) {
                warning("Failed to load user plugins: %s", e.message);
            }
        }

        public void register_plugin(Plugin plugin) {
            plugins.set(plugin.id, plugin);
        }

        public void unregister_plugin(string id) {
            plugins.remove(id);
        }

        public Plugin? get_plugin(string id) {
            return plugins.get(id);
        }

        public List<weak Plugin> get_all_plugins() {
            return plugins.get_values();
        }

        public List<weak Plugin> get_user_plugins() {
            var list = new List<weak Plugin>();
            foreach (var plugin in plugins.get_values()) {
                if (plugin is ScriptPlugin) {
                    list.append(plugin);
                }
            }
            return list;
        }

        public bool install_plugin(string zip_path) {
            string dest;
            if (!FileUtil.install_zip(zip_path, user_plugins_dir, out dest)) {
                return false;
            }

            var plugin_file = Path.build_filename(dest, "plugin.ini");
            if (FileUtils.test(plugin_file, FileTest.EXISTS)) {
                var plugin = new ScriptPlugin.from_file(plugin_file);
                if (plugin.id != null) {
                    register_plugin(plugin);
                    return true;
                }
            }
            warning("Plugin zip had no valid plugin.ini: %s", zip_path);
            return false;
        }

        public void uninstall_plugin(string id) {
            var plugin = plugins.get(id) as ScriptPlugin;
            if (plugin != null && plugin.path != null) {
                var dir = Path.get_dirname(plugin.path);
                string? real_dir = Posix.realpath(dir);
                string? real_base = Posix.realpath(user_plugins_dir);
                if (real_dir != null && real_base != null && real_dir.has_prefix(real_base + "/")) {
                    try {
                        FileUtil.recursive_delete(dir);
                        plugins.remove(id);
                    } catch (Error e) {
                        warning("Failed to uninstall plugin %s: %s", id, e.message);
                    }
                }
            }
        }

        public string[] get_enabled_plugins() {
            string[] result = {};
            foreach (var plugin in plugins.get_values()) {
                if (config.get_plugin_enabled(plugin.id)) {
                    result += plugin.id;
                }
            }
            return result;
        }

        public void set_enabled_plugins(string[] ids) {
            // Build a set for O(1) lookup so we don't do O(n*m) iteration
            var id_set = new HashTable<string, bool>(str_hash, str_equal);
            foreach (var id in ids) {
                id_set.set(id, true);
            }
            // Write all plugin states in one batch — avoids N separate disk writes
            config.begin_batch();
            foreach (var plugin in plugins.get_values()) {
                config.set_plugin_enabled(plugin.id, id_set.contains(plugin.id));
            }
            config.end_batch();
        }
    }
}
