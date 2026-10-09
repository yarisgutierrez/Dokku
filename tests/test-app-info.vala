namespace Dokku.Tests {
    public class AppInfoTests : GLib.Object {
        public static void register() {
            Test.add_func("/app-info/parses-desktop-file", parses_desktop_file);
            Test.add_func("/app-info/strips-exec-field-codes", strips_field_codes);
            Test.add_func("/app-info/category-mapping", category_mapping);
            Test.add_func("/app-info/no-display", no_display);
            Test.add_func("/app-info/missing-exec-falls-back", missing_exec);
            Test.add_func("/app-info/unreadable-file-falls-back", unreadable_file);
        }

        private static AppInfo load(string dir, string filename, string content) {
            string path = Path.build_filename(dir, filename);
            Support.write_file(path, content);
            return new AppInfo.from_desktop_file(path);
        }

        private static void parses_desktop_file() {
            string dir = Support.make_tmp_dir();
            var app = load(dir, "Firefox.desktop",
                "[Desktop Entry]\nType=Application\nName=Web Browser\nIcon=firefox\n" +
                "Exec=/usr/bin/Firefox --new-window %U\nCategories=Network;WebBrowser;\n");

            assert_cmpstr(app.id, CompareOperator.EQ, "Firefox");
            assert_cmpstr(app.name, CompareOperator.EQ, "Web Browser");
            assert_cmpstr(app.icon, CompareOperator.EQ, "firefox");
            // Lowercase copies are cached for matching windows to apps
            assert_cmpstr(app.id_lower, CompareOperator.EQ, "firefox");
            assert_cmpstr(app.name_lower, CompareOperator.EQ, "web browser");
            assert_cmpstr(app.exec_base, CompareOperator.EQ, "firefox");
            assert_false(app.no_display);

            Support.remove_tree(dir);
        }

        private static void strips_field_codes() {
            string dir = Support.make_tmp_dir();
            var app = load(dir, "viewer.desktop",
                "[Desktop Entry]\nName=Viewer\nIcon=x\nExec=viewer --flag %F %u %i\n");
            assert_cmpstr(app.exec, CompareOperator.EQ, "viewer --flag");
            assert_cmpstr(app.exec_base, CompareOperator.EQ, "viewer");
            Support.remove_tree(dir);
        }

        private static void category_mapping() {
            string dir = Support.make_tmp_dir();
            var editor = load(dir, "ed.desktop",
                "[Desktop Entry]\nName=Ed\nIcon=x\nExec=ed\nCategories=Utility;TextEditor;\n");
            assert_cmpstr(editor.display_category, CompareOperator.EQ, "Accessories");

            var game = load(dir, "game.desktop",
                "[Desktop Entry]\nName=Game\nIcon=x\nExec=game\nCategories=Game;ArcadeGame;\n");
            assert_cmpstr(game.display_category, CompareOperator.EQ, "Games");

            var odd = load(dir, "odd.desktop",
                "[Desktop Entry]\nName=Odd\nIcon=x\nExec=odd\nCategories=SomethingUnknown;\n");
            assert_cmpstr(odd.display_category, CompareOperator.EQ, "Other");

            var none = load(dir, "none.desktop", "[Desktop Entry]\nName=None\nIcon=x\nExec=none\n");
            assert_cmpstr(none.display_category, CompareOperator.EQ, "Other");

            Support.remove_tree(dir);
        }

        private static void no_display() {
            string dir = Support.make_tmp_dir();
            var hidden = load(dir, "hidden.desktop",
                "[Desktop Entry]\nName=Hidden\nIcon=x\nExec=hidden\nNoDisplay=true\n");
            assert_true(hidden.no_display);

            var shown = load(dir, "shown.desktop",
                "[Desktop Entry]\nName=Shown\nIcon=x\nExec=shown\nNoDisplay=false\n");
            assert_false(shown.no_display);
            Support.remove_tree(dir);
        }

        private static void missing_exec() {
            string dir = Support.make_tmp_dir();
            var app = load(dir, "broken.desktop", "[Desktop Entry]\nName=Broken\nIcon=x\n");
            // An entry without Exec can't be launched; it falls back to id-based defaults
            assert_cmpstr(app.name, CompareOperator.EQ, "broken");
            assert_cmpstr(app.icon, CompareOperator.EQ, "application-x-executable");
            assert_cmpstr(app.exec, CompareOperator.EQ, "");
            assert_cmpstr(app.exec_base, CompareOperator.EQ, "");
            Support.remove_tree(dir);
        }

        private static void unreadable_file() {
            var app = new AppInfo.from_desktop_file("/nonexistent/ghost.desktop");
            assert_cmpstr(app.id, CompareOperator.EQ, "ghost");
            assert_cmpstr(app.name, CompareOperator.EQ, "ghost");
            assert_cmpstr(app.exec, CompareOperator.EQ, "");
        }
    }
}
