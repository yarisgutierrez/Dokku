namespace Dokku {
    // A window the Wayland compositor lists through wlr-foreign-toplevel-management.
    // Everything is copied out of the protocol object on each update, so a window that
    // has just closed can still be read.
    public class WaylandWindow : TrackedWindow {
        internal unowned Wl.Toplevel? handle;
        private string _title = "";
        private string _app_id = "";
        private Wl.ToplevelState state = 0;

        internal WaylandWindow(Wl.Toplevel handle) {
            this.handle = handle;
            refresh();
        }

        // Copy the current values out of the protocol object
        internal void refresh() {
            if (handle == null) return;
            _title = handle.get_title();
            _app_id = handle.get_app_id();
            state = handle.get_state();
        }

        public bool is_active { get { return (state & Wl.ToplevelState.ACTIVATED) != 0; } }

        public override string title { owned get { return _title; } }
        public override string app_id { owned get { return _app_id; } }
        public override bool is_minimized { get { return (state & Wl.ToplevelState.MINIMIZED) != 0; } }
        public override bool is_maximized { get { return (state & Wl.ToplevelState.MAXIMIZED) != 0; } }
        public override bool is_fullscreen { get { return (state & Wl.ToplevelState.FULLSCREEN) != 0; } }

        // Wayland tells clients which outputs a window is on but not where it is on them,
        // so "the same monitor" is decided by the output's origin in the layout.
        public override bool is_on_monitor(Gdk.Rectangle monitor) {
            return handle != null && handle.is_on_output_at(monitor.x, monitor.y);
        }

        public override void activate() {
            if (handle == null) return;
            if (is_minimized) handle.set_minimized(false);
            handle.activate();
        }

        public override void close() {
            if (handle != null) handle.close();
        }

        internal void minimize(bool minimized) {
            if (handle != null) handle.set_minimized(minimized);
        }
    }

    // The compositor's window list, shared by every dock in the process
    public class WaylandWindows : Object {
        private static WaylandWindows? instance = null;
        private static bool tried = false;

        // Null where there is no Wayland connection or the compositor can't list windows
        public static unowned WaylandWindows? get_default() {
            if (!tried) {
                tried = true;
                var windows = new WaylandWindows();
                if (windows.tracker != null) instance = windows;
            }
            return instance;
        }

        private Wl.ToplevelTracker? tracker;
        private HashTable<void*, WaylandWindow> windows;
        private WaylandWindow? active = null;
        private List<WaylandWindow> hidden_by_show_desktop = new List<WaylandWindow>();

        public signal void windows_changed();
        public signal void active_changed();
        // Anything about a window changed that the dodge check cares about
        public signal void window_state_changed();

        private WaylandWindows() {
            windows = new HashTable<void*, WaylandWindow>(direct_hash, direct_equal);
            tracker = Wl.ToplevelTracker.create(on_event, this);
        }

        private static void on_event(Wl.ToplevelEvent event, Wl.Toplevel toplevel, void* data) {
            unowned WaylandWindows self = (WaylandWindows) data;
            self.handle_event(event, toplevel);
        }

        private void handle_event(Wl.ToplevelEvent event, Wl.Toplevel toplevel) {
            void* key = (void*) toplevel;
            switch (event) {
                case Wl.ToplevelEvent.ADDED:
                    windows.set(key, new WaylandWindow(toplevel));
                    update_active();
                    windows_changed();
                    window_state_changed();
                    break;
                case Wl.ToplevelEvent.CHANGED:
                    var changed = windows.get(key);
                    if (changed == null) break;
                    changed.refresh();
                    update_active();
                    // A title or app_id change can alter which app a window belongs to
                    windows_changed();
                    window_state_changed();
                    break;
                case Wl.ToplevelEvent.CLOSED:
                    var closed = windows.get(key);
                    if (closed == null) break;
                    closed.handle = null;
                    hidden_by_show_desktop.remove(closed);
                    windows.remove(key);
                    update_active();
                    windows_changed();
                    window_state_changed();
                    break;
            }
        }

        private void update_active() {
            WaylandWindow? now = null;
            foreach (var w in windows.get_values()) {
                if (w.is_active) now = w;
            }
            if (now != active) {
                active = now;
                active_changed();
            }
        }

        public List<weak WaylandWindow> get_windows() {
            var result = new List<weak WaylandWindow>();
            foreach (var w in windows.get_values()) {
                // Dokku's own windows (launcher, settings) are not apps to show as running
                if (!w.is_dokku_window()) result.append(w);
            }
            return result;
        }

        public unowned WaylandWindow? get_active() {
            return active;
        }

        // Wayland has no "show desktop" request: minimize what is open, and bring back
        // exactly those windows the next time.
        public void toggle_showing_desktop(bool show) {
            if (show) {
                foreach (var w in get_windows()) {
                    if (w.is_minimized || !w.is_application_window) continue;
                    hidden_by_show_desktop.append(w);
                    w.minimize(true);
                }
            } else {
                foreach (var w in hidden_by_show_desktop) {
                    w.minimize(false);
                }
                hidden_by_show_desktop = new List<WaylandWindow>();
            }
        }
    }
}
