namespace Dokku.Tests {
    public class ConfigTests : GLib.Object {
        public static void register() {
            Test.add_func("/config/defaults", defaults);
            Test.add_func("/config/persists-across-instances", persists);
            Test.add_func("/config/clamps-out-of-range-values", clamps);
            Test.add_func("/config/pinned-apps-roundtrip", pinned_roundtrip);
            Test.add_func("/config/file-permissions", file_permissions);
            Test.add_func("/config/batch-mode-defers-writes", batch_mode);
            Test.add_func("/config/hidden-apps", hidden_apps);
            Test.add_func("/config/hidden-apps-cache-invalidated", hidden_cache);
            Test.add_func("/config/folders/create-and-query", folder_create);
            Test.add_func("/config/folders/apps", folder_apps);
            Test.add_func("/config/folders/ordering", folder_ordering);
            Test.add_func("/config/folders/delete", folder_delete);
            Test.add_func("/config/folders/rejects-invalid-ids", folder_invalid_ids);
            Test.add_func("/config/custom-icons", custom_icons);
        }

        private static ConfigManager fresh() {
            Support.reset_config();
            return new ConfigManager();
        }

        private static void defaults() {
            var c = fresh();
            assert_cmpstr(c.get_position(), CompareOperator.EQ, "bottom");
            assert_cmpint(c.get_icon_size(), CompareOperator.EQ, 48);
            assert_false(c.get_auto_hide());
            assert_true(Math.fabs(c.get_magnification() - 1.5) < 1e-9);
            assert_cmpint(c.get_pinned_apps().length, CompareOperator.EQ, 3);
            assert_cmpint(c.get_hidden_apps().length, CompareOperator.EQ, 0);
            assert_cmpint(c.get_folder_ids().length, CompareOperator.EQ, 0);
            assert_null(c.get_custom_icon("anything"));
        }

        private static void persists() {
            var c = fresh();
            c.set_icon_size(64);
            c.set_position("left");
            c.set_auto_hide(true);

            // A new instance reads what the first one wrote to disk
            var again = new ConfigManager();
            assert_cmpint(again.get_icon_size(), CompareOperator.EQ, 64);
            assert_cmpstr(again.get_position(), CompareOperator.EQ, "left");
            assert_true(again.get_auto_hide());
        }

        private static void clamps() {
            var c = fresh();
            c.set_icon_size(500);
            assert_cmpint(c.get_icon_size(), CompareOperator.EQ, 128);
            c.set_icon_size(2);
            assert_cmpint(c.get_icon_size(), CompareOperator.EQ, 16);

            c.set_magnification(9.0);
            assert_true(Math.fabs(c.get_magnification() - 3.0) < 1e-9);
            c.set_magnification(0.2);
            assert_true(Math.fabs(c.get_magnification() - 1.0) < 1e-9);
        }

        private static void pinned_roundtrip() {
            var c = fresh();
            c.set_pinned_apps({"firefox", "folder:work", "org.gnome.Terminal"});
            var pinned = new ConfigManager().get_pinned_apps();
            assert_cmpint(pinned.length, CompareOperator.EQ, 3);
            // Order is preserved, including folder entries
            assert_cmpstr(pinned[0], CompareOperator.EQ, "firefox");
            assert_cmpstr(pinned[1], CompareOperator.EQ, "folder:work");
            assert_cmpstr(pinned[2], CompareOperator.EQ, "org.gnome.Terminal");
        }

        private static void file_permissions() {
            var c = fresh();
            c.set_icon_size(40);
            Posix.Stat st;
            assert_cmpint(Posix.stat(Support.config_file(), out st), CompareOperator.EQ, 0);
            // The config can name private launch commands: owner-only
            assert_cmpint((int)(st.st_mode & 0777), CompareOperator.EQ, 0600);
            // And no temp file is left behind by the atomic write
            assert_false(FileUtils.test(Support.config_file() + ".tmp", FileTest.EXISTS));
        }

        private static void batch_mode() {
            var c = fresh();
            c.begin_batch();
            c.set_icon_size(77);
            c.set_position("top");
            assert_false(FileUtils.test(Support.config_file(), FileTest.EXISTS));

            c.end_batch();
            assert_true(FileUtils.test(Support.config_file(), FileTest.EXISTS));
            var again = new ConfigManager();
            assert_cmpint(again.get_icon_size(), CompareOperator.EQ, 77);
            assert_cmpstr(again.get_position(), CompareOperator.EQ, "top");
        }

        private static void hidden_apps() {
            var c = fresh();
            c.hide_app("a");
            c.hide_app("b");
            c.hide_app("a");  // already hidden: no duplicate
            assert_cmpint(c.get_hidden_apps().length, CompareOperator.EQ, 2);
            assert_true(c.is_app_hidden("a"));
            assert_true(c.is_app_hidden("b"));
            assert_false(c.is_app_hidden("c"));

            c.unhide_app("a");
            assert_cmpint(c.get_hidden_apps().length, CompareOperator.EQ, 1);
            assert_false(c.is_app_hidden("a"));
            assert_true(c.is_app_hidden("b"));
        }

