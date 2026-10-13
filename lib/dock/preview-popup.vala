namespace Dokku {
    // Hover popups: a name tooltip, or a window list for multi-window apps.
    public class PreviewPopup : GLib.Object {
        private PopupHost host;
        private WindowManager wm;
        private Gtk.Window? popup = null;
        private uint hover_timeout_id = 0;
        private uint dismiss_timeout_id = 0;
        private uint flash_timeout_id = 0;
        private Gtk.Label? flash_label = null;
        private int flash_index = -1;
        // The name tooltip being shown, so its text can follow a widget that changes
        private Gtk.Label? tip_label = null;
        private int tip_index = -1;

        // Item index a popup is pending/shown for, or -1.
        public int target_index { get; private set; default = -1; }

        public PreviewPopup(PopupHost host, WindowManager wm) {
            this.host = host;
            this.wm = wm;
        }

        // Show a popup for `index` after `delay_ms`: the window list or a name tooltip.
        public void request(int index, uint delay_ms, bool window_list) {
            target_index = index;
            hover_timeout_id = Timeout.add(delay_ms, () => {
                hover_timeout_id = 0;
                // A message is on screen: let it be read before a hover popup replaces it
                if (flash_timeout_id != 0) return false;
                if (window_list)
                    show_windows(index);
                else
                    show_tooltip(index);
                return false;
            });
        }

        public void cancel_timer() {
            if (hover_timeout_id != 0) {
                Source.remove(hover_timeout_id);
                hover_timeout_id = 0;
            }
            target_index = -1;
        }

        // Hover handling dismisses popups all the time (the pointer moves, an icon changes).
        // A message from flash() is meant to be read, so it is left to run its time out;
        // anything that opens another popup replaces it.
        public void dismiss() {
            if (flash_timeout_id != 0) return;
            close_popup();
        }

        private void close_popup() {
            cancel_dismiss();
            if (flash_timeout_id != 0) { Source.remove(flash_timeout_id); flash_timeout_id = 0; }
            flash_label = null;
            flash_index = -1;
            tip_label = null;
            tip_index = -1;
            if (popup != null) {
                popup.destroy();
                popup = null;
            }
        }

        public void schedule_dismiss() {
            if (popup == null) return;
            if (dismiss_timeout_id != 0) return;
            dismiss_timeout_id = Timeout.add(300, () => {
                dismiss_timeout_id = 0;
                dismiss();
                return false;
            });
        }

        public void cancel_dismiss() {
            if (dismiss_timeout_id != 0) {
                Source.remove(dismiss_timeout_id);
                dismiss_timeout_id = 0;
            }
        }

        // Remove timers and the popup window (dock being destroyed).
        public void shutdown() {
            if (hover_timeout_id != 0) { Source.remove(hover_timeout_id); hover_timeout_id = 0; }
            close_popup();
        }

        // A short message over an item, such as the volume after a scroll. Calling it
        // again for the same item updates the text instead of rebuilding the popup.
        public void flash(int index, string text, uint ms = 1000) {
            if (popup != null && flash_label != null && flash_index == index) {
                flash_label.label = text;
            } else {
                cancel_timer();
                show_tooltip(index, text);
                flash_label = popup != null ? (popup.get_child() as Gtk.Label) : null;
                flash_index = index;
            }
            if (flash_timeout_id != 0) Source.remove(flash_timeout_id);
            flash_timeout_id = Timeout.add(ms, () => {
                flash_timeout_id = 0;
                close_popup();
                return Source.REMOVE;
            });
        }

        // The text of the tooltip open over this item changes (a volume widget after a
        // scroll): show the new text where it is. Does nothing when no tooltip is open for it.
        public void update_tooltip_text(int index, string text) {
            if (popup == null || tip_label == null || tip_index != index) return;
            if (tip_label.label == text) return;
            tip_label.label = text;
            // The popup is as wide as its text, so fit it and centre it over the item again
            if (Capabilities.current.session != SessionType.WAYLAND) {
                popup.resize(1, 1);
                host.show_popup(popup, index, 8);
            }
        }

        public void show_tooltip(int index, string? text = null) {
            var item = host.popup_item(index);
            if (item == null) return;

            close_popup();

            popup = PopupHelper.create_window(Gdk.WindowTypeHint.TOOLTIP, host.popup_parent());

            var label = new Gtk.Label(text != null ? text : item.name);
            label.margin = 6;
            var css = new Gtk.CssProvider();
            try {
                css.load_from_data(host.popup_is_light() ?
                    "label { color: #1a1a1a; }" : "label { color: #ffffff; }");
            } catch (Error e) {}
            label.get_style_context().add_provider(css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            popup.add(label);

            var theme_ref = host.popup_theme();
            popup.draw.connect((cr) => {
                PopupHelper.draw_background(cr, popup, theme_ref, 6);
                return false;
            });

            tip_label = label;
            tip_index = index;
            host.show_popup(popup, index, 8);

            popup.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK |
                                     Gdk.EventMask.LEAVE_NOTIFY_MASK);
            popup.enter_notify_event.connect((ev) => {
                cancel_dismiss();
                return false;
            });
            popup.leave_notify_event.connect((ev) => {
                if (ev.detail == Gdk.NotifyType.INFERIOR) return false;
                schedule_dismiss();
                return false;
            });
        }

        public void show_windows(int index) {
            var item = host.popup_item(index);
            if (item == null || item.windows.length() <= 1) return;

            close_popup();

            popup = PopupHelper.create_window(Gdk.WindowTypeHint.TOOLTIP, host.popup_parent());

            bool popup_light = host.popup_is_light();
            var label_css = new Gtk.CssProvider();
            try {
                label_css.load_from_data(popup_light ?
                    "label { color: #1a1a1a; }" : "label { color: #ffffff; }");
            } catch (Error e) {}

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            box.margin = 8;

            foreach (var window in item.windows) {
                var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
                row.margin = 4;

                var icon = IconLoader.image(item.icon_name, Gtk.IconSize.MENU);
                row.pack_start(icon, false, false, 0);

                var label = new Gtk.Label(window.title);
                label.halign = Gtk.Align.START;
                label.ellipsize = Pango.EllipsizeMode.END;
                label.max_width_chars = 30;
                label.get_style_context().add_provider(label_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
                row.pack_start(label, true, true, 0);

                var close_btn = new Gtk.Button.from_icon_name("window-close-symbolic", Gtk.IconSize.MENU);
                close_btn.relief = Gtk.ReliefStyle.NONE;
                close_btn.clicked.connect(() => {
                    window.close();
                    dismiss();
                });
                row.pack_end(close_btn, false, false, 0);

                var event_box = new Gtk.EventBox();
                event_box.add(row);
                event_box.button_press_event.connect((ev) => {
                    if (ev.button == 1) {
                        wm.activate_window(window);
                        dismiss();
                    }
                    return true;
                });

                box.pack_start(event_box, false, false, 0);
            }

            var theme_ref = host.popup_theme();
            popup.draw.connect((cr) => {
                PopupHelper.draw_background(cr, popup, theme_ref, 8);
                return false;
            });

            popup.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK |
                                     Gdk.EventMask.LEAVE_NOTIFY_MASK);

            popup.add(box);
            host.show_popup(popup, index, 8);

            // Mouse entering popup cancels any pending dismiss
            popup.enter_notify_event.connect((ev) => {
                cancel_dismiss();
                return false;
            });

            // Mouse leaving popup schedules a delayed dismiss
            popup.leave_notify_event.connect((ev) => {
                // Ignore leave events caused by entering child widgets
                if (ev.detail == Gdk.NotifyType.INFERIOR) return false;
                schedule_dismiss();
                return false;
            });
        }
    }
}
