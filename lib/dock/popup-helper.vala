namespace Dokku {
    public delegate void DismissFunc();
    public delegate void PointerFunc();

    // Shared construction/painting for the dock's themed popup windows.
    public class PopupHelper : GLib.Object {
        public static Gtk.Window create_window(Gdk.WindowTypeHint hint = Gdk.WindowTypeHint.POPUP_MENU,
                                               Gtk.Window? parent = null) {
            var popup = new Gtk.Window(Gtk.WindowType.POPUP);
            popup.set_type_hint(hint);
            popup.set_skip_taskbar_hint(true);
            popup.set_skip_pager_hint(true);
            popup.set_decorated(false);
            // Wayland positions a popup relative to its parent; without one it can't
            if (parent != null) popup.set_transient_for(parent);
            popup.set_resizable(false);
            var vis = popup.get_screen().get_rgba_visual();
            if (vis != null) popup.set_visual(vis);
            popup.set_app_paintable(true);
            return popup;
        }

        // Stop a timer and forget its id (a no-op when none is pending)
        public static void clear_source(ref uint id) {
            if (id == 0) return;
            Source.remove(id);
            id = 0;
        }

        // Colours every label in a popup for a light or dark background
        public static Gtk.CssProvider label_color(bool light) {
            var css = new Gtk.CssProvider();
            try {
                css.load_from_data(light ? "label { color: #1a1a1a; }" : "label { color: #ffffff; }");
            } catch (Error e) {}
            return css;
        }

        // Call `on_enter` / `on_leave` as the pointer enters or leaves the popup. Moves
        // between the popup and its own children are not reported.
        public static void watch_pointer(Gtk.Window popup, owned PointerFunc on_enter, owned PointerFunc on_leave) {
            popup.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK);
            popup.enter_notify_event.connect((ev) => {
                on_enter();
                return false;
            });
            popup.leave_notify_event.connect((ev) => {
                if (ev.detail != Gdk.NotifyType.INFERIOR) on_leave();
                return false;
            });
        }

        public static void draw_background(Cairo.Context cr, Gtk.Widget popup, Theme? theme_ref, double radius) {
            cr.set_operator(Cairo.Operator.SOURCE);
            cr.set_source_rgba(0, 0, 0, 0);
            cr.paint();
            cr.set_operator(Cairo.Operator.OVER);

            int w = popup.get_allocated_width();
            int h = popup.get_allocated_height();

            double r = 0.12, g = 0.12, b = 0.12;
            if (theme_ref != null) {
                r = theme_ref.bg_red; g = theme_ref.bg_green; b = theme_ref.bg_blue;
            }
            DockRenderer.draw_rounded_rect(cr, 0, 0, w, h, radius);
            cr.set_source_rgba(r, g, b, 0.92);
            cr.fill_preserve();

            if (theme_ref != null) {
                cr.set_source_rgba(theme_ref.border_red, theme_ref.border_green,
                                   theme_ref.border_blue, theme_ref.border_alpha);
            } else {
                cr.set_source_rgba(1, 1, 1, 0.1);
            }
            cr.set_line_width(1);
            cr.stroke();
        }

        // Grab the pointer and keyboard for `popup` so clicks elsewhere can close it.
        // With `show_in_grab` the popup is shown from inside the grab, which Wayland
        // needs (the grab must exist before the popup is mapped). Returns true if the
        // popup was shown that way.
        public static bool grab(Gtk.Window popup, bool show_in_grab) {
            var gdk_window = popup.get_window();
            if (gdk_window == null) return false;
            var seat = popup.get_display().get_default_seat();
            const Gdk.SeatCapabilities caps =
                Gdk.SeatCapabilities.POINTER | Gdk.SeatCapabilities.KEYBOARD;
            bool shown = false;
            Gdk.GrabStatus status;
            if (show_in_grab) {
                status = seat.grab(gdk_window, caps, true, null, null, (s, w) => {
                    popup.show_all();
                    shown = true;
                });
            } else {
                status = seat.grab(gdk_window, caps, true, null, null, null);
            }
            if (status != Gdk.GrabStatus.SUCCESS) {
                warning("Popup grab failed (%d); it will not close on outside clicks", (int) status);
            }
            return shown;
        }

        public static void ungrab(Gtk.Window popup) {
            popup.get_display().get_default_seat().ungrab();
        }

        // Call `on_dismiss` when the user clicks outside `popup` (X11), the compositor
        // dismisses it (Wayland), or Escape is pressed. Use together with a modal
        // show_popup().
        public static void connect_dismissal(Gtk.Window popup, owned DismissFunc on_dismiss) {
            popup.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.KEY_PRESS_MASK);
            popup.button_press_event.connect((ev) => {
                // Events redirected to the popup by the grab keep the *originating*
                // window's coordinates, and Wayland has no screen coordinates at all, so
                // ask GDK which of our windows the pointer is over instead. A click is
                // inside only if that window belongs to the popup; over the dock, or
                // over no window of ours, it is outside.
                var popup_window = popup.get_window();
                if (popup_window == null) return false;
                int wx, wy;
                var pointer = popup.get_display().get_default_seat().get_pointer();
                var under = pointer.get_window_at_position(out wx, out wy);
                bool inside = under != null && under.get_toplevel() == popup_window;
                if (!inside) {
                    on_dismiss();
                    return true;
                }
                return false;
            });
            popup.grab_broken_event.connect((ev) => {
                on_dismiss();
                return false;
            });
            // Wayland dismisses a grabbed popup by unmapping it (xdg_popup.popup_done)
            // without any other event, so the owner must hear about that too.
            popup.unmap_event.connect((ev) => {
                on_dismiss();
                return false;
            });
            popup.hide.connect(() => on_dismiss());
            popup.key_press_event.connect((ev) => {
                if (ev.keyval == Gdk.Key.Escape) {
                    on_dismiss();
                    return true;
                }
                return false;
            });
        }
    }
}
