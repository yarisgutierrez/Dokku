namespace Dokku {
    public class DockRenderer : Object {
        private Gtk.IconTheme icon_theme;
        private HashTable<string, Gdk.Pixbuf?> icon_cache;
        private HashTable<string, int64?> icon_access;
        private int64 access_counter = 0;
        private const uint MAX_CACHE_ENTRIES = 200;

        public int icon_size { get; set; default = 48; }
        public double magnification { get; set; default = 1.5; }
        public int spacing { get; set; default = 10; }
        public Theme? theme { get; set; default = null; }
        public AppManager? app_manager { get; set; default = null; }

        // Guard against invalid UTF-8 crashing Cairo (enters error state, drops ALL further drawing)
        private static string safe_text(string? text) {
            return TextUtil.sanitize(text);
        }

        // Safe wrappers: ensure Cairo NEVER receives invalid UTF-8
        private static void safe_show_text(Cairo.Context cr, string? text) {
            if (text == null || text == "") return;
            if (text.validate()) {
                cr.show_text(text);
            }
        }

        private static void safe_text_extents(Cairo.Context cr, string? text, out Cairo.TextExtents te) {
            te = Cairo.TextExtents();
            if (text == null || text == "" || !text.validate()) return;
            cr.text_extents(text, out te);
        }

        public DockRenderer() {
            icon_theme = Gtk.IconTheme.get_default();
            icon_cache = new HashTable<string, Gdk.Pixbuf?>(str_hash, str_equal);
            icon_access = new HashTable<string, int64?>(str_hash, str_equal);

            // Clear cache when icon theme changes
            icon_theme.changed.connect(() => {
                icon_cache.remove_all();
                icon_access.remove_all();
                access_counter = 0;
            });
        }

        private void evict_lru() {
            if (icon_cache.size() <= MAX_CACHE_ENTRIES) return;

            // Remove entries older than the midpoint threshold
            int target = (int)(MAX_CACHE_ENTRIES / 2);
            int64 threshold = access_counter - target;

            var to_evict = new GenericArray<string>();
            icon_access.foreach((key, val) => {
                if (val < threshold) {
                    to_evict.add(key);
                }
            });
            for (int i = 0; i < to_evict.length; i++) {
                icon_cache.remove(to_evict[i]);
                icon_access.remove(to_evict[i]);
            }
        }

        public void clear_icon_cache(string icon_name) {
            // Remove all sizes of this icon from cache
            var keys_to_remove = new List<string>();
            icon_cache.foreach((key, val) => {
                if (key.has_prefix(icon_name + "_")) {
                    keys_to_remove.append(key);
                }
            });
            foreach (var key in keys_to_remove) {
                icon_cache.remove(key);
                icon_access.remove(key);
            }
        }

        // Reusable key buffer to avoid per-frame string allocations
        private StringBuilder _key_buf = new StringBuilder.sized(128);

        public Gdk.Pixbuf? get_icon(string icon_name, int size) {
            bool is_symbolic = icon_name.has_suffix("-symbolic");

            // Build sized cache key without printf allocation
            _key_buf.truncate(0);
            _key_buf.append(icon_name);
            if (is_symbolic) {
                _key_buf.append(is_light_theme() ? "_light" : "_dark");
            }
            string base_key = _key_buf.str;
            _key_buf.append_c('_');
            _key_buf.append(size.to_string());
            string sized_key = _key_buf.str;

            if (icon_cache.contains(sized_key)) {
                access_counter++;
                icon_access.set(sized_key, access_counter);
                return icon_cache.get(sized_key);
            }

            // Load base pixbuf at fixed large size for quality
            int load_size = 96;
            Gdk.Pixbuf? base_pixbuf = null;

            if (icon_cache.contains(base_key)) {
                base_pixbuf = icon_cache.get(base_key);
            } else {
                // Symbolic icons are recoloured to suit the theme; everything else (theme
                // names, file paths, the fallback icon) goes through IconLoader.
                if (is_symbolic) {
                    try {
                        var info = Gtk.IconTheme.get_default().lookup_icon(icon_name, load_size, Gtk.IconLookupFlags.FORCE_SIZE);
                        if (info != null) {
                            var fg = Gdk.RGBA();
                            if (is_light_theme()) {
                                fg.red = 0.15f; fg.green = 0.15f; fg.blue = 0.15f; fg.alpha = 0.95f;
                            } else {
                                fg.red = 1.0f; fg.green = 1.0f; fg.blue = 1.0f; fg.alpha = 0.95f;
                            }
                            bool was_symbolic;
                            base_pixbuf = info.load_symbolic(fg, null, null, null, out was_symbolic);
                        }
                    } catch (Error e) {
                        // fall back to the plain icon below
                    }
                }
                if (base_pixbuf == null) {
                    base_pixbuf = IconLoader.load(icon_name, load_size);
                }
                access_counter++;
                icon_cache.set(base_key, base_pixbuf);
                icon_access.set(base_key, access_counter);
            }

            if (base_pixbuf == null) return null;

            if (base_pixbuf.get_width() == size) {
                return base_pixbuf;
            }

            // Scale and cache the result
            var scaled = base_pixbuf.scale_simple(size, size, Gdk.InterpType.BILINEAR);
            access_counter++;
            icon_cache.set(sized_key, scaled);
            icon_access.set(sized_key, access_counter);
            evict_lru();
            return scaled;
        }

        public void draw_item(Cairo.Context cr, DockItem item, double x, double y, double scale, bool item_hovered, double hover_x = -1, string position = "bottom") {
            bool vert = (position == "left" || position == "right");

            // Draw media widget
            if (item.is_media_widget && item.plugin is MediaPlugin) {
                var mp = item.plugin as MediaPlugin;
                if (vert) {
                    // Compact: album art at icon size for vertical docks
                    draw_media_compact(cr, mp, x, y, (int)(icon_size * scale), position, item_hovered);
                    return;
                }
                draw_media_widget(cr, mp, x, y, icon_size, item.dock_width_factor, item_hovered, hover_x, position);
                return;
            }

            // Draw folder icon
            if (item.is_folder && app_manager != null) {
                int size = (int)(icon_size * scale);
                draw_folder_icon(cr, item, x, y, size);
                return;
            }

            // Draw separator as a line, not an icon
            if (item.is_separator) {
                if (is_light_theme()) {
                    cr.set_source_rgba(0.15, 0.15, 0.15, 0.40);
                } else {
                    cr.set_source_rgba(1, 1, 1, 0.2);
                }
                cr.set_line_width(1.5);
                double line_len = icon_size;
                if (vert) {
                    cr.move_to(x - line_len / 2, y);
                    cr.line_to(x + line_len / 2, y);
                } else {
                    cr.move_to(x, y - line_len / 2);
                    cr.line_to(x, y + line_len / 2);
                }
                cr.stroke();
                return;
            }

            int size = (int)(icon_size * scale);

            // Bounce animation offset (bounce away from screen edge)
            if (item.is_bouncing) {
                int64 now = GLib.get_monotonic_time();
                double elapsed = (now - item.bounce_start_time) / 1000000.0;
                if (elapsed < 1.5) {
                    double damping = 1.0 - (elapsed / 1.5);
                    double bounce_offset = (double)icon_size * 0.4 * damping * Math.fabs(Math.sin(elapsed * 4.0 * Math.PI));
                    if (position == "bottom") y -= bounce_offset;
                    else if (position == "top") y += bounce_offset;
                    else if (position == "left") x += bounce_offset;
                    else x -= bounce_offset;  // right
                }
            }

            // Widget plugins - draw text instead of icon
            if (item.is_widget && item.plugin is ScriptPlugin) {
                var sp = item.plugin as ScriptPlugin;
                draw_widget_text(cr, sp.display_text, x, y, size);
                return;
            }

            // Get icon name - for plugins, get it fresh each time
            string icon_name = item.icon_name;
            if (item.is_plugin && item.plugin != null) {
                icon_name = item.plugin.icon;
            }

            var pixbuf = get_icon(icon_name, size);

            if (pixbuf != null) {
                double draw_x = x - size / 2.0;
                double draw_y = y - size / 2.0;

                if (item_hovered) {
                    // Brighten: draw icon then overlay white within icon shape
                    cr.push_group();
                    Gdk.cairo_set_source_pixbuf(cr, pixbuf, draw_x, draw_y);
                    cr.paint();
                    cr.set_operator(Cairo.Operator.ATOP);
                    cr.set_source_rgba(1, 1, 1, 0.18);
                    cr.paint();
                    cr.set_operator(Cairo.Operator.OVER);
                    cr.pop_group_to_source();
                    cr.paint();
                } else {
                    Gdk.cairo_set_source_pixbuf(cr, pixbuf, draw_x, draw_y);
                    cr.paint();
                }
            }

            // Running indicator dots (dark dots on light themes, light dots on dark themes)
            if (item.running) {
                if (theme != null) {
                    cr.set_source_rgba(theme.indicator_red, theme.indicator_green,
                                       theme.indicator_blue, theme.indicator_alpha);
                } else if (is_light_theme()) {
                    cr.set_source_rgba(0.12, 0.12, 0.14, 0.90);  // Charcoal
                } else {
                    cr.set_source_rgba(1, 1, 1, 0.4);
                }

                int window_count = (int)item.windows.length();
                int dots = int.min(window_count, 3);
                double dot_spacing = 5;

                for (int i = 0; i < dots; i++) {
                    double dot_offset = (i - (dots - 1) / 2.0) * dot_spacing;
                    double dx, dy;
                    if (position == "bottom") {
                        dx = x + dot_offset; dy = y + size / 2.0 + 6;
                    } else if (position == "top") {
                        dx = x + dot_offset; dy = y - size / 2.0 - 6;
                    } else if (position == "left") {
                        dx = x - size / 2.0 - 6; dy = y + dot_offset;
                    } else { // right
                        dx = x + size / 2.0 + 6; dy = y + dot_offset;
                    }
                    cr.arc(dx, dy, 2.0, 0, 2 * Math.PI);
                    cr.fill();
                }
            }

            // Notification badge (macOS-style red badge overlapping top-right of icon)
            if (item.notification_count > 0) {
                // Compute badge text fresh from the int value each frame — avoids
                // any stale/corrupt cached string in the GObject property
                int badge_count = item.notification_count;
                string badge_text = badge_count > 9 ? "9+" : badge_count.to_string();

                // Measure text to determine badge dimensions
                cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
                cr.set_font_size(size * 0.24);
                Cairo.TextExtents te;
                safe_text_extents(cr, badge_text, out te);

                double min_d = size * 0.34;
                double badge_h = min_d;
                double badge_w = double.max(min_d, te.width + min_d * 0.7);
                double badge_r = badge_h / 2.0;

                // Position: inset from the top-right corner so the badge overlaps the icon
                // (macOS places ~70% of the badge on the icon, ~30% peeking beyond)
                double badge_cx = x + size / 2.0 - badge_r * 0.35;
                double badge_cy = y - size / 2.0 + badge_r * 0.35;
                double bx = badge_cx - badge_w / 2.0;
                double by = badge_cy - badge_h / 2.0;

                // Subtle drop shadow
                draw_rounded_rect(cr, bx - 0.5, by + 1.0, badge_w + 1, badge_h + 1, badge_r + 0.5);
                cr.set_source_rgba(0, 0, 0, 0.25);
                cr.fill();

                // Red badge (circle for single digits, pill for "9+")
                draw_rounded_rect(cr, bx, by, badge_w, badge_h, badge_r);
                cr.set_source_rgba(1.0, 0.23, 0.19, 1.0);
                cr.fill();

                // White text centered in badge (use x_advance for uniform glyph centering)
                double text_ox = badge_cx - te.x_advance / 2.0;
                double text_oy = badge_cy - te.y_bearing - te.height / 2.0;
                cr.set_source_rgba(1, 1, 1, 1);
                cr.move_to(text_ox, text_oy);
                safe_show_text(cr, badge_text);
            }

            // Progress bar overlay (along the edge side of the icon)
            if (item.progress_visible) {
                double bar_len = (double)size;
                double bar_thick = 3;
                double bar_radius = bar_thick / 2.0;
                double bar_x, bar_y, bar_w, bar_h;

                if (vert) {
                    // Vertical bar alongside icon
                    bar_w = bar_thick; bar_h = bar_len;
                    bar_y = y - bar_len / 2.0;
                    bar_x = (position == "left") ? x - size / 2.0 - 5 : x + size / 2.0 + 2;
                } else {
                    // Horizontal bar below/above icon
                    bar_w = bar_len; bar_h = bar_thick;
                    bar_x = x - bar_len / 2.0;
                    bar_y = (position == "top") ? y - size / 2.0 - 5 : y + size / 2.0 + 2;
                }

                // Track background
                draw_rounded_rect(cr, bar_x, bar_y, bar_w, bar_h, bar_radius);
                if (is_light_theme()) {
                    cr.set_source_rgba(0.3, 0.3, 0.3, 0.2);
                } else {
                    cr.set_source_rgba(1, 1, 1, 0.15);
                }
                cr.fill();

                double progress_frac;
                if (item.progress_value >= 0.0) {
                    progress_frac = item.progress_value.clamp(0.0, 1.0);
                } else {
                    int64 now = GLib.get_monotonic_time();
                    progress_frac = (now % 2000000) / 2000000.0;
                }

                if (vert) {
                    double fill_h = bar_len * progress_frac;
                    if (fill_h > bar_radius * 2) {
                        draw_rounded_rect(cr, bar_x, bar_y, bar_w, fill_h, bar_radius);
                        cr.set_source_rgba(0.2, 0.6, 1.0, 0.9);
                        cr.fill();
                    }
                } else {
                    double fill_w = bar_len * progress_frac;
                    if (fill_w > bar_radius * 2) {
                        draw_rounded_rect(cr, bar_x, bar_y, fill_w, bar_h, bar_radius);
                        cr.set_source_rgba(0.2, 0.6, 1.0, 0.9);
                        cr.fill();
                    }
                }
            }
        }

        private void draw_widget_text(Cairo.Context cr, string raw_text, double x, double y, int size) {
            string text = safe_text(raw_text);
            if (text == "") return;
            cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
            cr.set_font_size(size * 0.35);

            Cairo.TextExtents extents;
            safe_text_extents(cr, text, out extents);

            double text_x = x - extents.width / 2;
            double text_y = y + extents.height / 2;

            cr.set_source_rgba(1, 1, 1, 1);
            cr.move_to(text_x, text_y);
            safe_show_text(cr, text);
        }

        public static void draw_rounded_rect(Cairo.Context cr, double x, double y,
                                               double w, double h, double radius) {
            cr.new_path();
            if (radius > 0) {
                cr.arc(x + w - radius, y + radius, radius, -Math.PI / 2, 0);
                cr.arc(x + w - radius, y + h - radius, radius, 0, Math.PI / 2);
                cr.arc(x + radius, y + h - radius, radius, Math.PI / 2, Math.PI);
                cr.arc(x + radius, y + radius, radius, Math.PI, 3 * Math.PI / 2);
            } else {
                cr.rectangle(x, y, w, h);
            }
            cr.close_path();
        }

        private string truncate_text(Cairo.Context cr, string text, double max_width) {
            return TextUtil.truncate(text, max_width, (s) => {
                Cairo.TextExtents extents;
                safe_text_extents(cr, s, out extents);
                return extents.width;
            });
        }

        private void draw_media_compact(Cairo.Context cr, MediaPlugin mp,
                                        double x, double y, int size, string position,
                                        bool hovered = false) {
            double rx = x - size / 2.0;
            double ry = y - size / 2.0;
            double radius = size * 0.18;

            // Album art clipped to rounded square, with hover brightening
            cr.push_group();
            cr.save();
            draw_rounded_rect(cr, rx, ry, size, size, radius);
            cr.clip();

            var art = mp.get_art(size);
            if (art != null) {
                Gdk.cairo_set_source_pixbuf(cr, art, rx, ry);
                cr.paint();
            } else {
                // Dark background with fallback music icon
                double bg_r = 0.2, bg_g = 0.2, bg_b = 0.2;
                if (theme != null) { bg_r = theme.bg_red; bg_g = theme.bg_green; bg_b = theme.bg_blue; }
                cr.set_source_rgba(bg_r, bg_g, bg_b, 0.6);
                cr.paint();
                int fallback_sz = size / 2;
                var fb = get_icon("audio-x-generic-symbolic", fallback_sz);
                if (fb != null) {
                    Gdk.cairo_set_source_pixbuf(cr, fb,
                        rx + (size - fallback_sz) / 2.0,
                        ry + (size - fallback_sz) / 2.0);
                    cr.paint();
                }
            }
            if (hovered) {
                cr.set_source_rgba(1, 1, 1, 0.18);
                cr.paint();
            }
            cr.restore();
            cr.pop_group_to_source();
            cr.paint();

            // Small play/pause overlay badge in bottom-right corner
            if (mp.is_playing) {
                int badge_sz = (int)(size * 0.3);
                double bx = x + size / 2.0 - badge_sz - 1;
                double by = y + size / 2.0 - badge_sz - 1;
                // Semi-transparent background circle
                cr.arc(bx + badge_sz / 2.0, by + badge_sz / 2.0, badge_sz / 2.0 + 2, 0, 2 * Math.PI);
                cr.set_source_rgba(0, 0, 0, 0.5);
                cr.fill();
                var play_icon = get_icon("media-playback-pause-symbolic", badge_sz);
                if (play_icon != null) {
                    Gdk.cairo_set_source_pixbuf(cr, play_icon, bx, by);
                    cr.paint();
                }
            }

            // Indicator dot (position-aware, toward screen edge)
            if (theme != null) {
                cr.set_source_rgba(theme.indicator_red, theme.indicator_green,
                                   theme.indicator_blue, theme.indicator_alpha);
            } else if (is_light_theme()) {
                cr.set_source_rgba(0.12, 0.12, 0.14, 0.90);
            } else {
                cr.set_source_rgba(1, 1, 1, 0.4);
            }
            double dx, dy;
            if (position == "left") {
                dx = x - size / 2.0 - 6; dy = y;
            } else {
                dx = x + size / 2.0 + 6; dy = y;
            }
            cr.arc(dx, dy, 2.0, 0, 2 * Math.PI);
            cr.fill();
        }

        private void draw_media_widget(Cairo.Context cr, MediaPlugin mp,
                                        double x, double y, int size, double width_factor,
                                        bool item_hovered = false, double hover_x = -1,
                                        string position = "bottom") {
            double widget_w = size * width_factor;
            double widget_h = (double)size;
            double rx = x - widget_w / 2.0;
            double ry = y - widget_h / 2.0;
            double pad = 6;
            double pill_radius = 10;

            // Theme-derived colors (fallback to white-on-dark defaults)
            double fg_r = 1, fg_g = 1, fg_b = 1;
            double pill_r = 1, pill_g = 1, pill_b = 1;
            double bg_r = 0.2, bg_g = 0.2, bg_b = 0.2;
            if (theme != null) {
                fg_r = theme.indicator_red; fg_g = theme.indicator_green; fg_b = theme.indicator_blue;
                pill_r = theme.border_red; pill_g = theme.border_green; pill_b = theme.border_blue;
                bg_r = theme.bg_red; bg_g = theme.bg_green; bg_b = theme.bg_blue;
            }

            // Rounded-rect overlay background (macOS-style corners)
            draw_rounded_rect(cr, rx, ry, widget_w, widget_h, pill_radius);
            cr.set_source_rgba(pill_r, pill_g, pill_b, 0.12);
            cr.fill();

            // Album art (square, equal padding on all sides)
            int art_sz = (int)(widget_h - pad * 2);
            double art_x = rx + pad;
            double art_y = y - art_sz / 2.0;
            cr.save();
            draw_rounded_rect(cr, art_x, art_y, art_sz, art_sz, 6);
            cr.clip();
            var art = mp.get_art(art_sz);
            if (art != null) {
                Gdk.cairo_set_source_pixbuf(cr, art, art_x, art_y);
                cr.paint();
            } else {
                cr.set_source_rgba(bg_r, bg_g, bg_b, 0.6);
                cr.paint();
                // Fallback music icon centered in square
                int fallback_sz = art_sz / 2;
                var fb = get_icon("audio-x-generic-symbolic", fallback_sz);
                if (fb != null) {
                    Gdk.cairo_set_source_pixbuf(cr, fb,
                        art_x + (art_sz - fallback_sz) / 2.0,
                        art_y + (art_sz - fallback_sz) / 2.0);
                    cr.paint();
                }
            }
            cr.restore();

            // Control button positions
            int ctrl_sz = 20;
            double skip_x = rx + widget_w - pad - ctrl_sz;
            double pause_x = skip_x - 6 - ctrl_sz;

            // Detect which button is hovered
            bool pause_hovered = item_hovered && hover_x >= pause_x && hover_x <= pause_x + ctrl_sz;
            bool skip_hovered = item_hovered && hover_x >= skip_x && hover_x <= skip_x + ctrl_sz;

            bool light = is_light_theme();

            // Draw control icons — ATOP overlay on hover to tint the icon itself
            // Dark theme: icons are light, so overlay dock bg color to darken them
            // Light theme: icons are dark, so overlay white to lighten them
            var pause_icon = get_icon(mp.is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic", ctrl_sz);
            if (pause_icon != null) {
                cr.push_group();
                Gdk.cairo_set_source_pixbuf(cr, pause_icon, pause_x, y - ctrl_sz / 2.0);
                cr.paint();
                if (pause_hovered) {
                    cr.set_operator(Cairo.Operator.ATOP);
                    if (light) {
                        cr.set_source_rgba(1, 1, 1, 0.2);
                    } else {
                        cr.set_source_rgba(bg_r, bg_g, bg_b, 0.5);
                    }
                    cr.paint();
                    cr.set_operator(Cairo.Operator.OVER);
                }
                cr.pop_group_to_source();
                cr.paint();
            }
            var skip_icon = get_icon("media-skip-forward-symbolic", ctrl_sz);
            if (skip_icon != null) {
                cr.push_group();
                Gdk.cairo_set_source_pixbuf(cr, skip_icon, skip_x, y - ctrl_sz / 2.0);
                cr.paint();
                if (skip_hovered) {
                    cr.set_operator(Cairo.Operator.ATOP);
                    if (light) {
                        cr.set_source_rgba(1, 1, 1, 0.2);
                    } else {
                        cr.set_source_rgba(bg_r, bg_g, bg_b, 0.5);
                    }
                    cr.paint();
                    cr.set_operator(Cairo.Operator.OVER);
                }
                cr.pop_group_to_source();
                cr.paint();
            }

            // Track text between art and controls
            double text_left = art_x + art_sz + 8;
            double text_max = pause_x - 8 - text_left;
            if (text_max < 20) return;

            // Title (theme foreground, bold, 11px)
            cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
            cr.set_font_size(11);
            cr.set_source_rgba(fg_r, fg_g, fg_b, 0.95);

            string title = safe_text(mp.track_title);
            if (title == "") title = safe_text(mp.player_name);
            title = truncate_text(cr, title, text_max);
            cr.move_to(text_left, y - 1);
            safe_show_text(cr, title);

            // Artist (theme foreground dimmed, 9px)
            if (mp.track_artist != "") {
                cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
                cr.set_font_size(9);
                cr.set_source_rgba(fg_r, fg_g, fg_b, 0.5);
                string artist = truncate_text(cr, safe_text(mp.track_artist), text_max);
                cr.move_to(text_left, y + 10);
                safe_show_text(cr, artist);
            }

            // Indicator dot (consistent with icon running dots)
            if (theme != null) {
                cr.set_source_rgba(theme.indicator_red, theme.indicator_green,
                                   theme.indicator_blue, theme.indicator_alpha);
            } else if (light) {
                cr.set_source_rgba(0.12, 0.12, 0.14, 0.90);  // Charcoal
            } else {
                cr.set_source_rgba(1, 1, 1, 0.4);
            }
            double dot_x, dot_y;
            if (position == "top") {
                dot_x = x; dot_y = y - size / 2.0 - 6;
            } else {
                dot_x = x; dot_y = y + size / 2.0 + 6;
            }
            cr.arc(dot_x, dot_y, 2.0, 0, 2 * Math.PI);
            cr.fill();
        }

        private bool is_light_theme() {
            return theme != null && theme.is_light();
        }

        private void draw_folder_icon(Cairo.Context cr, DockItem item, double x, double y, int size) {
            double rx = x - size / 2.0;
            double ry = y - size / 2.0;
            double radius = size * 0.2;

            // Rounded rect background
            draw_rounded_rect(cr, rx, ry, size, size, radius);
            if (is_light_theme()) {
                cr.set_source_rgba(0.85, 0.85, 0.85, 0.9);
            } else {
                cr.set_source_rgba(0.3, 0.3, 0.3, 0.7);
            }
            cr.fill();

            // Draw 2x2 mini grid of first 4 app icons
            int mini_size = (int)(size * 0.35);
            double padding = size * 0.12;
            double inner_spacing = size * 0.06;
            double start_x = rx + padding;
            double start_y = ry + padding;

            int count = 0;
            foreach (var app_id in item.folder_apps) {
                if (count >= 4) break;
                var app = app_manager.get_app(app_id);
                if (app == null) { count++; continue; }

                int col = count % 2;
                int row_i = count / 2;
                double ix = start_x + col * (mini_size + inner_spacing);
                double iy = start_y + row_i * (mini_size + inner_spacing);

                var pixbuf = get_icon(app.icon, mini_size);
                if (pixbuf != null) {
                    Gdk.cairo_set_source_pixbuf(cr, pixbuf, ix, iy);
                    cr.paint();
                }
                count++;
            }
        }

        public double calculate_scale(double distance, double hover_pos, bool hovering) {
            if (!hovering) return 1.0;

            double range = icon_size * 2.5;
            if (distance > range) return 1.0;

            double factor = 1.0 - (distance / range);
            return 1.0 + (magnification - 1.0) * factor * factor;
        }
    }
}
