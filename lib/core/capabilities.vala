namespace Dokku {
    public enum SessionType {
        X11,
        WAYLAND,
        UNKNOWN;

        public string to_label() {
            switch (this) {
                case X11: return "X11";
                case WAYLAND: return "Wayland";
                default: return "Unknown";
            }
        }
    }

    // Things that only work in some sessions.
    public enum Feature {
        WINDOW_TRACKING,   // seeing open windows: running indicators, previews, attention bounce
        GLOBAL_HOTKEYS,    // system-wide keyboard shortcuts
        COMPOSITOR_BLUR,   // frosted-glass backdrop
        DODGE_WINDOWS      // hide when a window overlaps (needs window tracking)
    }

    // What the current display session can do. Dokku runs on X11 and on Wayland
    // (via layer-shell); a few features depend on X11-only libraries (libwnck,
    // keybinder), so the rest of the code asks here instead of checking the
    // session itself, and the UI can say *why* something is unavailable.
    public class Capabilities : GLib.Object {
        public SessionType session { get; private set; }
        public bool layer_shell { get; private set; }
        // The compositor lists windows to clients (wlr-foreign-toplevel-management)
        public bool window_list { get; private set; }

        public Capabilities(SessionType session, bool layer_shell, bool window_list = false) {
            this.session = session;
            this.layer_shell = layer_shell;
            this.window_list = window_list;
        }

        public bool supports(Feature feature) {
            switch (feature) {
                case WINDOW_TRACKING:
                case DODGE_WINDOWS:
                    // X11 has libwnck; Wayland has it only where the compositor lists windows
                    return session == SessionType.X11 ||
                           (session == SessionType.WAYLAND && window_list);
                default:
                    // Hotkeys (keybinder) and blur (picom) depend on X11
                    return session == SessionType.X11;
            }
        }

        // Human-readable reason a feature is unavailable, or null if it is available.
        public string? why_not(Feature feature) {
            if (supports(feature)) return null;
            bool wayland = session == SessionType.WAYLAND;
            switch (feature) {
                case WINDOW_TRACKING:
                case DODGE_WINDOWS:
                    return wayland ? "Not available here: this Wayland compositor does not list windows (no wlr-foreign-toplevel-management)"
                                   : "Needs an X11 session";
                case GLOBAL_HOTKEYS:
                    return wayland ? "Not available on Wayland. Bind a key in your compositor to run \"dokku --launcher\""
                                   : "Needs an X11 session";
                case COMPOSITOR_BLUR:
                    return wayland ? "Not available on Wayland yet" : "Needs an X11 session";
                default:
                    return "Not available in this session";
            }
        }

        public string describe() {
            if (session == SessionType.WAYLAND)
                return layer_shell ? "Wayland (layer-shell)" : "Wayland (no layer-shell)";
            return session.to_label();
        }

        // --- Detection ---

        private static Capabilities? _current = null;

        // Detected once, after GTK has opened the display.
        public static Capabilities current {
            get {
                if (_current == null) _current = detect();
                return _current;
            }
        }

        public static Capabilities detect() {
            var display = Gdk.Display.get_default();
            SessionType type = SessionType.UNKNOWN;
            if (display is Gdk.X11.Display) {
                type = SessionType.X11;
            } else if (display != null && display.get_type().name() == "GdkWaylandDisplay") {
                type = SessionType.WAYLAND;
            }
            bool window_list = false;
#if HAVE_WAYLAND_TRACKER
            window_list = type == SessionType.WAYLAND && WaylandWindows.get_default() != null;
#endif
            return new Capabilities(type, type == SessionType.WAYLAND && GtkLayerShell.is_supported(), window_list);
        }
    }
}
