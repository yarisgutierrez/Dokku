namespace Dokku {
    // Now-playing flyout for vertical docks: art, title/artist and transport controls.
    public class MediaPopup : GLib.Object {
        private PopupHost host;
        private uint media_play_update_id = 0;

        public MediaPopup(PopupHost host) {
            this.host = host;
        }

        // Remove timers and the popup window (dock being destroyed).
        public void shutdown() {
            if (dismiss_id != 0) { Source.remove(dismiss_id); dismiss_id = 0; }
            if (media_play_update_id != 0) { Source.remove(media_play_update_id); media_play_update_id = 0; }
            if (popup != null) { popup.destroy(); popup = null; }
        }

        private Gtk.Window? popup = null;
        private uint fade_tick = 0;
        private int64 fade_start = 0;
        private bool fading_out = false;
        private bool pointer_inside = false;
        private uint dismiss_id = 0;
        private const int FADE_MS = 180;

        public void dismiss() {
            if (popup == null) return;
            if (fading_out) return;  // already fading
            fading_out = true;
            fade_start = GLib.get_monotonic_time();
            if (fade_tick != 0) return;  // reuse tick
            fade_tick = popup.add_tick_callback((widget, clock) => {
                int64 elapsed = clock.get_frame_time() - fade_start;
                double t = double.min(1.0, elapsed / (FADE_MS * 1000.0));
                if (popup != null) {
                    ((Gtk.Widget)popup).opacity = 1.0 - t;
                }
                if (t >= 1.0) {
                    fade_tick = 0;
                    fading_out = false;
                    if (popup != null) {
                        popup.destroy();
                        popup = null;
                    }
                    return false;
                }
                return true;
            });
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

        public void show(MediaPlugin mp, int index) {
            // Toggle: if already open, dismiss it
            if (popup != null) {
                dismiss();
                return;
            }

            pointer_inside = false;

            popup = PopupHelper.create_window(Gdk.WindowTypeHint.POPUP_MENU);

            bool popup_light = host.popup_is_light();

            // CSS for button and label colors
            var css_provider = new Gtk.CssProvider();
            if (popup_light) {
                try {
                    css_provider.load_from_data(
                        "button { color: #1a1a1a; } button:hover { background: rgba(0,0,0,0.08); } " +
                        ".media-title { color: #1a1a1a; } .media-artist { color: #4d4d4d; }");
                } catch (Error e) {}
            } else {
                try {
                    css_provider.load_from_data(
                        "button { color: #ffffff; } button:hover { background: rgba(255,255,255,0.1); } " +
                        ".media-title { color: #ffffff; } .media-artist { color: #b3b3b3; }");
                } catch (Error e) {}
            }

            var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
            hbox.margin = 10;

            // Album art (64x64)
            int art_size = 64;
            var art = mp.get_art(art_size);
            Gtk.Image art_image;
            if (art != null) {
                art_image = new Gtk.Image.from_pixbuf(art);
            } else {
                art_image = new Gtk.Image.from_icon_name("audio-x-generic-symbolic", Gtk.IconSize.DIALOG);
            }
            art_image.set_size_request(art_size, art_size);
            hbox.pack_start(art_image, false, false, 0);

            // Text box (title + artist)
            var text_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            text_box.valign = Gtk.Align.CENTER;

            string title_str = mp.track_title != "" ? mp.track_title : mp.player_name;
            var title_label = new Gtk.Label(null);
            title_label.set_markup("<b>" + GLib.Markup.escape_text(title_str) + "</b>");
            title_label.halign = Gtk.Align.START;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.max_width_chars = 25;
            title_label.get_style_context().add_class("media-title");
            title_label.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            text_box.pack_start(title_label, false, false, 0);

            if (mp.track_artist != "") {
                var artist_label = new Gtk.Label(mp.track_artist);
                artist_label.halign = Gtk.Align.START;
                artist_label.ellipsize = Pango.EllipsizeMode.END;
                artist_label.max_width_chars = 25;
                artist_label.get_style_context().add_class("media-artist");
                artist_label.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
                text_box.pack_start(artist_label, false, false, 0);
            }

            hbox.pack_start(text_box, true, true, 0);

            // Control buttons
            var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            btn_box.valign = Gtk.Align.CENTER;

            var prev_btn = new Gtk.Button.from_icon_name("media-skip-backward-symbolic", Gtk.IconSize.LARGE_TOOLBAR);
            prev_btn.relief = Gtk.ReliefStyle.NONE;
            prev_btn.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            prev_btn.clicked.connect(() => mp.previous());
            btn_box.pack_start(prev_btn, false, false, 0);

            var play_btn = new Gtk.Button.from_icon_name(
                mp.is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic",
                Gtk.IconSize.LARGE_TOOLBAR);
            play_btn.relief = Gtk.ReliefStyle.NONE;
            play_btn.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            play_btn.clicked.connect(() => {
                mp.activate();
                // Update icon after toggle (small delay for state to propagate)
                if (media_play_update_id != 0) Source.remove(media_play_update_id);
                media_play_update_id = Timeout.add(200, () => {
                    media_play_update_id = 0;
                    if (popup != null) {
                        var img = new Gtk.Image.from_icon_name(
                            mp.is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic",
                            Gtk.IconSize.LARGE_TOOLBAR);
                        play_btn.set_image(img);
                    }
                    return false;
                });
            });
            btn_box.pack_start(play_btn, false, false, 0);

            var next_btn = new Gtk.Button.from_icon_name("media-skip-forward-symbolic", Gtk.IconSize.LARGE_TOOLBAR);
            next_btn.relief = Gtk.ReliefStyle.NONE;
            next_btn.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            next_btn.clicked.connect(() => mp.next());
            btn_box.pack_start(next_btn, false, false, 0);

            hbox.pack_start(btn_box, false, false, 0);

            // Themed popup background
            var theme_ref = host.popup_theme();
            popup.draw.connect((cr) => {
                PopupHelper.draw_background(cr, popup, theme_ref, 10);
                return false;
            });

            popup.add(hbox);

            // Start fully transparent for fade-in
            ((Gtk.Widget)popup).opacity = 0.0;
            popup.show_all();

            int popup_w, popup_h;
            popup.get_size(out popup_w, out popup_h);
            int px, py;
            host.popup_position(index, popup_w, popup_h, 8, out px, out py);
            popup.move(px, py);

            // Fade in
            fading_out = false;
            fade_start = GLib.get_monotonic_time();
            fade_tick = popup.add_tick_callback((widget, clock) => {
                int64 elapsed = clock.get_frame_time() - fade_start;
                double t = double.min(1.0, elapsed / (FADE_MS * 1000.0));
                if (popup != null) {
                    ((Gtk.Widget)popup).opacity = t;
                }
                if (t >= 1.0) {
                    fade_tick = 0;
                    return false;
                }
                return true;
            });

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
    }
}
