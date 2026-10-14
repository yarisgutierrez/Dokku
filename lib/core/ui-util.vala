namespace Dokku {
    // Small drawing, monitor and input helpers shared by the dock, launcher and popups
    public class UiUtil : GLib.Object {
        // Fast start, smooth deceleration (t and the result run 0..1)
        public static double ease_out_cubic(double t) {
            double f = 1.0 - t;
            return 1.0 - f * f * f;
        }

        // Wipe a surface to fully transparent and go back to normal painting
        public static void clear(Cairo.Context cr) {
            cr.set_operator(Cairo.Operator.SOURCE);
            cr.set_source_rgba(0, 0, 0, 0);
            cr.paint();
            cr.set_operator(Cairo.Operator.OVER);
        }

        public static Gdk.Monitor primary_monitor() {
            var display = Gdk.Display.get_default();
            return display.get_primary_monitor() ?? display.get_monitor(0);
        }

        // Carries focus and startup notification to an application GLib launches
        public static AppLaunchContext? launch_context() {
            var display = Gdk.Display.get_default();
            return display != null ? display.get_app_launch_context() : null;
        }
    }
}
