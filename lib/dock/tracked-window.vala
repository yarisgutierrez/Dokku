namespace Dokku {
    // A window the dock knows about, whichever way it was found: through libwnck on X11
    // or through the compositor's foreign-toplevel protocol on Wayland. The dock only
    // talks to this, so it doesn't care which session it is in.
    public abstract class TrackedWindow : Object {
        public abstract string title { owned get; }
        // X11 class group, or the Wayland app_id: what the window calls its application
        public abstract string app_id { owned get; }
        public virtual string class_instance { owned get { return ""; } }
        public virtual string application_name { owned get { return app_id; } }

        public abstract bool is_minimized { get; }
        public abstract bool is_maximized { get; }
        public virtual bool is_fullscreen { get { return false; } }
        // An ordinary window (not a desktop, dock, panel or menu)
        public virtual bool is_application_window { get { return true; } }

        // Position and size on screen; false where the session does not say
        public virtual bool get_geometry(out Gdk.Rectangle rect) {
            rect = Gdk.Rectangle();
            return false;
        }

        // Whether the window is on the monitor that has this geometry
        public abstract bool is_on_monitor(Gdk.Rectangle monitor);

        // 0 where unknown (Wayland does not tell clients other windows' PIDs)
        public virtual int get_pid() { return 0; }

        public abstract void activate();
        public abstract void close();
        public abstract void minimize();

        public bool is_dokku_window() {
            return app_id.down() == "org.dokku.app";
        }
    }

    // A window libwnck reports (X11)
    public class WnckWindow : TrackedWindow {
        public Wnck.Window window { get; private set; }

        public WnckWindow(Wnck.Window window) {
            this.window = window;
        }

        public override string title { owned get { return window.get_name(); } }
        public override string app_id { owned get { return window.get_class_group_name() ?? ""; } }
        public override string class_instance { owned get { return window.get_class_instance_name() ?? ""; } }
        public override string application_name {
            owned get {
                var app = window.get_application();
                return app != null ? app.get_name() : "";
            }
        }

        public override bool is_minimized { get { return window.is_minimized(); } }
        public override bool is_maximized { get { return window.is_maximized(); } }
        public override bool is_fullscreen { get { return window.is_fullscreen(); } }

        public override bool is_application_window {
            get {
                var type = window.get_window_type();
                return type == Wnck.WindowType.NORMAL ||
                       type == Wnck.WindowType.DIALOG ||
                       type == Wnck.WindowType.UTILITY;
            }
        }

        public override bool get_geometry(out Gdk.Rectangle rect) {
            int x, y, w, h;
            window.get_geometry(out x, out y, out w, out h);
            rect = Gdk.Rectangle() { x = x, y = y, width = w, height = h };
            return true;
        }

        public override bool is_on_monitor(Gdk.Rectangle monitor) {
            Gdk.Rectangle r;
            get_geometry(out r);
            int cx = r.x + r.width / 2;
            int cy = r.y + r.height / 2;
            return cx >= monitor.x && cx < monitor.x + monitor.width &&
                   cy >= monitor.y && cy < monitor.y + monitor.height;
        }

        public override int get_pid() { return window.get_pid(); }

        public override void activate() { window.activate(Gtk.get_current_event_time()); }
        public override void close() { window.close(Gtk.get_current_event_time()); }
        public override void minimize() { window.minimize(); }
    }
}
