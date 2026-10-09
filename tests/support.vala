namespace Dokku.Tests {
    public class Support : GLib.Object {
        public static string make_tmp_dir() {
            try {
                return DirUtils.make_tmp("dokku-test-XXXXXX");
            } catch (Error e) {
                error("could not create temp dir: %s", e.message);
            }
        }

        public static void write_file(string path, string content) {
            DirUtils.create_with_parents(Path.get_dirname(path), 0755);
            try {
                FileUtils.set_contents(path, content);
            } catch (Error e) {
                error("could not write %s: %s", path, e.message);
            }
        }

        public static void remove_tree(string path) {
            try {
                FileUtil.recursive_delete(path);
            } catch (Error e) {
                warning("cleanup of %s failed: %s", path, e.message);
            }
        }

        // The runner sets HOME to a throwaway directory; this is the config file
        // ConfigManager will use. Tests start from a clean slate.
        public static string config_file() {
            return Path.build_filename(Environment.get_home_dir(), ".config", "dokku", "config.ini");
        }

        public static void reset_config() {
            FileUtils.remove(config_file());
            FileUtils.remove(config_file() + ".tmp");
        }
    }
}
