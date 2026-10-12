[CCode (cheader_filename = "wayland/toplevel-tracker.h")]
namespace Dokku.Wl {
    [CCode (cname = "DokkuToplevelEvent", cprefix = "DOKKU_TOPLEVEL_")]
    public enum ToplevelEvent {
        ADDED,
        CHANGED,
        CLOSED
    }

    [Flags, CCode (cname = "guint32", cprefix = "DOKKU_TOPLEVEL_STATE_")]
    public enum ToplevelState {
        MAXIMIZED,
        MINIMIZED,
        ACTIVATED,
        FULLSCREEN
    }

    [CCode (has_target = false, cname = "DokkuToplevelFunc")]
    public delegate void ToplevelFunc (ToplevelEvent event, Toplevel toplevel, void* data);

    [Compact, CCode (cname = "DokkuToplevel", free_function = "")]
    public class Toplevel {
        [CCode (cname = "dokku_toplevel_get_title")]
        public unowned string get_title ();
        [CCode (cname = "dokku_toplevel_get_app_id")]
        public unowned string get_app_id ();
        [CCode (cname = "dokku_toplevel_get_state")]
        public ToplevelState get_state ();
        [CCode (cname = "dokku_toplevel_is_on_output_at")]
        public bool is_on_output_at (int x, int y);
        [CCode (cname = "dokku_toplevel_activate")]
        public void activate ();
        [CCode (cname = "dokku_toplevel_close")]
        public void close ();
        [CCode (cname = "dokku_toplevel_set_minimized")]
        public void set_minimized (bool minimized);
    }

    [Compact, CCode (cname = "DokkuToplevelTracker", free_function = "dokku_toplevel_tracker_free")]
    public class ToplevelTracker {
        [CCode (cname = "dokku_toplevel_tracker_new")]
        public static ToplevelTracker? create (ToplevelFunc func, void* data);
    }
}
