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
            var dialog = new Gtk.Dialog.with_buttons("Properties — " + item.name, parent,
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

            // App ID
            var id_label = new Gtk.Label("App ID:");
            id_label.halign = Gtk.Align.END;
            id_label.get_style_context().add_class("dim-label");
            grid.attach(id_label, 0, row, 1, 1);
            var id_value = new Gtk.Label(item.id);
            id_value.halign = Gtk.Align.START;
            id_value.selectable = true;
            grid.attach(id_value, 1, row, 1, 1);
            row++;

            // Desktop file
            if (item.desktop_file != null && item.desktop_file != "") {
                var df_label = new Gtk.Label("Desktop File:");
                df_label.halign = Gtk.Align.END;
                df_label.get_style_context().add_class("dim-label");
                grid.attach(df_label, 0, row, 1, 1);
                var df_value = new Gtk.Label(item.desktop_file);
                df_value.halign = Gtk.Align.START;
                df_value.selectable = true;
                df_value.ellipsize = Pango.EllipsizeMode.MIDDLE;
                df_value.max_width_chars = 35;
                grid.attach(df_value, 1, row, 1, 1);
                row++;
            }

            // Command
            if (app != null && app.exec != null && app.exec != "") {
                var exec_label = new Gtk.Label("Command:");
                exec_label.halign = Gtk.Align.END;
                exec_label.get_style_context().add_class("dim-label");
                grid.attach(exec_label, 0, row, 1, 1);
                var exec_value = new Gtk.Label(app.exec);
                exec_value.halign = Gtk.Align.START;
                exec_value.selectable = true;
                exec_value.ellipsize = Pango.EllipsizeMode.END;
                exec_value.max_width_chars = 35;
                grid.attach(exec_value, 1, row, 1, 1);
                row++;
            }

            // File metadata: binary location, dates, size
            if (app != null && app.exec != null && app.exec != "") {
                string exec_basename = app.exec.split(" ")[0];
                string? binary_path = Environment.find_program_in_path(exec_basename);
                if (binary_path != null) {
                    // Location
                    var loc_label = new Gtk.Label("Location:");
                    loc_label.halign = Gtk.Align.END;
                    loc_label.get_style_context().add_class("dim-label");
                    grid.attach(loc_label, 0, row, 1, 1);
                    var loc_value = new Gtk.Label(binary_path);
                    loc_value.halign = Gtk.Align.START;
                    loc_value.selectable = true;
                    loc_value.ellipsize = Pango.EllipsizeMode.MIDDLE;
                    loc_value.max_width_chars = 35;
                    grid.attach(loc_value, 1, row, 1, 1);
                    row++;

                    try {
                        var file = File.new_for_path(binary_path);
                        var info = file.query_info(
                            "time::modified,time::access,standard::size",
                            FileQueryInfoFlags.NONE);

                        // Modified
                        var mtime = info.get_modification_date_time();
                        if (mtime != null) {
                            var mod_label = new Gtk.Label("Modified:");
                            mod_label.halign = Gtk.Align.END;
                            mod_label.get_style_context().add_class("dim-label");
                            grid.attach(mod_label, 0, row, 1, 1);
                            var mod_value = new Gtk.Label(mtime.to_local().format("%Y-%m-%d %H:%M:%S"));
                            mod_value.halign = Gtk.Align.START;
                            mod_value.selectable = true;
                            grid.attach(mod_value, 1, row, 1, 1);
                            row++;
                        }

                        // Accessed
                        var atime_val = info.get_attribute_uint64("time::access");
                        if (atime_val > 0) {
                            var atime = new DateTime.from_unix_local((int64)atime_val);
                            var acc_label = new Gtk.Label("Accessed:");
                            acc_label.halign = Gtk.Align.END;
                            acc_label.get_style_context().add_class("dim-label");
                            grid.attach(acc_label, 0, row, 1, 1);
                            var acc_value = new Gtk.Label(atime.format("%Y-%m-%d %H:%M:%S"));
                            acc_value.halign = Gtk.Align.START;
                            acc_value.selectable = true;
                            grid.attach(acc_value, 1, row, 1, 1);
                            row++;
                        }

                        // Size
                        int64 file_size = info.get_size();
                        var size_label = new Gtk.Label("Size:");
                        size_label.halign = Gtk.Align.END;
                        size_label.get_style_context().add_class("dim-label");
                        grid.attach(size_label, 0, row, 1, 1);
                        var size_value = new Gtk.Label(format_file_size(file_size));
                        size_value.halign = Gtk.Align.START;
                        size_value.selectable = true;
                        grid.attach(size_value, 1, row, 1, 1);
                        row++;
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

            var icon_entry = new Gtk.Entry();
            icon_entry.text = item.icon_name;
            icon_entry.hexpand = true;
            icon_box.pack_start(icon_entry, true, true, 0);

            var browse_btn = new Gtk.Button.from_icon_name("document-open-symbolic", Gtk.IconSize.BUTTON);
            browse_btn.tooltip_text = "Browse for icon";
            icon_box.pack_start(browse_btn, false, false, 0);

            var icon_preview = new Gtk.Image.from_icon_name(item.icon_name, Gtk.IconSize.LARGE_TOOLBAR);
            icon_box.pack_start(icon_preview, false, false, 0);

            // Update preview when entry changes
            icon_entry.changed.connect(() => {
                string text = icon_entry.text.strip();
                if (text.has_prefix("/") && FileUtils.test(text, FileTest.EXISTS)) {
                    try {
                        var pixbuf = new Gdk.Pixbuf.from_file_at_size(text, 24, 24);
                        icon_preview.set_from_pixbuf(pixbuf);
                    } catch (Error e) {
                        icon_preview.set_from_icon_name(text, Gtk.IconSize.LARGE_TOOLBAR);
                    }
                } else {
                    icon_preview.set_from_icon_name(text, Gtk.IconSize.LARGE_TOOLBAR);
                }
            });

            // Browse for icon file
            browse_btn.clicked.connect(() => {
                var chooser = new Gtk.FileChooserDialog("Choose Icon", dialog,
                    Gtk.FileChooserAction.OPEN,
                    "_Cancel", Gtk.ResponseType.CANCEL,
                    "_Open", Gtk.ResponseType.ACCEPT);

                var filter = new Gtk.FileFilter();
                filter.set_filter_name("Image files");
                filter.add_pattern("*.png");
                filter.add_pattern("*.svg");
                filter.add_pattern("*.xpm");
                filter.add_pattern("*.ico");
                chooser.add_filter(filter);

                var all_filter = new Gtk.FileFilter();
                all_filter.set_filter_name("All files");
                all_filter.add_pattern("*");
                chooser.add_filter(all_filter);

                chooser.set_current_folder("/usr/share/icons");

                // Preview widget
                var preview_img = new Gtk.Image();
                preview_img.set_size_request(64, 64);
                chooser.set_preview_widget(preview_img);
                chooser.update_preview.connect(() => {
                    string? path = chooser.get_preview_filename();
                    if (path != null) {
                        try {
                            var pixbuf = new Gdk.Pixbuf.from_file_at_size(path, 64, 64);
                            preview_img.set_from_pixbuf(pixbuf);
                            chooser.set_preview_widget_active(true);
                        } catch (Error e) {
                            chooser.set_preview_widget_active(false);
                        }
                    }
                });

                if (chooser.run() == Gtk.ResponseType.ACCEPT) {
                    icon_entry.text = chooser.get_filename();
                }
                chooser.destroy();
            });

            // Clicking header icon also opens browse dialog
            icon_event.button_press_event.connect((ev) => {
                browse_btn.clicked();
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
            reset_btn.clicked.connect(() => {
                renderer.clear_icon_cache(item.icon_name);
                config.clear_custom_icon(item.id);
                item.icon_name = original_icon;
                icon_entry.text = original_icon;
                update_header_icon(icon_image, original_icon);
                reset_btn.sensitive = false;
                changed();
            });
            action_box.pack_start(reset_btn, false, false, 0);

            var apply_btn = new Gtk.Button.with_label("Apply Icon");
            apply_btn.get_style_context().add_class("suggested-action");
            apply_btn.clicked.connect(() => {
                string new_icon = icon_entry.text.strip();
                if (new_icon != "" && new_icon != original_icon) {
                    renderer.clear_icon_cache(item.icon_name);
                    config.set_custom_icon(item.id, new_icon);
                    item.icon_name = new_icon;
                    update_header_icon(icon_image, new_icon);
                    reset_btn.sensitive = true;
                    changed();
                } else if (new_icon == original_icon) {
                    renderer.clear_icon_cache(item.icon_name);
                    config.clear_custom_icon(item.id);
                    item.icon_name = original_icon;
                    update_header_icon(icon_image, original_icon);
                    reset_btn.sensitive = false;
                    changed();
                }
            });
            action_box.pack_start(apply_btn, false, false, 0);

            content.pack_start(btn_box, false, false, 0);

            dialog.show_all();
            dialog.run();
            dialog.destroy();
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
