namespace Dokku {
    // Shared construction/painting for the dock's themed popup windows.
    public class PopupHelper : GLib.Object {
        public static Gtk.Window create_window(Gdk.WindowTypeHint hint = Gdk.WindowTypeHint.POPUP_MENU) {
            var popup = new Gtk.Window(Gtk.WindowType.POPUP);
            popup.set_type_hint(hint);
            popup.set_skip_taskbar_hint(true);
            popup.set_skip_pager_hint(true);
            popup.set_decorated(false);
            popup.set_resizable(false);
            var vis = popup.get_screen().get_rgba_visual();
            if (vis != null) popup.set_visual(vis);
            popup.set_app_paintable(true);
            return popup;
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
    }
}
