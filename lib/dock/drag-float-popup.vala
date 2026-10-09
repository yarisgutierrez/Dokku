namespace Dokku {
    // Called while dragging; returns 0..1 of how far the cursor is past the remove threshold.
    public delegate double RemoveProgressFunc();

    // Drag-to-remove floating icon. A small transparent overlay window that
    // follows the cursor across the entire screen, so the icon stays visible
    // outside the dock bounds, then dissolves ("poof") when dropped.
    public class DragFloatPopup : GLib.Object {
        private const int POOF_DURATION_MS = 300;

        private Gtk.Window? popup = null;
        private Gdk.Pixbuf? icon = null;
        private int64 poof_start_time = 0;
        private RemoveProgressFunc? progress = null;

        // True while the popup is playing the dissolve animation.
        public bool is_poofing { get; private set; default = false; }
        public bool is_active { get { return popup != null; } }

        // Returns false if no icon could be loaded (nothing is shown).
        public bool show(DockItem item, int icon_size, bool light, bool host_layer_shell,
                         owned RemoveProgressFunc progress_func) {
            // Cancel any running poof before starting a new drag
            destroy();
            this.progress = (owned) progress_func;

            // Cache icon pixbuf
            icon = IconLoader.load(item.icon_name, icon_size);
            if (icon == null) {
                this.progress = null;
                return false;
            }

            is_poofing = false;

            // Popup: large enough for the scaled icon + "Remove" label
            int popup_size = (int)(icon_size * 1.8);
            popup = new Gtk.Window(Gtk.WindowType.POPUP);
            popup.set_type_hint(Gdk.WindowTypeHint.DND);
            popup.set_skip_taskbar_hint(true);
            popup.set_skip_pager_hint(true);
            popup.set_decorated(false);
            popup.set_resizable(false);
            var vis = popup.get_screen().get_rgba_visual();
            if (vis != null) popup.set_visual(vis);
            popup.set_app_paintable(true);
            popup.set_size_request(popup_size, popup_size);
            popup.resize(popup_size, popup_size);

            // Single draw handler: switches between drag and poof modes
            popup.draw.connect((cr) => {
                cr.set_operator(Cairo.Operator.SOURCE);
                cr.set_source_rgba(0, 0, 0, 0);
                cr.paint();
                cr.set_operator(Cairo.Operator.OVER);
                if (icon == null) return false;

                if (popup == null) return false;
                int w = popup.get_allocated_width();
                int h = popup.get_allocated_height();
                double icon_w = icon.get_width();
                double icon_h = icon.get_height();

                if (is_poofing) {
                    // Poof mode: scale up + fade out
                    int64 now = GLib.get_monotonic_time() / 1000;
                    double t = ((double)(now - poof_start_time)) / POOF_DURATION_MS;
                    if (t >= 1.0) return false;

                    double ease_t = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t);
                    double anim_scale = 1.0 + 0.5 * ease_t;
                    double alpha = 1.0 - ease_t;

                    cr.save();
                    cr.translate(w / 2.0, h / 2.0);
                    cr.scale(anim_scale, anim_scale);
                    cr.translate(-icon_w / 2.0, -icon_h / 2.0);
                    Gdk.cairo_set_source_pixbuf(cr, icon, 0, 0);
                    cr.paint_with_alpha(alpha);
                    cr.restore();
                } else {
                    // Drag mode: shrink + fade + "Remove" label
                    double remove_t = progress != null ? progress() : 0.0;
                    double scale = 1.05 - 0.45 * remove_t;
                    double alpha = 0.85 - 0.45 * remove_t;

                    cr.save();
                    cr.translate(w / 2.0, h / 2.0);
                    cr.scale(scale, scale);
                    cr.translate(-icon_w / 2.0, -icon_h / 2.0);
                    Gdk.cairo_set_source_pixbuf(cr, icon, 0, 0);
                    cr.paint_with_alpha(alpha);
                    cr.restore();

                    // "Remove" label above the icon
                    cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
                    cr.set_font_size(11);
                    Cairo.TextExtents te;
                    cr.text_extents("Remove", out te);
                    double lx = (w - te.width) / 2.0;
                    double ly = (h / 2.0) - (icon_h * scale / 2.0) - 6;

                    cr.move_to(lx + 1, ly + 1);
                    cr.set_source_rgba(0, 0, 0, 0.6);
                    cr.show_text("Remove");
                    cr.move_to(lx, ly);
                    if (light) {
                        cr.set_source_rgba(0.15, 0.15, 0.15, 0.9);
                    } else {
                        cr.set_source_rgba(1, 1, 1, 0.9);
                    }
                    cr.show_text("Remove");
                }

                return false;
            });

            popup.show_all();
            // X11: override_redirect + suppress compositor shadow
            var popup_gdk = popup.get_window();
            if (!host_layer_shell && popup_gdk != null) {
                popup_gdk.set_override_redirect(true);
                CompositorHints.apply(popup_gdk, false);
            }

            return true;
        }

        public void move_to(double root_x, double root_y) {
            if (popup == null) return;
            int popup_size = popup.get_allocated_width();
            int px = (int)(root_x - popup_size / 2.0);
            int py = (int)(root_y - popup_size / 2.0);
            popup.move(px, py);
            popup.queue_draw();
        }

        public void destroy() {
            is_poofing = false;
            if (popup != null) {
                popup.destroy();
                popup = null;
            }
            icon = null;
            progress = null;
        }

        // Transition the floating popup into poof mode (scale-up + fade-out)
        public void poof() {
            if (popup == null || icon == null) {
                destroy();
                return;
            }
            is_poofing = true;
            poof_start_time = GLib.get_monotonic_time() / 1000;

            // Capture start time locally so a hypothetical second poof
            // can't corrupt this animation's timeline
            int64 local_start = poof_start_time;

            popup.add_tick_callback((widget, frame_clock) => {
                int64 now = GLib.get_monotonic_time() / 1000;
                double t = ((double)(now - local_start)) / POOF_DURATION_MS;
                if (t >= 1.0) {
                    destroy();
                    return false;
                }
                if (popup != null) {
                    popup.queue_draw();
                }
                return true;
            });
        }
    }
}
