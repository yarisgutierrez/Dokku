namespace Dokku {
    // A name for a monitor that survives restarts, so per-monitor settings can be kept for it.
    //
    // GTK gives a make and model (on X11 the model is the output name, such as DP-2) and a
    // size. Two identical monitors look the same, so they are told apart by where they are.
    // A name is the make, the model and the size, for example "DEL DP-2 3440x1440".
    public class MonitorKey : Object {
        private static bool is_unknown(string? s) {
            return s == null || s.strip() == "" || s.strip() == "Unknown";
        }

        // The name before duplicates are told apart
        public static string compose(string? maker, string? model, int width, int height) {
            var parts = new StringBuilder();
            if (!is_unknown(maker)) parts.append(maker.strip()).append_c(' ');
            if (!is_unknown(model)) parts.append(model.strip()).append_c(' ');
            if (parts.len == 0) parts.append("monitor ");
            parts.append("%dx%d".printf(width, height));
            // The name becomes a section name in the settings file
            string key = parts.str.replace("[", "(").replace("]", ")").replace("\n", " ");
            if (key.char_count() > 80) key = key.substring(0, key.index_of_nth_char(80));
            return key;
        }

        // Monitors with the same base name get " #1", " #2"... in order of position (left to
        // right, then top to bottom). A name that is alone stays as it is.
        public static string[] disambiguate(string[] bases, int[] xs, int[] ys) {
            string[] result = new string[bases.length];
            for (int i = 0; i < bases.length; i++) {
                int same = 0;
                int before = 0;
                for (int j = 0; j < bases.length; j++) {
                    if (bases[j] != bases[i]) continue;
                    same++;
                    if (xs[j] < xs[i] || (xs[j] == xs[i] && ys[j] < ys[i]) ||
                        (xs[j] == xs[i] && ys[j] == ys[i] && j < i)) {
                        before++;
                    }
                }
                result[i] = same > 1 ? "%s #%d".printf(bases[i], before + 1) : bases[i];
            }
            return result;
        }

        // One name per monitor of the display, in the display's order
        public static string[] all(Gdk.Display display) {
            int n = display.get_n_monitors();
            string[] bases = new string[n];
            int[] xs = new int[n];
            int[] ys = new int[n];
            for (int i = 0; i < n; i++) {
                var monitor = display.get_monitor(i);
                var geometry = monitor.get_geometry();
                bases[i] = compose(monitor.get_manufacturer(), monitor.get_model(),
                                   geometry.width, geometry.height);
                xs[i] = geometry.x;
                ys[i] = geometry.y;
            }
            return disambiguate(bases, xs, ys);
        }

        // The name of one monitor, or "" when it is not on the display
        public static string for_monitor(Gdk.Display display, Gdk.Monitor? monitor) {
            if (monitor == null) return "";
            string[] names = all(display);
            for (int i = 0; i < names.length; i++) {
                if (display.get_monitor(i) == monitor) return names[i];
            }
            return "";
        }

        // What to call a monitor in the settings window
        public static string label(Gdk.Display display, int index) {
            var monitor = display.get_monitor(index);
            var geometry = monitor.get_geometry();
            var parts = new StringBuilder();
            string? maker = monitor.get_manufacturer();
            string? model = monitor.get_model();
            if (!is_unknown(model)) {
                if (!is_unknown(maker)) parts.append(maker.strip()).append_c(' ');
                parts.append(model.strip());
            } else {
                parts.append("Monitor %d".printf(index + 1));
            }
            return "%s (%d×%d)".printf(parts.str, geometry.width, geometry.height);
        }
    }
}
