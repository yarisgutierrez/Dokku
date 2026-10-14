namespace Dokku {
    public class ThemeManager : Object {
        private HashTable<string, Theme> themes;
        private string themes_dir;
        private string user_themes_dir;

        public ThemeManager() {
            themes = new HashTable<string, Theme>(str_hash, str_equal);
            themes_dir = "/usr/share/dokku/themes";
            user_themes_dir = Path.build_filename(Environment.get_home_dir(), ".local/share/dokku/themes");

            DirUtils.create_with_parents(user_themes_dir, 0755);
            load_builtin_themes();
            scan_themes();
        }

        private void load_builtin_themes() {
            // Default (macOS-style)
            var def = new Theme("default", "Default");
            themes.set(def.id, def);

            // Dark
            var dark = new Theme("dark", "Dark");
            dark.bg_red = 0.08; dark.bg_green = 0.08; dark.bg_blue = 0.08;
            dark.bg_alpha = 0.7;
            dark.border_alpha = 0.1;
            themes.set(dark.id, dark);

            // Light (macOS-style frosted glass)
            var light = new Theme("light", "Light");
            light.bg_red = 0.96; light.bg_green = 0.96; light.bg_blue = 0.97;
            light.bg_alpha = 0.60;
            light.border_red = 0.0; light.border_green = 0.0; light.border_blue = 0.0;
            light.border_alpha = 0.06;
            light.indicator_red = 0.12; light.indicator_green = 0.12; light.indicator_blue = 0.14;
            light.indicator_alpha = 0.90;
            themes.set(light.id, light);

            // Transparent
            var trans = new Theme("transparent", "Transparent");
            trans.bg_alpha = 0.25;
            trans.border_alpha = 0.12;
            themes.set(trans.id, trans);
        }

        private void scan_themes() {
            scan_directory(themes_dir);
            scan_directory(user_themes_dir);
        }

        // Add the theme described by <dir>/theme.ini, if there is one
        private bool load_theme_dir(string dir) {
            var theme_file = Path.build_filename(dir, "theme.ini");
            if (!FileUtils.test(theme_file, FileTest.EXISTS)) return false;
            var theme = new Theme.from_file(theme_file);
            themes.set(theme.id, theme);
            return true;
        }

        private void scan_directory(string dir) {
            try {
                var directory = Dir.open(dir);
                string? name;
                while ((name = directory.read_name()) != null) {
                    load_theme_dir(Path.build_filename(dir, name));
                }
            } catch (Error e) {
                // Expected if directory doesn't exist yet
            }
        }

        public Theme? get_theme(string id) {
            return themes.get(id);
        }

        public List<weak Theme> get_all_themes() {
            return themes.get_values();
        }

        public bool install_theme(string zip_path) {
            string dest;
            if (!FileUtil.install_zip(zip_path, user_themes_dir, out dest)) {
                return false;
            }

            if (load_theme_dir(dest)) return true;
            warning("Theme zip had no valid theme.ini: %s", zip_path);
            return false;
        }
    }
}
