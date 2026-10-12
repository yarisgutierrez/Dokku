namespace Dokku {
    // Now-playing flyout: art, title, artist, album, a seek bar and transport controls.
    // It opens when the pointer rests on the media widget, or when its art or text is clicked.
    public class MediaPopup : GLib.Object {
        private PopupHost host;

        public MediaPopup(PopupHost host) {
            this.host = host;
        }

        // Remove timers and the popup window (dock being destroyed).
        public void shutdown() {
            if (dismiss_id != 0) { Source.remove(dismiss_id); dismiss_id = 0; }
            cancel_request();
            teardown();
            if (popup != null) { popup.destroy(); popup = null; }
        }

        private Gtk.Window? popup = null;
        private uint fade_tick = 0;
        private int64 fade_start = 0;
        private double fade_from = 0;
        private bool fading_out = false;
        private bool pointer_inside = false;
        private uint dismiss_id = 0;
        private const int FADE_MS = 180;
        // How long the pointer rests on the widget before the popup opens. Long enough that
        // someone who means to click usually does so first.
        private const int HOVER_DELAY_MS = 600;
        // A click this soon after the popup opened by hover is ignored: it was most likely
        // aimed at opening the popup, which the hover just did
        private const int CLICK_GUARD_MS = 800;
        private const int ART_SIZE = 88;
        private const int ICON_SIZE = 20;

        // The track the open popup shows, and the widgets that follow it
        private MediaPlugin? mp = null;
        private ulong changed_handler = 0;
        private Gtk.Image art_image;
        private Gtk.Label title_label;
        private Gtk.Label artist_label;
        private Gtk.Label album_label;
        private Gtk.Box seek_row;
        private Gtk.Scale seek;
        private Gtk.Label pos_label;
        private Gtk.Label len_label;
        private Gtk.Button play_btn;
        private Gtk.Image player_icon;
        private Gtk.CssProvider accent_css;
        private bool popup_light = false;
        private bool has_tint = false;
        private double tint_r = 0;
        private double tint_g = 0;
        private double tint_b = 0;
        private int64 shown_length_us = -1;

        // Position polling and seeking: the player only reports where it is when asked, so a
        // one-second timer runs while the popup is open and the track is playing
        private uint tick_id = 0;
        private uint request_id = 0;
        // Set when a click closed the popup: hover must not reopen it until the pointer leaves
        private bool hover_suppressed = false;
        // When the open popup was opened by hover (monotonic µs), or 0 if a click opened it
        private int64 hover_opened_at = 0;
        private uint seek_id = 0;
        private bool scrubbing = false;
        private bool seek_pending = false;
        private int64 pending_us = 0;
        private int64 settle_until = 0;

        // Fade the popup in or out from wherever its opacity is now, so a dismiss that lands
        // mid fade-in turns around instead of leaving the popup stuck half way
        private void start_fade(bool out_) {
            if (popup == null) return;
            fade_from = ((Gtk.Widget) popup).opacity;
            fading_out = out_;
            fade_start = GLib.get_monotonic_time();
            if (fade_tick != 0) return;  // the running tick follows the new direction
            fade_tick = popup.add_tick_callback((widget, clock) => {
                double t = ((clock.get_frame_time() - fade_start) / (FADE_MS * 1000.0)).clamp(0.0, 1.0);
                double target = fading_out ? 0.0 : 1.0;
                ((Gtk.Widget) widget).opacity = fade_from + (target - fade_from) * t;
                if (t < 1.0) return true;
                fade_tick = 0;
                if (fading_out) {
                    fading_out = false;
                    destroy_popup();
                }
                return false;
            });
        }

        public void dismiss() {
            if (popup == null || fading_out) return;
            start_fade(true);
        }

        public void schedule_dismiss() {
            if (popup == null || dismiss_id != 0) return;
            dismiss_id = Timeout.add(300, () => {
                dismiss_id = 0;
                if (!pointer_inside) {
                    dismiss();
                }
                return false;
            });
        }

        public void cancel_dismiss() {
            if (dismiss_id != 0) {
                Source.remove(dismiss_id);
                dismiss_id = 0;
            }
        }

        // Open after the pointer has rested on the widget for a moment
        public void request(MediaPlugin target, int index) {
            if (hover_suppressed) return;
            if (popup != null && !fading_out) { cancel_dismiss(); return; }
            if (request_id != 0) return;
            request_id = Timeout.add(HOVER_DELAY_MS, () => {
                request_id = 0;
                bool was_open = popup != null && !fading_out;
                open(target, index);
                if (!was_open) hover_opened_at = GLib.get_monotonic_time();
                return false;
            });
        }

        // Called when the pointer is off the widget: hover may open the popup again
        public void cancel_request() {
            if (request_id != 0) { Source.remove(request_id); request_id = 0; }
            hover_suppressed = false;
        }

        // A click on the widget's art or text: close the popup if it is open, else open it
        public void toggle(MediaPlugin target, int index) {
            if (popup != null && !fading_out) {
                if (hover_opened_at != 0 &&
                    GLib.get_monotonic_time() - hover_opened_at < CLICK_GUARD_MS * 1000) return;
                hover_suppressed = true;
                dismiss();
            } else {
                open(target, index);
                hover_opened_at = 0;
            }
        }

        private void destroy_popup() {
            teardown();
            hover_opened_at = 0;
            fade_tick = 0;   // the tick dies with the window
            fading_out = false;
            if (popup != null) { popup.destroy(); popup = null; }
        }

        // Stop following the player and drop the timers
        private void teardown() {
            if (mp != null && changed_handler != 0) mp.disconnect(changed_handler);
            changed_handler = 0;
            mp = null;
            if (tick_id != 0) { Source.remove(tick_id); tick_id = 0; }
            if (seek_id != 0) { Source.remove(seek_id); seek_id = 0; }
            seek_pending = false;
            scrubbing = false;
        }

        private static string format_time(int64 us) {
            int64 total = us / 1000000;
            if (total < 0) total = 0;
            if (total >= 3600) return "%d:%02d:%02d".printf((int)(total / 3600), (int)(total / 60 % 60), (int)(total % 60));
            return "%d:%02d".printf((int)(total / 60), (int)(total % 60));
        }

        // The album art's average colour tints the card and picks the accent
        private void update_colors(Gdk.Pixbuf? art) {
            has_tint = false;
            double ar = popup_light ? 0.1 : 0.95, ag = ar, ab = ar;   // no art: a neutral accent
            if (art != null) {
                var one_pixel = art.scale_simple(1, 1, Gdk.InterpType.BILINEAR);   // keep it alive while reading
                unowned uint8[] px = one_pixel.get_pixels();
                tint_r = px[0] / 255.0; tint_g = px[1] / 255.0; tint_b = px[2] / 255.0;
                has_tint = true;
                accent_from(tint_r, tint_g, tint_b, popup_light, out ar, out ag, out ab);
            }
            string accent = hex(ar, ag, ab);
            string on_accent = popup_light ? "#ffffff" : "#111111";
            try {
                accent_css.load_from_data(
                    ".media-artist { color: %s; } ".printf(accent) +
                    "button.media-play { background: %s; color: %s; border-radius: 15px; ".printf(accent, on_accent) +
                    "min-width: 48px; min-height: 30px; padding: 0; } " +
                    "button.media-play:hover { background: %s; } ".printf(hex(ar * 0.85, ag * 0.85, ab * 0.85)) +
                    "scale highlight, scale trough highlight { background-image: none; background-color: %s; border: none; } ".printf(accent) +
                    "scale slider { background-color: %s; border-color: %s; } ".printf(accent, accent));
            } catch (Error e) {}
            popup.queue_draw();
        }

        private static string hex(double r, double g, double b) {
            return "#%02x%02x%02x".printf((int)(r.clamp(0, 1) * 255), (int)(g.clamp(0, 1) * 255), (int)(b.clamp(0, 1) * 255));
        }

        // Keep the art's hue, but fix the lightness so the accent reads on the card
        private static void accent_from(double r, double g, double b, bool light,
                                        out double ar, out double ag, out double ab) {
            double hi = double.max(r, double.max(g, b)), lo = double.min(r, double.min(g, b));
            double h = 0, sat = 0, d = hi - lo, l = (hi + lo) / 2;
            if (d > 0.0001) {
                sat = d / (1 - (2 * l - 1).abs());
                if (hi == r) h = ((g - b) / d) % 6;
                else if (hi == g) h = (b - r) / d + 2;
                else h = (r - g) / d + 4;
                h *= 60; if (h < 0) h += 360;
            }
            if (sat > 0.1) sat = double.max(sat, 0.5);
            double lum = light ? 0.38 : 0.74;
            double c = (1 - (2 * lum - 1).abs()) * sat;
            double x = c * (1 - ((h / 60) % 2 - 1).abs());
            double m = lum - c / 2;
            double rr = 0, gg = 0, bb = 0;
            if (h < 60) { rr = c; gg = x; }
            else if (h < 120) { rr = x; gg = c; }
            else if (h < 180) { gg = c; bb = x; }
            else if (h < 240) { gg = x; bb = c; }
            else if (h < 300) { rr = x; bb = c; }
            else { rr = c; bb = x; }
            ar = rr + m; ag = gg + m; ab = bb + m;
        }

        // The art with rounded corners, for the card
        private static Cairo.Surface rounded_art(Gdk.Pixbuf art, double radius) {
            int w = art.get_width(), h = art.get_height();
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, w, h);
            var cr = new Cairo.Context(surface);
            DockRenderer.draw_rounded_rect(cr, 0, 0, w, h, radius);
            cr.clip();
            Gdk.cairo_set_source_pixbuf(cr, art, 0, 0);
            cr.paint();
            return surface;
        }

        // Bring every label, the art, the play icon and the seek bar up to date
        private void refresh() {
            if (popup == null || mp == null) return;

            string title_str = mp.track_title != "" ? mp.track_title : mp.player_name;
            title_label.visible = true;
            title_label.set_markup("<b>" + GLib.Markup.escape_text(title_str) + "</b>");
            artist_label.label = mp.track_artist;
            artist_label.visible = mp.track_artist != "";
            album_label.label = mp.track_album;
            album_label.visible = mp.track_album != "";

            var art = mp.get_art(ART_SIZE);
            if (art != null) art_image.set_from_surface(rounded_art(art, 12));
            else art_image.set_from_icon_name("audio-x-generic-symbolic", Gtk.IconSize.DIALOG);
            update_colors(art);

            // The player's logo, flattened to grey so it reads as one colour
            var logo = mp.player_icon_name != "" ? IconLoader.load(mp.player_icon_name, ICON_SIZE) : null;
            if (logo != null) {
                var grey = logo.copy();
                logo.saturate_and_pixelate(grey, 0, false);
                player_icon.set_from_pixbuf(grey);
            }
            player_icon.visible = logo != null;

            ((Gtk.Image) play_btn.image).set_from_icon_name(
                mp.is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic",
                Gtk.IconSize.LARGE_TOOLBAR);

            // A stream with no length, or a player that can't seek, gets no seek bar
            bool seekable = mp.track_length_us > 0 && mp.can_seek;
            seek_row.visible = seekable;
            if (seekable) {
                if (mp.track_length_us != shown_length_us) {
                    shown_length_us = mp.track_length_us;
                    seek.set_range(0, mp.track_length_us / 1000000.0);
                    seek.set_value(0);
                    pos_label.label = format_time(0);
                    len_label.label = format_time(mp.track_length_us);
                }
                update_position.begin();
            }
        }

        private async void update_position() {
            var target = mp;
            if (target == null) return;
            int64 pos = yield target.get_position();
            // The popup may have closed, moved to another track or be mid-seek by now
            if (popup == null || mp != target || pos < 0) return;
            if (scrubbing || seek_pending || GLib.get_monotonic_time() < settle_until) return;
            seek.set_value(pos / 1000000.0);
            pos_label.label = format_time(pos);
        }

        private void commit_seek() {
            if (seek_id != 0) { Source.remove(seek_id); seek_id = 0; }
            if (!seek_pending) return;
            seek_pending = false;
            if (mp != null) mp.seek_to(pending_us);
            // Ignore positions read before the player has acted on the seek
            settle_until = GLib.get_monotonic_time() + 800000;
        }

        public void open(MediaPlugin target, int index) {
            cancel_request();
            cancel_dismiss();   // a timer left from an earlier popup must not close this one
            if (popup != null) {
                if (fading_out) start_fade(false);   // closing: bring it back instead of rebuilding
                return;
            }

            pointer_inside = false;
            mp = target;
            shown_length_us = -1;

            popup = PopupHelper.create_window(Gdk.WindowTypeHint.POPUP_MENU, host.popup_parent());

            popup_light = host.popup_is_light();
            string fg = popup_light ? "#1a1a1a" : "#ffffff";
            string dim = popup_light ? "#4d4d4d" : "#b3b3b3";
            string hover = popup_light ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.12)";
            string track = popup_light ? "rgba(0,0,0,0.18)" : "rgba(255,255,255,0.22)";

            var css_provider = new Gtk.CssProvider();
            try {
                css_provider.load_from_data(
                    "button { color: %s; } button:hover { background: %s; } ".printf(fg, hover) +
                    ".media-title { color: %s; font-size: 14px; } .media-artist { color: %s; } ".printf(fg, dim) +
                    ".media-album, .media-time { color: %s; } .media-time { font-size: 11px; } ".printf(dim) +
                    "scale trough { min-height: 2px; border: none; border-radius: 1px; background-image: none; background-color: %s; } ".printf(track) +
                    "scale highlight { border: none; border-radius: 1px; } " +
                    "scale slider { min-width: 10px; min-height: 10px; border-radius: 9999px; background-image: none; box-shadow: none; }");
            } catch (Error e) {}
            accent_css = new Gtk.CssProvider();

            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
            outer.margin = 12;

            // Art on the left; text on the right with the player's logo in the corner
            var top = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 14);
            art_image = new Gtk.Image();
            art_image.set_size_request(ART_SIZE, ART_SIZE);
            art_image.valign = Gtk.Align.START;
            top.pack_start(art_image, false, false, 0);

            var col = new Gtk.Box(Gtk.Orientation.VERTICAL, 3);
            col.valign = Gtk.Align.CENTER;
            title_label = make_label("media-title", css_provider);
            artist_label = make_label("media-artist", css_provider);
            album_label = make_label("media-album", css_provider);
            artist_label.get_style_context().add_provider(accent_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            col.pack_start(title_label, false, false, 0);
            col.pack_start(artist_label, false, false, 0);
            col.pack_start(album_label, false, false, 0);

            var text_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            player_icon = new Gtk.Image();
            player_icon.no_show_all = true;
            player_icon.valign = Gtk.Align.START;
            ((Gtk.Widget) player_icon).opacity = 0.8;
            text_row.pack_start(col, true, true, 0);
            text_row.pack_start(player_icon, false, false, 0);
            top.pack_start(text_row, true, true, 0);
            outer.pack_start(top, false, false, 0);

            // Seek bar across the card: elapsed time on the left, track length on the right
            seek_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
            seek_row.no_show_all = true;
            pos_label = make_label("media-time", css_provider);
            len_label = make_label("media-time", css_provider);
            pos_label.width_chars = 5;
            len_label.width_chars = 5;
            len_label.xalign = 1;
            pos_label.show();
            len_label.show();
            seek = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 1);
            seek.draw_value = false;
            seek.set_size_request(240, 14);
            seek.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            seek.get_style_context().add_provider(accent_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            seek.show();
            seek_row.pack_start(pos_label, false, false, 0);
            seek_row.pack_start(seek, true, true, 0);
            seek_row.pack_start(len_label, false, false, 0);
            outer.pack_start(seek_row, false, false, 0);

            seek.change_value.connect((scroll, value) => {
                pending_us = (int64) (value.clamp(0, seek.adjustment.upper) * 1000000);
                seek_pending = true;
                pos_label.label = format_time(pending_us);
                // While dragging, seek once on release; otherwise (a click, the keyboard) once it settles
                if (!scrubbing) {
                    if (seek_id != 0) Source.remove(seek_id);
                    seek_id = Timeout.add(150, () => { seek_id = 0; commit_seek(); return false; });
                }
                return false;
            });
            seek.button_press_event.connect(() => { scrubbing = true; return false; });
            seek.button_release_event.connect_after(() => { scrubbing = false; commit_seek(); return false; });

            // Transport controls: the play button is the highlighted one
            var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 16);
            btn_box.halign = Gtk.Align.CENTER;
            btn_box.pack_start(make_button("media-skip-backward-symbolic", 18, css_provider, () => target.previous()), false, false, 0);
            play_btn = make_button("media-playback-start-symbolic", 20, css_provider, () => target.activate());
            play_btn.get_style_context().add_class("media-play");
            play_btn.get_style_context().add_provider(accent_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            btn_box.pack_start(play_btn, false, false, 0);
            btn_box.pack_start(make_button("media-skip-forward-symbolic", 18, css_provider, () => target.next()), false, false, 0);
            outer.pack_start(btn_box, false, false, 0);

            // Themed popup background
            var theme_ref = host.popup_theme();
            popup.draw.connect((cr) => {
                PopupHelper.draw_background(cr, popup, theme_ref, 14);
                if (has_tint) {
                    // A wash of the art's colour, strongest behind the art and fading across the card
                    int w = popup.get_allocated_width(), h = popup.get_allocated_height();
                    var wash = new Cairo.Pattern.linear(0, 0, w, h);
                    wash.add_color_stop_rgba(0, tint_r, tint_g, tint_b, 0.55);
                    wash.add_color_stop_rgba(1, tint_r, tint_g, tint_b, 0.15);
                    DockRenderer.draw_rounded_rect(cr, 1, 1, w - 2, h - 2, 13);
                    cr.set_source(wash);
                    cr.fill();
                }
                return false;
            });

            popup.add(outer);
            outer.show_all();
            seek_row.visible = false;
            refresh();

            // Follow the player: track changes, play/pause and late-arriving art
            changed_handler = target.changed.connect(refresh);
            tick_id = Timeout.add_seconds(1, () => {
                if (mp != null && mp.is_playing && seek_row.visible) update_position.begin();
                return true;
            });

            // Start fully transparent for fade-in
            ((Gtk.Widget)popup).opacity = 0.0;
            host.show_popup(popup, index, 8);

            // Fade in
            start_fade(false);

            // Track mouse enter/leave on popup for dismiss-on-leave
            popup.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK |
                                   Gdk.EventMask.LEAVE_NOTIFY_MASK);
            popup.enter_notify_event.connect((ev) => {
                pointer_inside = true;
                cancel_dismiss();
                return false;
            });
            popup.leave_notify_event.connect((ev) => {
                if (ev.detail == Gdk.NotifyType.INFERIOR) return false;
                pointer_inside = false;
                schedule_dismiss();
                return false;
            });
        }

        private Gtk.Label make_label(string css_class, Gtk.CssProvider css_provider) {
            var label = new Gtk.Label(null);
            label.halign = Gtk.Align.START;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 28;
            label.no_show_all = true;
            label.get_style_context().add_class(css_class);
            label.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            return label;
        }

        private delegate void ButtonAction();

        private Gtk.Button make_button(string icon, int pixel_size, Gtk.CssProvider css_provider, ButtonAction action) {
            var button = new Gtk.Button();
            var image = new Gtk.Image.from_icon_name(icon, Gtk.IconSize.LARGE_TOOLBAR);
            image.pixel_size = pixel_size;
            button.image = image;
            button.relief = Gtk.ReliefStyle.NONE;
            button.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            button.clicked.connect(() => action());
            return button;
        }
    }
}
