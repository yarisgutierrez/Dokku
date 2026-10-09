namespace Dokku {
    // Returns the dock capsule's corner radius (0 when corners are square).
    public delegate double CornerRadiusFunc();

    /**
     * Two-window blur approach:
     *
     * Problem: A single bounding shape cannot both (a) restrict picom blur
     * to the dock capsule and (b) allow magnified icons to extend above it.
     * Extending the shape for magnification causes picom to blur that area,
     * creating a visible rectangle artifact.
     *
     * Solution: Use a SEPARATE transparent popup window (the backdrop) positioned
     * behind the main dock at the capsule location. This window:
     * - Has _DOKKU_BLUR atom → picom blurs behind it
     * - Has a rounded-rect bounding shape matching the capsule
     * - Is transparent → blurred desktop shows through
     *
     * The main dock window has NO bounding shape and NO blur atom, so:
     * - Magnified icons extend freely (no clipping)
     * - Picom does NOT blur behind the main dock
     * - The semi-transparent dock background lets the blurred desktop
     *   (from the backdrop below) show through → frosted glass effect
     *
     * Compositing order: desktop → blur (capsule area) → backdrop → main dock
     */
    public class BlurBackdrop : GLib.Object {
        private Gtk.Window dock;
        private CornerRadiusFunc? corner_radius;
        private Gtk.Window? window = null;

        // Cached shape dimensions to avoid re-creating the surface on every size_allocate
        private int shape_w = 0;
        private int shape_h = 0;
        private double shape_radius = -1;

        // The backdrop window was just created and should be positioned.
        public signal void created();

        public bool is_active { get { return window != null; } }

        public BlurBackdrop(Gtk.Window dock, owned CornerRadiusFunc corner_radius) {
            this.dock = dock;
            this.corner_radius = (owned) corner_radius;
        }

        // Create or destroy the backdrop window to match `enabled`.
        public void set_enabled(bool enabled) {
            if (enabled && window == null) {
                create();
            } else if (!enabled && window != null) {
                destroy_window();
            }
        }

        // Drop the window and our reference back to the dock (dock being destroyed).
        public void shutdown() {
            destroy_window();
            corner_radius = null;
        }

        private void destroy_window() {
            if (window == null) return;
            window.destroy();
            window = null;
            shape_w = 0;
            shape_h = 0;
            shape_radius = -1;
        }

        private void create() {
            window = new Gtk.Window(Gtk.WindowType.POPUP);
            var visual = window.get_screen().get_rgba_visual();
            if (visual != null) window.set_visual(visual);
            window.set_app_paintable(true);
            window.set_decorated(false);
            window.set_skip_taskbar_hint(true);
            window.set_skip_pager_hint(true);
            window.set_accept_focus(false);
            window.set_type_hint(Gdk.WindowTypeHint.DOCK);

            window.draw.connect((cr) => {
                // Transparent — compositor blur shows through this window.
                cr.set_operator(Cairo.Operator.SOURCE);
                cr.set_source_rgba(0, 0, 0, 0);
                cr.paint();
                return true;
            });

            window.realize.connect(() => {
                if (window == null) return;
                var bgw = window.get_window();
                if (bgw == null) return;
                bgw.set_override_redirect(true);
                CompositorHints.apply(bgw, true);
                apply_shape();
            });

            window.map.connect(() => {
                if (window == null) return;
                var bgw = window.get_window();
                if (bgw == null) return;
                CompositorHints.apply(bgw, true);
                apply_shape();
                // Main dock must stay above the blur background
                var main_w = dock.get_window();
                if (main_w != null) main_w.raise();
            });

            window.size_allocate.connect(() => {
                apply_shape();
            });

            window.set_default_size(1, 1);
            window.show_all();
            // Let the dock position us immediately
            created();
        }

        /**
         * Apply a rounded-rectangle bounding shape to the blur background
         * window so picom only blurs behind the dock capsule shape.
         */
        public void apply_shape() {
            if (window == null) return;
            var bgw = window.get_window();
            if (bgw == null) return;

            int w = window.get_allocated_width();
            int h = window.get_allocated_height();
            if (w <= 1 || h <= 1) return;

            double radius = corner_radius != null ? corner_radius() : 0;

            // Skip if dimensions and radius haven't changed
            if (w == shape_w && h == shape_h && radius == shape_radius) return;
            shape_w = w;
            shape_h = h;
            shape_radius = radius;

            var surface = new Cairo.ImageSurface(Cairo.Format.A8, w, h);
            var cr = new Cairo.Context(surface);
            cr.set_operator(Cairo.Operator.SOURCE);
            cr.set_source_rgba(0, 0, 0, 0);
            cr.paint();
            cr.set_source_rgba(0, 0, 0, 1);
            DockRenderer.draw_rounded_rect(cr, 0, 0, w, h, radius);
            cr.fill();
            surface.flush();

            var region = Gdk.cairo_region_create_from_surface(surface);
            bgw.shape_combine_region(region, 0, 0);
        }

        /**
         * Position and resize the blur background window to match the dock
         * capsule area. Takes the actual dock_dim (which changes during
         * magnification) so the blur area grows/shrinks with the capsule.
         */
        public void sync(int dock_x, int dock_y, int dock_w, int dock_h, double dock_dim,
                         string dock_position, int icon_area_height) {
            if (window == null) return;

            double margin = 2;
            int bg_x, bg_y, bg_w, bg_h;

            if (dock_position == "bottom") {
                bg_w = (int)(dock_dim - margin * 2);
                bg_h = icon_area_height;
                bg_x = dock_x + (dock_w - (int)dock_dim) / 2 + (int)margin;
                bg_y = dock_y + dock_h - icon_area_height - (int)margin;
            } else if (dock_position == "top") {
                bg_w = (int)(dock_dim - margin * 2);
                bg_h = icon_area_height;
                bg_x = dock_x + (dock_w - (int)dock_dim) / 2 + (int)margin;
                bg_y = dock_y + (int)margin;
            } else if (dock_position == "left") {
                bg_w = icon_area_height;
                bg_h = (int)(dock_dim - margin * 2);
                bg_x = dock_x + (int)margin;
                bg_y = dock_y + (dock_h - (int)dock_dim) / 2 + (int)margin;
            } else { // right
                bg_w = icon_area_height;
                bg_h = (int)(dock_dim - margin * 2);
                bg_x = dock_x + dock_w - icon_area_height - (int)margin;
                bg_y = dock_y + (dock_h - (int)dock_dim) / 2 + (int)margin;
            }

            bg_w = int.max(bg_w, 1);
            bg_h = int.max(bg_h, 1);

            // Only call resize/move if values actually changed — avoids
            // recreating the X11 bounding shape 60 times/sec during hover
            int cur_w = window.get_allocated_width();
            int cur_h = window.get_allocated_height();
            int cur_x, cur_y;
            window.get_position(out cur_x, out cur_y);

            if (cur_w != bg_w || cur_h != bg_h) {
                window.resize(bg_w, bg_h);
            }
            if (cur_x != bg_x || cur_y != bg_y) {
                window.move(bg_x, bg_y);
            }
        }
    }
}