        // is_app_hidden() builds a lookup set lazily. Changing the list must drop it,
        // or hiding/unhiding would appear to do nothing until restart.
        private static void hidden_cache() {
            var c = fresh();
            assert_false(c.is_app_hidden("x"));   // builds the (empty) cache
            c.hide_app("x");
            assert_true(c.is_app_hidden("x"));    // stale cache would say false
            c.set_hidden_apps({});
            assert_false(c.is_app_hidden("x"));
        }

        private static void folder_create() {
            var c = fresh();
            c.create_folder("work", "Work", {"firefox", "slack"});
            assert_cmpint(c.get_folder_ids().length, CompareOperator.EQ, 1);
            assert_cmpstr(c.get_folder_ids()[0], CompareOperator.EQ, "work");
            assert_cmpstr(c.get_folder_name("work"), CompareOperator.EQ, "Work");
            assert_cmpint(c.get_folder_apps("work").length, CompareOperator.EQ, 2);
            // Unknown folder falls back to a generic name
            assert_cmpstr(c.get_folder_name("nope"), CompareOperator.EQ, "Folder");

            // Creating the same id again updates it instead of duplicating
            c.create_folder("work", "Work 2", {"firefox"});
            assert_cmpint(c.get_folder_ids().length, CompareOperator.EQ, 1);
            assert_cmpstr(c.get_folder_name("work"), CompareOperator.EQ, "Work 2");
        }

        private static void folder_apps() {
            var c = fresh();
            c.create_folder("f", "F", {"a"});
            c.add_app_to_folder("f", "b");
            c.add_app_to_folder("f", "b");  // duplicate ignored
            assert_cmpint(c.get_folder_apps("f").length, CompareOperator.EQ, 2);
            assert_cmpstr(c.get_app_folder("b"), CompareOperator.EQ, "f");
            assert_null(c.get_app_folder("zzz"));

            c.remove_app_from_folder("f", "a");
            assert_cmpint(c.get_folder_apps("f").length, CompareOperator.EQ, 1);
            assert_null(c.get_app_folder("a"));

            c.rename_folder("f", "Renamed");
            assert_cmpstr(c.get_folder_name("f"), CompareOperator.EQ, "Renamed");
        }

        private static string join(string[] parts) {
            return string.joinv(",", parts);
        }

        private static void folder_ordering() {
            var c = fresh();
            c.create_folder("f1", "1", {});
            c.create_folder("f2", "2", {});
            c.create_folder("f3", "3", {});
            assert_cmpstr(join(c.get_folder_ids()), CompareOperator.EQ, "f1,f2,f3");

            c.move_folder_to_position("f3", 0);
            assert_cmpstr(join(c.get_folder_ids()), CompareOperator.EQ, "f3,f1,f2");
            c.move_folder_to_position("f3", 1);
            assert_cmpstr(join(c.get_folder_ids()), CompareOperator.EQ, "f1,f3,f2");
            // Positions outside the list clamp to the ends
            c.move_folder_to_position("f1", 99);
            assert_cmpstr(join(c.get_folder_ids()), CompareOperator.EQ, "f3,f2,f1");
            c.move_folder_to_position("f1", -5);
            assert_cmpstr(join(c.get_folder_ids()), CompareOperator.EQ, "f1,f3,f2");
        }

        private static void folder_delete() {
            var c = fresh();
            c.create_folder("f1", "1", {"a"});
            c.create_folder("f2", "2", {"b"});
            c.delete_folder("f1");
            assert_cmpstr(join(c.get_folder_ids()), CompareOperator.EQ, "f2");
            // Its settings group is gone, not just its id
            assert_cmpint(c.get_folder_apps("f1").length, CompareOperator.EQ, 0);
            assert_null(c.get_app_folder("a"));
        }

        // Folder ids become key-file group names; anything that could break out of
        // that (separators, brackets, newlines, huge strings) is refused.
        private static void folder_invalid_ids() {
            var c = fresh();
            string[] bad = {"", "has space", "bad]id", "new\nline", "semi;colon", "slash/id",
                            string.nfill(65, 'a')};
            foreach (var id in bad) {
                Test.expect_message(null, LogLevelFlags.LEVEL_WARNING, "*Invalid folder ID*");
                c.create_folder(id, "Nope", {});
            }
            Test.assert_expected_messages();
            assert_cmpint(c.get_folder_ids().length, CompareOperator.EQ, 0);

            // Valid characters are accepted
            c.create_folder("ok_id-1", "Fine", {});
            assert_cmpint(c.get_folder_ids().length, CompareOperator.EQ, 1);
        }

        private static void custom_icons() {
            var c = fresh();
            assert_null(c.get_custom_icon("app"));
            c.set_custom_icon("app", "my-icon");
            assert_cmpstr(c.get_custom_icon("app"), CompareOperator.EQ, "my-icon");
            assert_cmpstr(new ConfigManager().get_custom_icon("app"), CompareOperator.EQ, "my-icon");
            c.clear_custom_icon("app");
            assert_null(c.get_custom_icon("app"));
        }
    }
}
