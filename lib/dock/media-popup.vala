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
        private bool fading_out = false;
        private bool pointer_inside = false;
        private uint dismiss_id = 0;
        private const int FADE_MS = 180;
        private const int ART_SIZE = 96;

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
        private int64 shown_length_us = -1;

        // Position polling and seeking: the player only reports where it is when asked, so a
        // one-second timer runs while the popup is open and the track is playing
        private uint tick_id = 0;
        private uint request_id = 0;
        private uint seek_id = 0;
        private bool scrubbing = false;
        private bool seek_pending = false;
        private int64 pending_us = 0;
        private int64 settle_until = 0;

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
                    destroy_popup();
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

        // Open after the pointer has rested on the widget for a moment
        public void request(MediaPlugin target, int index) {
            if (popup != null && !fading_out) { cancel_dismiss(); return; }
            if (request_id != 0) return;
            request_id = Timeout.add(300, () => {
                request_id = 0;
                open(target, index);
                return false;
            });
        }

        public void cancel_request() {
            if (request_id != 0) { Source.remove(request_id); request_id = 0; }
        }

        private void destroy_popup() {
            teardown();
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
            if (art != null) art_image.set_from_pixbuf(art);
            else art_image.set_from_icon_name("audio-x-generic-symbolic", Gtk.IconSize.DIALOG);

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
            if (popup != null && !fading_out) { cancel_dismiss(); return; }
            if (popup != null) destroy_popup();   // still fading out: start afresh

            pointer_inside = false;
            mp = target;
            shown_length_us = -1;

            popup = PopupHelper.create_window(Gdk.WindowTypeHint.POPUP_MENU, host.popup_parent());

            bool popup_light = host.popup_is_light();
            string fg = popup_light ? "#1a1a1a" : "#ffffff";
            string dim = popup_light ? "#4d4d4d" : "#b3b3b3";
            string hover = popup_light ? "rgba(0,0,0,0.08)" : "rgba(255,255,255,0.1)";

            var css_provider = new Gtk.CssProvider();
            try {
                css_provider.load_from_data(
                    "button { color: %s; } button:hover { background: %s; } ".printf(fg, hover) +
                    ".media-title { color: %s; } .media-artist { color: %s; } ".printf(fg, dim) +
                    ".media-album, .media-time { color: %s; } .media-time { font-size: 11px; }".printf(dim));
            } catch (Error e) {}

            var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
            hbox.margin = 12;

            art_image = new Gtk.Image();
            art_image.set_size_request(ART_SIZE, ART_SIZE);
            art_image.valign = Gtk.Align.START;
            hbox.pack_start(art_image, false, false, 0);

            var col = new Gtk.Box(Gtk.Orientation.VERTICAL, 3);
            col.valign = Gtk.Align.CENTER;

            title_label = make_label("media-title", css_provider);
            artist_label = make_label("media-artist", css_provider);
            album_label = make_label("media-album", css_provider);
            col.pack_start(title_label, false, false, 0);
            col.pack_start(artist_label, false, false, 0);
            col.pack_start(album_label, false, false, 0);

            // Seek bar: elapsed time on the left, track length on the right
            seek_row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            seek_row.no_show_all = true;
            seek_row.margin_top = 6;
            pos_label = make_label("media-time", css_provider);
            len_label = make_label("media-time", css_provider);
            seek = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 1);
            seek.draw_value = false;
            seek.set_size_request(180, -1);
            seek.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            pos_label.show();
            len_label.show();
            seek.show();
            seek_row.pack_start(pos_label, false, false, 0);
            seek_row.pack_start(seek, true, true, 0);
            seek_row.pack_start(len_label, false, false, 0);
            col.pack_start(seek_row, false, false, 0);

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

            // Transport controls
            var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            btn_box.halign = Gtk.Align.CENTER;
            btn_box.margin_top = 4;
            btn_box.pack_start(make_button("media-skip-backward-symbolic", css_provider, () => target.previous()), false, false, 0);
            play_btn = make_button("media-playback-start-symbolic", css_provider, () => target.activate());
            btn_box.pack_start(play_btn, false, false, 0);
            btn_box.pack_start(make_button("media-skip-forward-symbolic", css_provider, () => target.next()), false, false, 0);
            col.pack_start(btn_box, false, false, 0);

            hbox.pack_start(col, true, true, 0);

            // Themed popup background
            var theme_ref = host.popup_theme();
            popup.draw.connect((cr) => {
                PopupHelper.draw_background(cr, popup, theme_ref, 10);
                return false;
            });

            popup.add(hbox);
            hbox.show_all();
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

        private Gtk.Button make_button(string icon, Gtk.CssProvider css_provider, ButtonAction action) {
            var button = new Gtk.Button.from_icon_name(icon, Gtk.IconSize.LARGE_TOOLBAR);
            button.relief = Gtk.ReliefStyle.NONE;
            button.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            button.clicked.connect(() => action());
            return button;
        }
    }
}
