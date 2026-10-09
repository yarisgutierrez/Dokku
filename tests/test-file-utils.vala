namespace Dokku.Tests {
    public class FileUtilTests : GLib.Object {
        public static void register() {
            Test.add_func("/file-utils/validate/clean-tree", validate_clean_tree);
            Test.add_func("/file-utils/validate/rejects-symlink", validate_rejects_symlink);
            Test.add_func("/file-utils/validate/rejects-nested-symlink", validate_rejects_nested_symlink);
            Test.add_func("/file-utils/validate/missing-dir", validate_missing_dir);
            Test.add_func("/file-utils/delete/removes-tree", delete_removes_tree);
            Test.add_func("/file-utils/delete/does-not-follow-symlinks", delete_ignores_symlink_target);
            Test.add_func("/file-utils/install-zip/good-archive", install_good_zip);
            Test.add_func("/file-utils/install-zip/rejects-symlink-archive", install_rejects_symlink_zip);
        }

        private static void validate_clean_tree() {
            string dir = Support.make_tmp_dir();
            Support.write_file(Path.build_filename(dir, "a.txt"), "a");
            Support.write_file(Path.build_filename(dir, "sub", "deep", "b.txt"), "b");
            assert_true(FileUtil.validate_extracted_paths(dir));
            Support.remove_tree(dir);
        }

        private static void validate_rejects_symlink() {
            string dir = Support.make_tmp_dir();
            Support.write_file(Path.build_filename(dir, "a.txt"), "a");
            FileUtils.symlink("/etc", Path.build_filename(dir, "escape"));
            assert_false(FileUtil.validate_extracted_paths(dir));
            Support.remove_tree(dir);
        }

        private static void validate_rejects_nested_symlink() {
            string dir = Support.make_tmp_dir();
            Support.write_file(Path.build_filename(dir, "sub", "ok.txt"), "ok");
            FileUtils.symlink("/etc/passwd", Path.build_filename(dir, "sub", "link"));
            assert_false(FileUtil.validate_extracted_paths(dir));
            Support.remove_tree(dir);
        }

        private static void validate_missing_dir() {
            assert_false(FileUtil.validate_extracted_paths("/nonexistent/dokku-test-dir"));
        }

        private static void delete_removes_tree() {
            string dir = Support.make_tmp_dir();
            Support.write_file(Path.build_filename(dir, "t", "a.txt"), "a");
            Support.write_file(Path.build_filename(dir, "t", "sub", "b.txt"), "b");
            try {
                FileUtil.recursive_delete(Path.build_filename(dir, "t"));
            } catch (Error e) {
                Test.fail();
            }
            assert_false(FileUtils.test(Path.build_filename(dir, "t"), FileTest.EXISTS));
            Support.remove_tree(dir);
        }

        // Deleting a tree must never reach through a symlink and delete its target.
        private static void delete_ignores_symlink_target() {
            string dir = Support.make_tmp_dir();
            string outside = Path.build_filename(dir, "outside");
            string precious = Path.build_filename(outside, "precious.txt");
            Support.write_file(precious, "keep me");

            string victim = Path.build_filename(dir, "victim");
            Support.write_file(Path.build_filename(victim, "a.txt"), "a");
            FileUtils.symlink(outside, Path.build_filename(victim, "link"));

            try {
                FileUtil.recursive_delete(victim);
            } catch (Error e) {
                Test.fail();
            }
            assert_false(FileUtils.test(victim, FileTest.EXISTS));
            assert_true(FileUtils.test(precious, FileTest.EXISTS));

            Support.remove_tree(dir);
        }

        private static bool tools_available() {
            return Environment.find_program_in_path("zip") != null
                && Environment.find_program_in_path("unzip") != null;
        }

        private static void make_zip(string src_dir, string zip_path) {
            try {
                string[] argv = {"zip", "-q", "-r", "-y", zip_path, "."};
                int status;
                Process.spawn_sync(src_dir, argv, null, SpawnFlags.SEARCH_PATH,
                                   null, null, null, out status);
                assert_cmpint(status, CompareOperator.EQ, 0);
            } catch (Error e) {
                Test.fail();
            }
        }

        private static void install_good_zip() {
            if (!tools_available()) { Test.skip("zip/unzip not installed"); return; }
            string dir = Support.make_tmp_dir();
            string src = Path.build_filename(dir, "src");
            Support.write_file(Path.build_filename(src, "theme.ini"), "[Theme]\nname=Z\n");
            Support.write_file(Path.build_filename(src, "sub", "x.txt"), "x");
            string zip = Path.build_filename(dir, "goodtheme.zip");
            make_zip(src, zip);

            string dest_dir = Path.build_filename(dir, "installed");
            string dest;
            assert_true(FileUtil.install_zip(zip, dest_dir, out dest));
            assert_cmpstr(dest, CompareOperator.EQ, Path.build_filename(dest_dir, "goodtheme"));
            assert_true(FileUtils.test(Path.build_filename(dest, "theme.ini"), FileTest.EXISTS));
            assert_true(FileUtils.test(Path.build_filename(dest, "sub", "x.txt"), FileTest.EXISTS));

            Support.remove_tree(dir);
        }

        // A zip carrying a symlink could point outside the install dir; it must be
        // rejected and the half-installed files removed.
        private static void install_rejects_symlink_zip() {
            if (!tools_available()) { Test.skip("zip/unzip not installed"); return; }
            string dir = Support.make_tmp_dir();
            string src = Path.build_filename(dir, "src");
            Support.write_file(Path.build_filename(src, "theme.ini"), "[Theme]\nname=Evil\n");
            FileUtils.symlink("/etc", Path.build_filename(src, "escape"));
            string zip = Path.build_filename(dir, "eviltheme.zip");
            make_zip(src, zip);

            Test.expect_message(null, LogLevelFlags.LEVEL_WARNING, "*path traversal*");
            string dest_dir = Path.build_filename(dir, "installed");
            string dest;
            assert_false(FileUtil.install_zip(zip, dest_dir, out dest));
            assert_false(FileUtils.test(dest, FileTest.EXISTS));
            Test.assert_expected_messages();

            Support.remove_tree(dir);
        }
    }
}
