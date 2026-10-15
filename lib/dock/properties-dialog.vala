namespace Dokku {
    public class PropertiesDialog : GLib.Object {
        private Gtk.Window parent;
        private AppManager app_manager;
        private ConfigManager config;
        private DockRenderer renderer;

        // Emitted when an icon change means the dock needs repainting.
        public signal void changed();

        public PropertiesDialog(Gtk.Window parent, AppManager app_manager,
                                ConfigManager config, DockRenderer renderer) {
            this.parent = parent;
            this.app_manager = app_manager;
            this.config = config;
            this.renderer = renderer;
        }

        public void show(DockItem item) {
            var dialog = new Gtk.Dialog.with_buttons("Properties: " + item.name, parent,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                null);
            dialog.set_default_size(400, -1);
            // Center on the monitor rather than on the (edge-anchored) dock
            dialog.set_position(Gtk.WindowPosition.CENTER);

            var content = dialog.get_content_area();
            content.spacing = 8;
            content.margin = 12;

            var app = app_manager.get_app(item.id);
            string? current_custom = config.get_custom_icon(item.id);
            string original_icon = app != null ? app.icon : item.icon_name;

            // App icon (clickable to browse) + name header
            var header_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
            var icon_image = IconLoader.image(item.icon_name, Gtk.IconSize.DIALOG);
            var icon_event = new Gtk.EventBox();
            icon_event.add(icon_image);
            icon_event.tooltip_text = "Click to change icon";
            header_box.pack_start(icon_event, false, false, 0);
            var name_label = new Gtk.Label("<b>" + GLib.Markup.escape_text(item.name) + "</b>");
            name_label.use_markup = true;
            name_label.halign = Gtk.Align.START;
            header_box.pack_start(name_label, false, false, 0);
            content.pack_start(header_box, false, false, 0);

            content.pack_start(new Gtk.Separator(Gtk.Orientation.HORIZONTAL), false, false, 4);

            // Properties grid
            var grid = new Gtk.Grid();
            grid.row_spacing = 6;
            grid.column_spacing = 12;
            int row = 0;

            add_row(grid, ref row, "App ID:", item.id);
            if (item.desktop_file != null && item.desktop_file != "") {
                add_row(grid, ref row, "Desktop File:", item.desktop_file, Pango.EllipsizeMode.MIDDLE);
            }
            if (app != null && app.exec != null && app.exec != "") {
                add_row(grid, ref row, "Command:", app.exec, Pango.EllipsizeMode.END);

                // File metadata: binary location, dates, size
                string? binary_path = Environment.find_program_in_path(app.exec.split(" ")[0]);
                if (binary_path != null) {
                    add_row(grid, ref row, "Location:", binary_path, Pango.EllipsizeMode.MIDDLE);
                    try {
                        var info = File.new_for_path(binary_path).query_info(
                            "time::modified,time::access,standard::size", FileQueryInfoFlags.NONE);
                        var mtime = info.get_modification_date_time();
                        if (mtime != null) {
                            add_row(grid, ref row, "Modified:", mtime.to_local().format("%Y-%m-%d %H:%M:%S"));
                        }
                        var atime_val = info.get_attribute_uint64("time::access");
                        if (atime_val > 0) {
                            var atime = new DateTime.from_unix_local((int64) atime_val);
                            add_row(grid, ref row, "Accessed:", atime.format("%Y-%m-%d %H:%M:%S"));
                        }
                        add_row(grid, ref row, "Size:", format_file_size(info.get_size()));
                    } catch (Error e) {}
                }
            }

            content.pack_start(grid, false, false, 0);

            // Icon override section
            content.pack_start(new Gtk.Separator(Gtk.Orientation.HORIZONTAL), false, false, 4);

            var icon_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            var icon_label = new Gtk.Label("Icon:");
            icon_label.halign = Gtk.Align.END;
            icon_label.get_style_context().add_class("dim-label");
            icon_box.pack_start(icon_label, false, false, 0);
            var picker = new IconPicker(dialog, item.icon_name, item.icon_name);
            icon_box.pack_start(picker, true, true, 0);

            // Clicking header icon also opens browse dialog
            icon_event.button_press_event.connect((ev) => {
                picker.browse();
                return true;
            });

            content.pack_start(icon_box, false, false, 0);

            // Close on the left; Reset / Apply grouped on the right
            var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);

            var close_btn = new Gtk.Button.with_mnemonic("_Close");
            close_btn.clicked.connect(() => dialog.response(Gtk.ResponseType.CLOSE));
            btn_box.pack_start(close_btn, false, false, 0);
            var action_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            btn_box.pack_end(action_box, false, false, 0);

            // Always visible; only enabled while a custom icon is set.
            var reset_btn = new Gtk.Button.with_label("Reset Icon");
            reset_btn.tooltip_text = "Restore the application's default icon";
            reset_btn.sensitive = current_custom != null;
            // Back to the application's own icon
            void restore_default() {
                renderer.clear_icon_cache(item.icon_name);
                config.clear_custom_icon(item.id);
                item.icon_name = original_icon;
                update_header_icon(icon_image, original_icon);
                reset_btn.sensitive = false;
                changed();
            }
            reset_btn.clicked.connect(() => {
                picker.text = original_icon;
                restore_default();
            });
            action_box.pack_start(reset_btn, false, false, 0);

            var apply_btn = new Gtk.Button.with_label("Apply Icon");
            apply_btn.get_style_context().add_class("suggested-action");
            apply_btn.clicked.connect(() => {
                string new_icon = picker.text;
                if (new_icon != "" && new_icon != original_icon) {
                    renderer.clear_icon_cache(item.icon_name);
                    config.set_custom_icon(item.id, new_icon);
                    item.icon_name = new_icon;
                    update_header_icon(icon_image, new_icon);
                    reset_btn.sensitive = true;
                    changed();
                } else if (new_icon == original_icon) {
                    restore_default();
                }
            });
            action_box.pack_start(apply_btn, false, false, 0);

            content.pack_start(btn_box, false, false, 0);

            dialog.show_all();
            dialog.run();
            dialog.destroy();
        }

        // One "Label: value" line of the properties grid
        private static void add_row(Gtk.Grid grid, ref int row, string label, string value,
                                    Pango.EllipsizeMode ellipsize = Pango.EllipsizeMode.NONE) {
            var name_label = new Gtk.Label(label);
            name_label.halign = Gtk.Align.END;
            name_label.get_style_context().add_class("dim-label");
            grid.attach(name_label, 0, row, 1, 1);
            var value_label = new Gtk.Label(value);
            value_label.halign = Gtk.Align.START;
            value_label.selectable = true;
            if (ellipsize != Pango.EllipsizeMode.NONE) {
                value_label.ellipsize = ellipsize;
                value_label.max_width_chars = 35;
            }
            grid.attach(value_label, 1, row, 1, 1);
            row++;
        }

        private static void update_header_icon(Gtk.Image image, string icon_name) {
            IconLoader.apply(image, icon_name, Gtk.IconSize.DIALOG);
        }

        private static string format_file_size(int64 size) {
            if (size < 1024) return "%s B".printf(size.to_string());
            if (size < 1024 * 1024) return "%.1f KB".printf(size / 1024.0);
            if (size < 1024 * 1024 * 1024) return "%.1f MB".printf(size / (1024.0 * 1024.0));
            return "%.1f GB".printf(size / (1024.0 * 1024.0 * 1024.0));
        }
    }
}
