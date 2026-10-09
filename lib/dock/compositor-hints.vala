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
    }
}
