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
            register_plugin(new MediaPlugin(config.get_media_blocked_players()));
        }

        // Plugins that ship with Dokku, in the data directories (/usr/share/dokku/plugins), and
        // those the user installed. A user plugin with the same id replaces a bundled one.
        // DOKKU_PLUGIN_DIR adds one more directory, for running from a source tree.
        private void load_user_plugins() {
            var dirs = new List<string>();
            string? extra = Environment.get_variable("DOKKU_PLUGIN_DIR");
            if (extra != null && extra != "") dirs.append(extra);
            foreach (var data_dir in Environment.get_system_data_dirs()) {
                dirs.append(Path.build_filename(data_dir, "dokku", "plugins"));
            }
            dirs.append(user_plugins_dir);
            foreach (var dir in dirs) load_plugins_from(dir);
        }

        private void load_plugins_from(string plugins_dir) {
            try {
                var dir = Dir.open(plugins_dir);
                string? name;
                while ((name = dir.read_name()) != null) {
                    var plugin_file = Path.build_filename(plugins_dir, name, "plugin.ini");
                    if (FileUtils.test(plugin_file, FileTest.EXISTS)) {
                        var plugin = new ScriptPlugin.from_file(plugin_file);
                        if (plugin.id != null) {
                            register_plugin(plugin);
                        }
                    }
                }
            } catch (Error e) {
                // A directory that does not exist is normal
                if (plugins_dir == user_plugins_dir) warning("Failed to load user plugins: %s", e.message);
            }
        }

        public void register_plugin(Plugin plugin) {
            plugins.set(plugin.id, plugin);
        }

        public Plugin? get_plugin(string id) {
            return plugins.get(id);
        }

        public List<weak Plugin> get_user_plugins() {
            var list = new List<weak Plugin>();
            foreach (var plugin in plugins.get_values()) {
                if (plugin is ScriptPlugin) {
                    list.append(plugin);
                }
            }
            // The hash table has no order of its own; keep the widgets where they were put
            list.sort((a, b) => strcmp(a.id, b.id));
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
    }
}
