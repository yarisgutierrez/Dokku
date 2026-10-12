namespace Dokku {
    // The dock's view of the windows that are open. On X11 they come from libwnck; on
    // Wayland from the compositor's foreign-toplevel list (see wayland-windows.vala).
    public class WindowManager : Object {
        private Wnck.Screen? screen = null;
        private HashTable<unowned Wnck.Window, WnckWindow> wnck_windows;
        private HashTable<unowned Wnck.Window, ulong> state_handlers;
        private HashTable<unowned Wnck.Window, ulong> geometry_handlers;
#if HAVE_WAYLAND_TRACKER
        private unowned WaylandWindows? wayland = null;
#endif

        public signal void windows_changed();
        public signal void active_changed();
        // Only ever emitted on X11: Wayland has no attention request to report
        public signal void attention_requested(TrackedWindow window);
        public signal void window_geometry_changed();

        // The one place that asks libwnck for its screen, so the X11-only check and the
        // deprecated call (Wnck.Handle needs libwnck 43, newer than Debian 12 and
        // Ubuntu 22.04 ship) are not repeated. Null wherever libwnck cannot work.
        public static unowned Wnck.Screen? default_screen() {
            if (Capabilities.current.session != SessionType.X11) return null;
            return Wnck.Screen.get_default();
        }

        public WindowManager() {
            wnck_windows = new HashTable<unowned Wnck.Window, WnckWindow>(direct_hash, direct_equal);
            state_handlers = new HashTable<unowned Wnck.Window, ulong>(direct_hash, direct_equal);
            geometry_handlers = new HashTable<unowned Wnck.Window, ulong>(direct_hash, direct_equal);

            screen = default_screen();
            if (screen != null) {
                screen.window_opened.connect(on_window_opened);
                screen.window_closed.connect(on_window_closed);
                screen.active_window_changed.connect(on_active_changed);
                return;
            }
#if HAVE_WAYLAND_TRACKER
            if (Capabilities.current.session == SessionType.WAYLAND) {
                wayland = WaylandWindows.get_default();
                if (wayland != null) {
                    wayland.windows_changed.connect(on_wayland_windows_changed);
                    wayland.active_changed.connect(on_wayland_active_changed);
                    wayland.window_state_changed.connect(on_wayland_state_changed);
                }
            }
#endif
        }

        private void on_active_changed(Wnck.Window? prev) {
            active_changed();
        }

#if HAVE_WAYLAND_TRACKER
        private void on_wayland_windows_changed() { windows_changed(); }
        private void on_wayland_active_changed() { active_changed(); }
        private void on_wayland_state_changed() { window_geometry_changed(); }
#endif

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
#if HAVE_WAYLAND_TRACKER
            if (wayland != null) {
                wayland.windows_changed.disconnect(on_wayland_windows_changed);
                wayland.active_changed.disconnect(on_wayland_active_changed);
                wayland.window_state_changed.disconnect(on_wayland_state_changed);
            }
#endif
        }

        private WnckWindow wrap(Wnck.Window window) {
            var wrapped = wnck_windows.get(window);
            if (wrapped == null) {
                wrapped = new WnckWindow(window);
                wnck_windows.set(window, wrapped);
            }
            return wrapped;
        }

        private void on_window_opened(Wnck.Window window) {
            ulong state_id = window.state_changed.connect((changed_mask, new_state) => {
                if ((new_state & Wnck.WindowState.DEMANDS_ATTENTION) != 0 ||
                    (new_state & Wnck.WindowState.URGENT) != 0) {
                    attention_requested(wrap(window));
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
            // Listeners rebuild their lists from get_windows(), which no longer has it
            windows_changed();
            window_geometry_changed();
            wnck_windows.remove(window);
        }

        public List<weak TrackedWindow> get_windows() {
            var windows = new List<weak TrackedWindow>();
            if (screen != null) {
                foreach (var window in screen.get_windows()) {
                    if (!window.is_skip_tasklist()) {
                        windows.append(wrap(window));
                    }
                }
            }
#if HAVE_WAYLAND_TRACKER
            if (wayland != null) {
                foreach (var window in wayland.get_windows()) {
                    windows.append(window);
                }
            }
#endif
            return windows;
        }

        public void activate_window(TrackedWindow window) {
            window.activate();
        }

        public TrackedWindow? get_active_window() {
            if (screen != null) {
                var active = screen.get_active_window();
                return active != null ? wrap(active) : null;
            }
#if HAVE_WAYLAND_TRACKER
            if (wayland != null) return wayland.get_active();
#endif
            return null;
        }

        // Minimizes every window, or brings back the ones it minimized. False when the
        // session can't do it.
        public static bool toggle_showing_desktop(bool show) {
            var wnck_screen = default_screen();
            if (wnck_screen != null) {
                wnck_screen.toggle_showing_desktop(show);
                return true;
            }
#if HAVE_WAYLAND_TRACKER
            var windows = WaylandWindows.get_default();
            if (windows != null) {
                windows.toggle_showing_desktop(show);
                return true;
            }
#endif
            return false;
        }
    }
}
