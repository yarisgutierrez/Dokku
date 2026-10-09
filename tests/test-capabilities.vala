namespace Dokku.Tests {
    public class CapabilitiesTests : GLib.Object {
        private static Feature[] all_features = {
            Feature.WINDOW_TRACKING, Feature.GLOBAL_HOTKEYS,
            Feature.COMPOSITOR_BLUR, Feature.DODGE_WINDOWS
        };

        public static void register() {
            Test.add_func("/capabilities/x11-supports-everything", x11);
            Test.add_func("/capabilities/wayland-explains-each-gap", wayland);
            Test.add_func("/capabilities/unknown-session-supports-nothing", unknown);
            Test.add_func("/capabilities/describe", describe);
        }

        private static void x11() {
            var caps = new Capabilities(SessionType.X11, false);
            foreach (var f in all_features) {
                assert_true(caps.supports(f));
                assert_null(caps.why_not(f));
            }
        }

        private static void wayland() {
            var caps = new Capabilities(SessionType.WAYLAND, true);
            foreach (var f in all_features) {
                assert_false(caps.supports(f));
                string? reason = caps.why_not(f);
                assert_nonnull(reason);
                assert_true(reason.length > 0);
            }
            // The hotkey message tells the user what to do instead
            assert_true(caps.why_not(Feature.GLOBAL_HOTKEYS).contains("dokku --launcher"));
        }

        private static void unknown() {
            var caps = new Capabilities(SessionType.UNKNOWN, false);
            foreach (var f in all_features) {
                assert_false(caps.supports(f));
                assert_nonnull(caps.why_not(f));
            }
        }

        private static void describe() {
            assert_cmpstr(new Capabilities(SessionType.X11, false).describe(), CompareOperator.EQ, "X11");
            assert_cmpstr(new Capabilities(SessionType.WAYLAND, true).describe(),
                          CompareOperator.EQ, "Wayland (layer-shell)");
            assert_cmpstr(new Capabilities(SessionType.WAYLAND, false).describe(),
                          CompareOperator.EQ, "Wayland (no layer-shell)");
            assert_cmpstr(new Capabilities(SessionType.UNKNOWN, false).describe(),
                          CompareOperator.EQ, "Unknown");
        }
    }
}
