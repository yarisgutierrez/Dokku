namespace Dokku {
    public class WindowManager : Object {
        private Wnck.Screen? screen = null;
        private HashTable<unowned Wnck.Window, ulong> state_handlers;
        private HashTable<unowned Wnck.Window, ulong> geometry_handlers;

        public signal void windows_changed();
        public signal void active_changed();
        public signal void attention_requested(Wnck.Window window);
        public signal void window_geometry_changed();

        // The one place that asks libwnck for its screen, so the X11-only check and the
        // deprecated call (Wnck.Handle needs libwnck 43, newer than Debian 12 and
        // Ubuntu 22.04 ship) are not repeated. Null wherever libwnck cannot work.
        public static unowned Wnck.Screen? default_screen() {
            if (!Capabilities.current.supports(Feature.WINDOW_TRACKING)) return null;
            return Wnck.Screen.get_default();
        }

        public WindowManager() {
            screen = default_screen();
            state_handlers = new HashTable<unowned Wnck.Window, ulong>(direct_hash, direct_equal);
            geometry_handlers = new HashTable<unowned Wnck.Window, ulong>(direct_hash, direct_equal);
            if (screen != null) {
                screen.window_opened.connect(on_window_opened);
                screen.window_closed.connect(on_window_closed);
                screen.active_window_changed.connect(on_active_changed);
            }
        }

        private void on_active_changed(Wnck.Window? prev) {
            active_changed();
        }

        ~WindowManager() {
            // Disconnect all remaining state_changed handlers from tracked windows
            state_handlers.foreach((window, handler_id) => {
                window.disconnect(handler_id);
            });
            state_handlers.remove_all();

            geometry_handlers.foreach((window, handler_id) => {
                window.disconnect(handler_id);
            });
            geometry_handlers.remove_all();

            // Disconnect screen signals
            if (screen != null) {
                screen.window_opened.disconnect(on_window_opened);
                screen.window_closed.disconnect(on_window_closed);
                screen.active_window_changed.disconnect(on_active_changed);
            }
        }

        private void on_window_opened(Wnck.Window window) {
            ulong state_id = window.state_changed.connect((changed_mask, new_state) => {
                if ((new_state & Wnck.WindowState.DEMANDS_ATTENTION) != 0 ||
                    (new_state & Wnck.WindowState.URGENT) != 0) {
                    attention_requested(window);
                }
                // Detect maximize/unmaximize transitions
                if ((changed_mask & Wnck.WindowState.MAXIMIZED_HORIZONTALLY) != 0 ||
                    (changed_mask & Wnck.WindowState.MAXIMIZED_VERTICALLY) != 0) {
                    window_geometry_changed();
                }
            });
            state_handlers.set(window, state_id);

            ulong geo_id = window.geometry_changed.connect(() => {
                window_geometry_changed();
            });
            geometry_handlers.set(window, geo_id);

            windows_changed();
        }

        private void on_window_closed(Wnck.Window window) {
            if (state_handlers.contains(window)) {
                window.disconnect(state_handlers.get(window));
                state_handlers.remove(window);
            }
            if (geometry_handlers.contains(window)) {
                window.disconnect(geometry_handlers.get(window));
                geometry_handlers.remove(window);
            }
            windows_changed();
            window_geometry_changed();
        }

        public List<weak Wnck.Window> get_windows() {
            var windows = new List<weak Wnck.Window>();
            if (screen == null) return windows;
            foreach (var window in screen.get_windows()) {
                if (!window.is_skip_tasklist()) {
                    windows.append(window);
                }
            }
            return windows;
        }

        public void activate_window(Wnck.Window window) {
            window.activate(Gtk.get_current_event_time());
        }

        public Wnck.Window? get_active_window() {
            if (screen == null) return null;
            return screen.get_active_window();
        }
    }
}
