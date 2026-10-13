namespace Dokku {
    // X11 properties that let compositor rules (picom) target Dokku windows.
    public class CompositorHints : GLib.Object {
        /**
         * - _DOKKU_WINDOW = 1: identifies a Dokku window for picom rule matching
         *   (reliable for override_redirect windows where class_g may fail)
         * - _COMPTON_SHADOW = 0: disable compositor shadow
         * - _DOKKU_BLUR: set when `blur` is true, removed otherwise; picom
         *   matches on _DOKKU_BLUR@ existence and re-evaluates via PropertyNotify
         *
         * No-op on non-X11 displays.
         */
        public static void apply(Gdk.Window gdk_window, bool blur) {
            var display = gdk_window.get_display();
            if (!(display is Gdk.X11.Display)) return;

            unowned X.Display xdisplay = ((Gdk.X11.Display) display).get_xdisplay();
            X.Window xid = ((Gdk.X11.Window) gdk_window).get_xid();

            X.Atom dock_atom = xdisplay.intern_atom("_DOKKU_WINDOW", false);
            uchar[] dock_val = { 1, 0, 0, 0 };
            xdisplay.change_property(xid, dock_atom, X.XA_CARDINAL, 32,
                                      X.PropMode.Replace, dock_val, 1);

            X.Atom shadow_atom = xdisplay.intern_atom("_COMPTON_SHADOW", false);
            uchar[] shadow_off = { 0, 0, 0, 0 };
            xdisplay.change_property(xid, shadow_atom, X.XA_CARDINAL, 32,
                                      X.PropMode.Replace, shadow_off, 1);

            X.Atom blur_atom = xdisplay.intern_atom("_DOKKU_BLUR", false);
            if (blur) {
                uchar[] blur_on = { 1, 0, 0, 0 };
                xdisplay.change_property(xid, blur_atom, X.XA_CARDINAL, 32,
                                          X.PropMode.Replace, blur_on, 1);
            } else {
                xdisplay.delete_property(xid, blur_atom);
            }

            xdisplay.flush();
        }

        /**
         * Sets the window's opacity through _NET_WM_WINDOW_OPACITY so the
         * compositor does the blending. Unlike GtkWidget:opacity, which makes
         * GTK repaint the whole window with a new alpha each frame, this
         * costs the client nothing and sends the compositor no damage.
         * Returns false (and does nothing) on non-X11 displays.
         */
        public static bool set_window_opacity(Gdk.Window gdk_window, double opacity) {
            var display = gdk_window.get_display();
            if (!(display is Gdk.X11.Display)) return false;

            unowned X.Display xdisplay = ((Gdk.X11.Display) display).get_xdisplay();
            X.Window xid = ((Gdk.X11.Window) gdk_window).get_xid();
            X.Atom atom = xdisplay.intern_atom("_NET_WM_WINDOW_OPACITY", false);

            if (opacity >= 1.0) {
                xdisplay.delete_property(xid, atom);
            } else {
                uint32 v = (uint32) (double.max(0.0, opacity) * 4294967295.0);
                // Xlib reads a long per 32-bit item, so give it 8 bytes
                uchar[] val = {
                    (uchar) (v & 0xff), (uchar) ((v >> 8) & 0xff),
                    (uchar) ((v >> 16) & 0xff), (uchar) ((v >> 24) & 0xff),
                    0, 0, 0, 0
                };
                xdisplay.change_property(xid, atom, X.XA_CARDINAL, 32,
                                          X.PropMode.Replace, val, 1);
            }
            xdisplay.flush();
            return true;
        }
    }
}
