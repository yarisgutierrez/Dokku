namespace Dokku.Tests {
    public class ThemeTests : GLib.Object {
        public static void register() {
            Test.add_func("/theme/from-file/full", full_theme);
            Test.add_func("/theme/from-file/partial-keeps-defaults", partial_theme);
            Test.add_func("/theme/from-file/missing-name-falls-back", missing_name);
            Test.add_func("/theme/from-file/missing-file-falls-back", missing_file);
            Test.add_func("/theme/from-file/missing-sections-keep-name-and-rest", missing_sections);
            Test.add_func("/theme/from-file/clamps-out-of-range", clamps);
            Test.add_func("/theme/from-file/ignores-non-numeric", non_numeric);
            Test.add_func("/theme/is-light", is_light);
        }

        private static void assert_near(double actual, double expected) {
            assert_true(Math.fabs(actual - expected) < 1e-9);
        }

        private static void full_theme() {
            string dir = Support.make_tmp_dir();
            string path = Path.build_filename(dir, "midnight", "theme.ini");
            Support.write_file(path,
                "[Theme]\nname=Midnight\n" +
                "[Background]\nred=0.1\ngreen=0.2\nblue=0.3\nalpha=0.4\n" +
                "[Border]\nred=0.5\ngreen=0.6\nblue=0.7\nalpha=0.8\n" +
                "[Indicator]\nred=0.9\ngreen=0.8\nblue=0.7\nalpha=0.6\n" +
                "[Style]\ncorner_radius=20\nborder_width=2\n");

            var theme = new Theme.from_file(path);
            // The id is the name of the directory that holds theme.ini
            assert_cmpstr(theme.id, CompareOperator.EQ, "midnight");
            assert_cmpstr(theme.name, CompareOperator.EQ, "Midnight");
            assert_near(theme.bg_red, 0.1);
            assert_near(theme.bg_green, 0.2);
            assert_near(theme.bg_blue, 0.3);
            assert_near(theme.bg_alpha, 0.4);
            assert_near(theme.border_alpha, 0.8);
            assert_near(theme.indicator_red, 0.9);
            assert_near(theme.corner_radius, 20);
            assert_near(theme.border_width, 2);

            Support.remove_tree(dir);
        }

        private static void partial_theme() {
            string dir = Support.make_tmp_dir();
            string path = Path.build_filename(dir, "sparse", "theme.ini");
            Support.write_file(path, "[Theme]\nname=Sparse\n[Background]\nred=0.9\n");

            var theme = new Theme.from_file(path);
            assert_cmpstr(theme.name, CompareOperator.EQ, "Sparse");
            assert_near(theme.bg_red, 0.9);
            // Everything not in the file keeps its default
            assert_near(theme.bg_green, 0.12);
            assert_near(theme.bg_alpha, 0.55);
            assert_near(theme.corner_radius, 16);
            assert_near(theme.border_width, 1);

            Support.remove_tree(dir);
        }

        private static void missing_name() {
            string dir = Support.make_tmp_dir();
            string path = Path.build_filename(dir, "noname", "theme.ini");
            Support.write_file(path, "[Background]\nred=0.9\n");

            var theme = new Theme.from_file(path);
            assert_cmpstr(theme.name, CompareOperator.EQ, "noname");

            Support.remove_tree(dir);
        }

        private static void missing_file() {
            var theme = new Theme.from_file("/nonexistent/ghost/theme.ini");
            assert_cmpstr(theme.id, CompareOperator.EQ, "ghost");
            assert_cmpstr(theme.name, CompareOperator.EQ, "ghost");
        }

        // A theme that omits whole sections must still keep its name and the
        // values it does define, including ones in sections after the gap.
        private static void missing_sections() {
            string dir = Support.make_tmp_dir();
            string path = Path.build_filename(dir, "gappy", "theme.ini");
            Support.write_file(path,
                "[Theme]\nname=Gappy\n[Background]\nred=0.7\n[Style]\ncorner_radius=30\n");

            var theme = new Theme.from_file(path);
            assert_cmpstr(theme.name, CompareOperator.EQ, "Gappy");
            assert_near(theme.bg_red, 0.7);
            assert_near(theme.corner_radius, 30);
            // No [Border] / [Indicator] sections: defaults
            assert_near(theme.border_alpha, 0.08);
            assert_near(theme.indicator_alpha, 0.4);

            Support.remove_tree(dir);
        }

        private static void clamps() {
            string dir = Support.make_tmp_dir();
            string path = Path.build_filename(dir, "extreme", "theme.ini");
            Support.write_file(path,
                "[Theme]\nname=Extreme\n[Background]\nred=5\ngreen=-3\nalpha=2\n" +
                "[Style]\ncorner_radius=9999\nborder_width=-1\n");

            var theme = new Theme.from_file(path);
            assert_near(theme.bg_red, 1.0);
            assert_near(theme.bg_green, 0.0);
            assert_near(theme.bg_alpha, 1.0);
            assert_near(theme.corner_radius, 100.0);
            assert_near(theme.border_width, 0.0);

            Support.remove_tree(dir);
        }

        private static void non_numeric() {
            string dir = Support.make_tmp_dir();
            string path = Path.build_filename(dir, "garbled", "theme.ini");
            Support.write_file(path,
                "[Theme]\nname=Garbled\n[Background]\nred=banana\ngreen=0.4\n");

            var theme = new Theme.from_file(path);
            assert_cmpstr(theme.name, CompareOperator.EQ, "Garbled");
            assert_near(theme.bg_red, 0.12);   // default kept
            assert_near(theme.bg_green, 0.4);  // later keys still read

            Support.remove_tree(dir);
        }

        private static void is_light() {
            var theme = new Theme("t", "T");
            theme.bg_red = 1.0; theme.bg_green = 1.0; theme.bg_blue = 1.0;
            assert_true(theme.is_light());

            theme.bg_red = 0.12; theme.bg_green = 0.12; theme.bg_blue = 0.12;
            assert_false(theme.is_light());

            // Perceived luminance, not a plain average: pure green reads as light,
            // pure blue as dark.
            theme.bg_red = 0; theme.bg_green = 1.0; theme.bg_blue = 0;
            assert_true(theme.is_light());
            theme.bg_red = 0; theme.bg_green = 0; theme.bg_blue = 1.0;
            assert_false(theme.is_light());
        }
    }
}
