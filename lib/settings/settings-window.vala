namespace Dokku {
    public class SettingsWindow : Gtk.Window {
        private ConfigManager config;
        private AppManager app_manager;
        private ThemeManager theme_manager;
        private PluginManager plugin_manager;
        private Gtk.ComboBoxText theme_combo;
        public signal void settings_changed();

        // Debounce timer for live apply
        private uint apply_timeout_id = 0;

        // Hotkey UI components
        private HotkeyCaptureButton launcher_hotkey_button;
        private Gtk.Entry[] app_entries;
        private HotkeyCaptureButton[] app_hotkey_buttons;

        public SettingsWindow(ConfigManager config, AppManager app_manager) {
            Object(
                title: "Dokku Settings",
                default_width: 500,
                default_height: 560,
                resizable: false
            );
            this.config = config;
            this.app_manager = app_manager;
            this.theme_manager = new ThemeManager();
            this.plugin_manager = new PluginManager(config);
            apply_css();
            build_ui();

            // Set X11 atoms so picom rules reliably match this window
            // (_DOKKU_WINDOW@ rule disables blur and shadow)
            this.realize.connect(() => {
                var gdk_window = get_window();
                if (gdk_window == null) return;
                var display = gdk_window.get_display();
                if (!(display is Gdk.X11.Display)) return;
                unowned X.Display xdisplay = ((Gdk.X11.Display) display).get_xdisplay();
                X.Window xid = ((Gdk.X11.Window) gdk_window).get_xid();

                X.Atom dock_atom = xdisplay.intern_atom("_DOKKU_WINDOW", false);
                uchar[] dock_val = { 1, 0, 0, 0 };
                xdisplay.change_property(xid, dock_atom, X.XA_CARDINAL, 32,
                                          X.PropMode.Replace, dock_val, 1);

                X.Atom shadow_atom = xdisplay.intern_atom("_COMPTON_SHADOW", false);
                uchar[] shadow_off = { 0, 0, 0, 0 };
                xdisplay.change_property(xid, shadow_atom, X.XA_CARDINAL, 32,
                                          X.PropMode.Replace, shadow_off, 1);

                xdisplay.flush();
            });

            this.hide.connect(flush_apply);
        }

        private void schedule_apply() {
            if (apply_timeout_id != 0) {
                Source.remove(apply_timeout_id);
            }
            apply_timeout_id = Timeout.add(100, () => {
                apply_timeout_id = 0;
                settings_changed();
                return false;
            });
        }

        private void flush_apply() {
            if (apply_timeout_id != 0) {
                Source.remove(apply_timeout_id);
                apply_timeout_id = 0;
                settings_changed();
            }
        }

        // --- CSS ---

        private static bool css_applied = false;

        private void apply_css() {
            if (css_applied) return;
            css_applied = true;
            var css = new Gtk.CssProvider();
            try {
                css.load_from_data("""
                    .settings-card {
                        background: @theme_base_color;
                        border-radius: 10px;
                        border: 1px solid alpha(@borders, 0.15);
                        padding: 8px 12px;
                    }
                """);
                Gtk.StyleContext.add_provider_for_screen(
                    Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                );
            } catch (Error e) {}
        }

        // --- UI Helpers ---

        private Gtk.Box make_setting_label(string title, string subtitle) {
            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            box.halign = Gtk.Align.START;
            box.valign = Gtk.Align.CENTER;
            var title_label = new Gtk.Label(title);
            title_label.halign = Gtk.Align.START;
            var sub_label = new Gtk.Label("<small>%s</small>".printf(subtitle));
            sub_label.use_markup = true;
            sub_label.halign = Gtk.Align.START;
            sub_label.get_style_context().add_class("dim-label");
            box.pack_start(title_label, false, false, 0);
            box.pack_start(sub_label, false, false, 0);
            return box;
        }

        private Gtk.Label make_section_header(string title, bool first = false) {
            var label = new Gtk.Label("<b>%s</b>".printf(title));
            label.use_markup = true;
            label.halign = Gtk.Align.START;
            label.margin_top = first ? 0 : 18;
            label.margin_bottom = 6;
            return label;
        }

        private Gtk.Box make_card() {
            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            card.get_style_context().add_class("settings-card");
            return card;
        }

        private Gtk.Grid make_card_grid(int columns = 2) {
            var grid = new Gtk.Grid();
            grid.row_spacing = 10;
            grid.column_spacing = 12;
            return grid;
        }

        // --- Build UI ---

        private void build_ui() {
            var header = new Gtk.HeaderBar();
            header.title = "Settings";
            header.show_close_button = true;

            var info_btn = new Gtk.Button.from_icon_name("help-about-symbolic", Gtk.IconSize.BUTTON);
            info_btn.tooltip_text = "About Dokku";
            info_btn.clicked.connect(show_about_dialog);
            header.pack_end(info_btn);

            set_titlebar(header);

            var notebook = new Gtk.Notebook();
            notebook.margin = 12;

            notebook.append_page(create_appearance_tab(), new Gtk.Label("Appearance"));
            notebook.append_page(create_behavior_tab(), new Gtk.Label("Behavior"));
            notebook.append_page(create_shortcuts_tab(), new Gtk.Label("Shortcuts"));

            add(notebook);
        }

        // --- Appearance Tab ---

        private Gtk.Widget create_appearance_tab() {
            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            outer.margin = 16;

            // --- Layout section ---
            outer.pack_start(make_section_header("Layout", true), false, false, 0);

            var layout_card = make_card();
            var layout_grid = make_card_grid();

            int row = 0;

            // Position
            layout_grid.attach(make_setting_label("Position", "Which edge of the screen to place the dock"), 0, row, 1, 1);
            var position_combo = new Gtk.ComboBoxText();
            position_combo.append("bottom", "Bottom");
            position_combo.append("top", "Top");
            position_combo.append("left", "Left");
            position_combo.append("right", "Right");
            position_combo.active_id = config.get_position();
            position_combo.valign = Gtk.Align.CENTER;
            position_combo.changed.connect(() => {
                config.set_position(position_combo.active_id);
                schedule_apply();
            });
            layout_grid.attach(position_combo, 1, row++, 1, 1);

            // Icon size
            layout_grid.attach(make_setting_label("Icon size", "Size of dock icons in pixels"), 0, row, 1, 1);
            var size_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 32, 72, 4);
            size_scale.set_value(config.get_icon_size());
            size_scale.hexpand = true;
            size_scale.value_changed.connect(() => {
                config.set_icon_size((int)size_scale.get_value());
                schedule_apply();
            });
            layout_grid.attach(size_scale, 1, row++, 1, 1);

            // Magnification
            layout_grid.attach(make_setting_label("Magnification", "Enlarge icons when hovering over them"), 0, row, 1, 1);
            var mag_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            mag_box.valign = Gtk.Align.CENTER;
            var mag_switch = new Gtk.Switch();
            double cur_mag = config.get_magnification();
            mag_switch.active = cur_mag > 1.0;
            mag_switch.valign = Gtk.Align.CENTER;

            var mag_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 1.2, 2.0, 0.1);
            mag_scale.set_value(cur_mag > 1.0 ? cur_mag : 1.5);
            mag_scale.hexpand = true;
            mag_scale.sensitive = mag_switch.active;

            mag_switch.notify["active"].connect(() => {
                mag_scale.sensitive = mag_switch.active;
                config.set_magnification(mag_switch.active ? mag_scale.get_value() : 1.0);
                schedule_apply();
            });
            mag_scale.value_changed.connect(() => {
                if (mag_switch.active) {
                    config.set_magnification(mag_scale.get_value());
                    schedule_apply();
                }
            });

            mag_box.pack_start(mag_switch, false, false, 0);
            mag_box.pack_start(mag_scale, true, true, 0);
            layout_grid.attach(mag_box, 1, row++, 1, 1);

            layout_card.pack_start(layout_grid, true, true, 0);
            outer.pack_start(layout_card, false, false, 0);

            // --- Style section ---
            outer.pack_start(make_section_header("Style"), false, false, 0);

            var style_card = make_card();
            var style_grid = make_card_grid();

            row = 0;

            // Theme
            style_grid.attach(make_setting_label("Theme", "Visual style for the dock background"), 0, row, 1, 1);
            var theme_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            theme_box.valign = Gtk.Align.CENTER;
            theme_combo = new Gtk.ComboBoxText();
            refresh_theme_list();
            theme_combo.changed.connect(() => {
                config.set_theme(theme_combo.active_id);
                schedule_apply();
            });
            theme_combo.hexpand = true;
            theme_box.pack_start(theme_combo, true, true, 0);

            var install_btn = new Gtk.Button.from_icon_name("folder-open-symbolic", Gtk.IconSize.BUTTON);
            install_btn.tooltip_text = "Install theme from file";
            install_btn.clicked.connect(on_install_theme);
            theme_box.pack_start(install_btn, false, false, 0);
            style_grid.attach(theme_box, 1, row++, 1, 1);

            // Dock opacity
            style_grid.attach(make_setting_label("Dock opacity", "Background transparency level"), 0, row, 1, 1);
            var opacity_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 0.0, 1.0, 0.05);
            opacity_scale.set_value(config.get_dock_opacity());
            opacity_scale.hexpand = true;
            opacity_scale.set_draw_value(true);
            opacity_scale.set_value_pos(Gtk.PositionType.RIGHT);
            opacity_scale.format_value.connect((val) => {
                return "%d%%".printf((int)(val * 100));
            });
            opacity_scale.value_changed.connect(() => {
                config.set_dock_opacity(opacity_scale.get_value());
                schedule_apply();
            });
            style_grid.attach(opacity_scale, 1, row++, 1, 1);

            // Frosted glass (compositor blur)
            style_grid.attach(make_setting_label("Frosted glass", "Requires a compositor with blur support (e.g. Picom)"), 0, row, 1, 1);
            var blur_switch = new Gtk.Switch();
            blur_switch.active = config.get_blur_enabled();
            blur_switch.halign = Gtk.Align.START;
            blur_switch.valign = Gtk.Align.CENTER;
            blur_switch.notify["active"].connect(() => {
                config.set_blur_enabled(blur_switch.active);
                schedule_apply();
            });
            style_grid.attach(blur_switch, 1, row++, 1, 1);

            // Rounded corners
            style_grid.attach(make_setting_label("Rounded corners", "Round the edges of the dock background"), 0, row, 1, 1);
            var corners_switch = new Gtk.Switch();
            corners_switch.active = config.get_rounded_corners();
            corners_switch.halign = Gtk.Align.START;
            corners_switch.valign = Gtk.Align.CENTER;
            corners_switch.notify["active"].connect(() => {
                config.set_rounded_corners(corners_switch.active);
                schedule_apply();
            });
            style_grid.attach(corners_switch, 1, row++, 1, 1);

            style_card.pack_start(style_grid, true, true, 0);
            outer.pack_start(style_card, false, false, 0);

            return outer;
        }

        private void refresh_theme_list() {
            theme_combo.remove_all();
            foreach (var theme in theme_manager.get_all_themes()) {
                theme_combo.append(theme.id, theme.name);
            }
            theme_combo.active_id = config.get_theme();
        }

        private void on_install_theme() {
            var dialog = new Gtk.FileChooserDialog(
                "Install Theme", this, Gtk.FileChooserAction.OPEN,
                "_Cancel", Gtk.ResponseType.CANCEL,
                "_Open", Gtk.ResponseType.ACCEPT
            );

            var filter = new Gtk.FileFilter();
            filter.set_filter_name("Theme files (*.zip)");
            filter.add_pattern("*.zip");
            dialog.add_filter(filter);

            if (dialog.run() == Gtk.ResponseType.ACCEPT) {
                var path = dialog.get_filename();
                if (theme_manager.install_theme(path)) {
                    refresh_theme_list();
                }
            }
            dialog.destroy();
        }

        // --- Behavior Tab ---

        private Gtk.Widget create_behavior_tab() {
            var scroll = new Gtk.ScrolledWindow(null, null);
            scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            outer.margin = 16;

            // --- Visibility section ---
            outer.pack_start(make_section_header("Visibility", true), false, false, 0);

            var vis_card = make_card();
            var vis_grid = make_card_grid();
            int row = 0;

            // Auto-hide
            vis_grid.attach(make_setting_label("Auto-hide", "Hide the dock when not in use"), 0, row, 1, 1);
            var hide_switch = new Gtk.Switch();
            hide_switch.active = config.get_auto_hide();
            hide_switch.halign = Gtk.Align.START;
            hide_switch.valign = Gtk.Align.CENTER;
            hide_switch.notify["active"].connect(() => {
                config.set_auto_hide(hide_switch.active);
                schedule_apply();
            });
            vis_grid.attach(hide_switch, 1, row++, 1, 1);

            // Dodge windows
            vis_grid.attach(make_setting_label("Dodge windows", "Hide when a window overlaps the dock"), 0, row, 1, 1);
            var dodge_switch = new Gtk.Switch();
            dodge_switch.active = config.get_dodge_windows();
            dodge_switch.halign = Gtk.Align.START;
            dodge_switch.valign = Gtk.Align.CENTER;
            dodge_switch.notify["active"].connect(() => {
                config.set_dodge_windows(dodge_switch.active);
                schedule_apply();
            });
            vis_grid.attach(dodge_switch, 1, row++, 1, 1);

            // Hide delay
            vis_grid.attach(make_setting_label("Hide delay", "Milliseconds before the dock hides"), 0, row, 1, 1);
            var delay_spin = new Gtk.SpinButton.with_range(0, 2000, 100);
            delay_spin.value = config.get_hide_delay();
            delay_spin.valign = Gtk.Align.CENTER;
            delay_spin.value_changed.connect(() => {
                config.set_hide_delay((int)delay_spin.value);
                schedule_apply();
            });
            vis_grid.attach(delay_spin, 1, row++, 1, 1);

            // Show on all monitors
            vis_grid.attach(make_setting_label("Show on all monitors", "Display the dock on every connected display"), 0, row, 1, 1);
            var multi_switch = new Gtk.Switch();
            multi_switch.active = config.get_multi_monitor();
            multi_switch.halign = Gtk.Align.START;
            multi_switch.valign = Gtk.Align.CENTER;
            multi_switch.notify["active"].connect(() => {
                config.set_multi_monitor(multi_switch.active);
                schedule_apply();
            });
            vis_grid.attach(multi_switch, 1, row++, 1, 1);

            vis_card.pack_start(vis_grid, true, true, 0);
            outer.pack_start(vis_card, false, false, 0);

            // --- Animations section ---
            outer.pack_start(make_section_header("Animations"), false, false, 0);

            var anim_card = make_card();
            var anim_grid = make_card_grid();
            row = 0;

            // Bounce on launch
            anim_grid.attach(make_setting_label("Bounce on launch", "Bounce icon when opening an application"), 0, row, 1, 1);
            var bounce_switch = new Gtk.Switch();
            bounce_switch.active = config.get_launch_bounce();
            bounce_switch.halign = Gtk.Align.START;
            bounce_switch.valign = Gtk.Align.CENTER;
            bounce_switch.notify["active"].connect(() => {
                config.set_launch_bounce(bounce_switch.active);
                schedule_apply();
            });
            anim_grid.attach(bounce_switch, 1, row++, 1, 1);

            // Launcher fade
            anim_grid.attach(make_setting_label("Launcher fade", "Fade animation when opening the app launcher"), 0, row, 1, 1);
            var fade_switch = new Gtk.Switch();
            fade_switch.active = config.get_launcher_fade();
            fade_switch.halign = Gtk.Align.START;
            fade_switch.valign = Gtk.Align.CENTER;
            fade_switch.notify["active"].connect(() => {
                config.set_launcher_fade(fade_switch.active);
            });
            anim_grid.attach(fade_switch, 1, row++, 1, 1);

            anim_card.pack_start(anim_grid, true, true, 0);
            outer.pack_start(anim_card, false, false, 0);

            // --- Dock Items section ---
            outer.pack_start(make_section_header("Dock Items"), false, false, 0);

            var items_card = make_card();
            var items_grid = make_card_grid();
            row = 0;

            // Media widget
            items_grid.attach(make_setting_label("Media widget", "Show media player controls on the dock"), 0, row, 1, 1);
            var media_switch = new Gtk.Switch();
            media_switch.active = config.get_media_widget();
            media_switch.halign = Gtk.Align.START;
            media_switch.valign = Gtk.Align.CENTER;
            media_switch.notify["active"].connect(() => {
                config.set_media_widget(media_switch.active);
                schedule_apply();
            });
            items_grid.attach(media_switch, 1, row++, 1, 1);

            // Notification badges
            items_grid.attach(make_setting_label("Notification badges", "Show unread count on app icons"), 0, row, 1, 1);
            var badge_switch = new Gtk.Switch();
            badge_switch.active = config.get_notification_badges();
            badge_switch.halign = Gtk.Align.START;
            badge_switch.valign = Gtk.Align.CENTER;
            badge_switch.notify["active"].connect(() => {
                config.set_notification_badges(badge_switch.active);
                schedule_apply();
            });
            items_grid.attach(badge_switch, 1, row++, 1, 1);

            // Separator
            items_grid.attach(make_setting_label("Separator", "Divider between pinned and running apps"), 0, row, 1, 1);
            var sep_switch = new Gtk.Switch();
            sep_switch.active = config.get_plugin_enabled("separator");
            sep_switch.halign = Gtk.Align.START;
            sep_switch.valign = Gtk.Align.CENTER;
            sep_switch.notify["active"].connect(() => {
                config.set_plugin_enabled("separator", sep_switch.active);
                schedule_apply();
            });
            items_grid.attach(sep_switch, 1, row++, 1, 1);

            // Show Desktop
            items_grid.attach(make_setting_label("Show Desktop", "Button to minimize all windows"), 0, row, 1, 1);
            var desktop_switch = new Gtk.Switch();
            desktop_switch.active = config.get_plugin_enabled("show-desktop");
            desktop_switch.halign = Gtk.Align.START;
            desktop_switch.valign = Gtk.Align.CENTER;
            desktop_switch.notify["active"].connect(() => {
                config.set_plugin_enabled("show-desktop", desktop_switch.active);
                schedule_apply();
            });
            items_grid.attach(desktop_switch, 1, row++, 1, 1);

            // Trash
            items_grid.attach(make_setting_label("Trash", "Quick access to the trash can"), 0, row, 1, 1);
            var trash_switch = new Gtk.Switch();
            trash_switch.active = config.get_plugin_enabled("trash");
            trash_switch.halign = Gtk.Align.START;
            trash_switch.valign = Gtk.Align.CENTER;
            trash_switch.notify["active"].connect(() => {
                config.set_plugin_enabled("trash", trash_switch.active);
                schedule_apply();
            });
            items_grid.attach(trash_switch, 1, row++, 1, 1);

            // User plugins
            foreach (var plugin in plugin_manager.get_user_plugins()) {
                items_grid.attach(make_setting_label(plugin.name, "User-installed plugin"), 0, row, 1, 1);
                var sw = new Gtk.Switch();
                sw.active = config.get_plugin_enabled(plugin.id);
                sw.halign = Gtk.Align.START;
                sw.valign = Gtk.Align.CENTER;
                var pid = plugin.id;
                sw.notify["active"].connect(() => {
                    config.set_plugin_enabled(pid, sw.active);
                    schedule_apply();
                });
                items_grid.attach(sw, 1, row++, 1, 1);
            }

            // Action buttons
            var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            btn_box.margin_top = 4;

            var install_plugin_btn = new Gtk.Button.with_label("Install Plugin...");
            install_plugin_btn.clicked.connect(on_install_plugin);
            btn_box.pack_start(install_plugin_btn, false, false, 0);

            var create_folder_btn = new Gtk.Button.with_label("Create Folder...");
            create_folder_btn.clicked.connect(() => on_create_folder());
            btn_box.pack_start(create_folder_btn, false, false, 0);

            items_grid.attach(btn_box, 0, row++, 2, 1);

            items_card.pack_start(items_grid, true, true, 0);
            outer.pack_start(items_card, false, false, 0);

            // --- Launcher section ---
            outer.pack_start(make_section_header("Launcher"), false, false, 0);

            var launcher_card = make_card();
            var launcher_grid = make_card_grid();
            row = 0;

            // Hidden apps
            launcher_grid.attach(make_setting_label("Hidden apps", "Apps hidden from the application launcher"), 0, row, 1, 1);
            var hidden_btn = new Gtk.Button.with_label("Manage...");
            hidden_btn.halign = Gtk.Align.START;
            hidden_btn.valign = Gtk.Align.CENTER;
            hidden_btn.clicked.connect(show_hidden_apps_dialog);
            launcher_grid.attach(hidden_btn, 1, row++, 1, 1);

            launcher_card.pack_start(launcher_grid, true, true, 0);
            outer.pack_start(launcher_card, false, false, 0);

            scroll.add(outer);
            return scroll;
        }

        private void on_install_plugin() {
            var dialog = new Gtk.FileChooserDialog(
                "Install Plugin", this, Gtk.FileChooserAction.OPEN,
                "_Cancel", Gtk.ResponseType.CANCEL,
                "_Open", Gtk.ResponseType.ACCEPT
            );

            var filter = new Gtk.FileFilter();
            filter.set_filter_name("Plugin files (*.zip)");
            filter.add_pattern("*.zip");
            dialog.add_filter(filter);

            if (dialog.run() == Gtk.ResponseType.ACCEPT) {
                if (plugin_manager.install_plugin(dialog.get_filename())) {
                    schedule_apply();
                }
            }
            dialog.destroy();
        }

        // --- Hidden Apps Dialog ---

        private void show_hidden_apps_dialog() {
            var dialog = new Gtk.Dialog.with_buttons("Hidden Apps", this,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                "_Close", Gtk.ResponseType.CLOSE);
            dialog.set_default_size(350, 400);

            var content = dialog.get_content_area();
            content.margin = 12;
            content.spacing = 8;

            var label = new Gtk.Label("Hidden apps won't appear in the launcher.\nRight-click an app in launcher to hide it.");
            label.halign = Gtk.Align.START;
            label.margin_bottom = 8;
            content.pack_start(label, false, false, 0);

            var scroll = new Gtk.ScrolledWindow(null, null);
            scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
            scroll.vexpand = true;

            var list = new Gtk.ListBox();
            list.selection_mode = Gtk.SelectionMode.NONE;
            scroll.add(list);
            content.pack_start(scroll, true, true, 0);

            populate_hidden_list(list);

            dialog.show_all();
            dialog.run();
            dialog.destroy();
        }

        private void populate_hidden_list(Gtk.ListBox list) {
            list.foreach((w) => list.remove(w));

            var hidden_ids = config.get_hidden_apps();
            foreach (var app_id in hidden_ids) {
                var app = app_manager.get_app(app_id);
                string name = app != null ? app.name : app_id;

                var row_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
                row_box.margin = 6;

                var app_label = new Gtk.Label(name);
                app_label.halign = Gtk.Align.START;
                app_label.hexpand = true;
                row_box.pack_start(app_label, true, true, 0);

                var unhide_btn = new Gtk.Button.with_label("Unhide");
                var aid = app_id;
                unhide_btn.clicked.connect(() => {
                    config.unhide_app(aid);
                    populate_hidden_list(list);
                });
                row_box.pack_end(unhide_btn, false, false, 0);

                list.add(row_box);
            }

            if (hidden_ids.length == 0) {
                var empty = new Gtk.Label("No hidden apps");
                empty.margin = 20;
                list.add(empty);
            }

            list.show_all();
        }

        // --- Shortcuts Tab ---

        private Gtk.Widget create_shortcuts_tab() {
            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            outer.margin = 16;

            // Initialize arrays
            app_entries = new Gtk.Entry[4];
            app_hotkey_buttons = new HotkeyCaptureButton[4];

            // --- Launcher Hotkey section ---
            outer.pack_start(make_section_header("Launcher Hotkey", true), false, false, 0);

            var launcher_card = make_card();
            var launcher_grid = make_card_grid();
            int row = 0;

            launcher_grid.attach(make_setting_label("Toggle launcher", "Global shortcut to open the app launcher"), 0, row, 1, 1);

            launcher_hotkey_button = new HotkeyCaptureButton(config.get_launcher_hotkey());
            launcher_hotkey_button.hexpand = true;
            launcher_hotkey_button.hotkey_changed.connect((new_hotkey) => {
                var conflict = check_hotkey_conflict(new_hotkey, "launcher");
                if (conflict != null) {
                    show_conflict_dialog(new_hotkey, conflict);
                    launcher_hotkey_button.revert_hotkey(config.get_launcher_hotkey());
                } else {
                    config.set_launcher_hotkey(new_hotkey);
                    schedule_apply();
                }
            });
            launcher_grid.attach(launcher_hotkey_button, 1, row, 2, 1);

            var launcher_clear_btn = new Gtk.Button.with_label("Clear");
            launcher_clear_btn.clicked.connect(() => {
                launcher_hotkey_button.clear();
                config.set_launcher_hotkey("");
                schedule_apply();
            });
            launcher_grid.attach(launcher_clear_btn, 3, row++, 1, 1);

            launcher_card.pack_start(launcher_grid, true, true, 0);
            outer.pack_start(launcher_card, false, false, 0);

            // --- Application Hotkeys section ---
            outer.pack_start(make_section_header("Application Hotkeys"), false, false, 0);

            var app_card = make_card();
            var app_grid = make_card_grid();
            row = 0;

            // Create 4 app hotkey slots
            for (int i = 0; i < 4; i++) {
                int slot = i + 1;

                app_grid.attach(make_setting_label("Slot %d".printf(slot), "Assign an app and shortcut"), 0, row, 1, 1);

                // App entry + browse button
                var entry_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
                entry_box.hexpand = true;

                var entry = new Gtk.Entry();
                entry.hexpand = true;
                entry.placeholder_text = "App name or /path/to/binary";
                app_entries[i] = entry;

                string current_app_id = config.get_app_hotkey_id(slot);
                entry.text = display_for_app_id(current_app_id);

                entry.activate.connect(() => {
                    on_app_entry_activate(slot);
                });
                entry.focus_out_event.connect(() => {
                    on_app_entry_activate(slot);
                    return false;
                });

                entry_box.pack_start(entry, true, true, 0);

                var browse_btn = new Gtk.Button.with_label("Browse");
                browse_btn.clicked.connect(() => {
                    on_browse_app(slot);
                });
                entry_box.pack_start(browse_btn, false, false, 0);

                app_grid.attach(entry_box, 1, row, 1, 1);

                // Hotkey capture button
                string current_hotkey = config.get_app_hotkey(slot);

                var hotkey_button = new HotkeyCaptureButton(current_hotkey);
                hotkey_button.sensitive = (current_app_id != "");
                app_hotkey_buttons[i] = hotkey_button;

                hotkey_button.hotkey_changed.connect((new_hotkey) => {
                    string exclude_key = "app_%d".printf(slot);
                    var conflict = check_hotkey_conflict(new_hotkey, exclude_key);
                    if (conflict != null) {
                        show_conflict_dialog(new_hotkey, conflict);
                        hotkey_button.revert_hotkey(config.get_app_hotkey(slot));
                    } else {
                        config.set_app_hotkey(slot, new_hotkey);
                        schedule_apply();
                    }
                });

                app_grid.attach(hotkey_button, 2, row, 1, 1);

                // Clear button
                var clear_btn = new Gtk.Button.with_label("Clear");
                clear_btn.clicked.connect(() => {
                    on_clear_app_slot(slot);
                });
                app_grid.attach(clear_btn, 3, row++, 1, 1);
            }

            app_card.pack_start(app_grid, true, true, 0);
            outer.pack_start(app_card, false, false, 0);

            return outer;
        }

        // --- About Dialog ---

        private void show_about_dialog() {
            var dialog = new Gtk.Dialog.with_buttons("About Dokku", this,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                "_Close", Gtk.ResponseType.CLOSE);
            dialog.set_default_size(360, -1);
            dialog.resizable = false;

            var content = dialog.get_content_area();

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 16);
            box.margin = 32;
            box.halign = Gtk.Align.CENTER;
            box.valign = Gtk.Align.CENTER;

            var title = new Gtk.Label("<span size='xx-large' weight='bold'>Dokku</span>");
            title.use_markup = true;
            box.pack_start(title, false, false, 0);

            var version = new Gtk.Label("Version 0.1.3");
            version.get_style_context().add_class("dim-label");
            box.pack_start(version, false, false, 0);

            var desc = new Gtk.Label("A lightweight and configurable dock for XFCE4");
            desc.wrap = true;
            desc.justify = Gtk.Justification.CENTER;
            desc.margin_top = 12;
            box.pack_start(desc, false, false, 0);

            // Donation section
            var donation_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            donation_box.margin_top = 24;
            donation_box.margin_bottom = 12;

            var donation_label = new Gtk.Label("If you're enjoying this application, please consider supporting its development");
            donation_label.wrap = true;
            donation_label.justify = Gtk.Justification.CENTER;
            donation_label.get_style_context().add_class("dim-label");
            donation_box.pack_start(donation_label, false, false, 0);

            var kofi_button = new Gtk.Button.with_label("Support me on Ko-fi");
            kofi_button.get_style_context().add_class("suggested-action");
            kofi_button.margin_top = 8;
            kofi_button.clicked.connect(() => {
                try {
                    Gtk.show_uri_on_window(this, "https://ko-fi.com/yarisg", Gdk.CURRENT_TIME);
                } catch (Error e) {
                    stderr.printf("Failed to open Ko-fi link: %s\n", e.message);
                }
            });
            donation_box.pack_start(kofi_button, false, false, 0);

            box.pack_start(donation_box, false, false, 0);

            // Links section
            var links_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
            links_box.margin_top = 12;

            var author = new Gtk.Label("<b>Author:</b> Yaris Gutierrez");
            author.use_markup = true;
            links_box.pack_start(author, false, false, 0);

            var email = new Gtk.LinkButton.with_label("mailto:yarisgutierrez@gmail.com", "yarisgutierrez@gmail.com");
            links_box.pack_start(email, false, false, 0);

            var website = new Gtk.LinkButton.with_label("https://yaris.io", "yaris.io");
            links_box.pack_start(website, false, false, 0);

            var github = new Gtk.LinkButton.with_label("https://github.com/yarisgutierrez/Dokku", "GitHub Repository");
            links_box.pack_start(github, false, false, 0);

            box.pack_start(links_box, false, false, 0);

            var copyright = new Gtk.Label("Copyright © 2026");
            copyright.margin_top = 16;
            copyright.get_style_context().add_class("dim-label");
            box.pack_start(copyright, false, false, 0);

            var license = new Gtk.Label("<small>Licensed under GPL-3.0</small>");
            license.use_markup = true;
            license.get_style_context().add_class("dim-label");
            box.pack_start(license, false, false, 0);

            content.pack_start(box, true, true, 0);

            dialog.show_all();
            dialog.run();
            dialog.destroy();
        }

        // --- Hotkey Helpers ---

        private string display_for_app_id(string app_id) {
            if (app_id == "") return "";
            if (app_id.has_prefix("/")) return app_id;
            var app = app_manager.get_app(app_id);
            return app != null ? app.name : app_id;
        }

        private string resolve_entry_text(string text) {
            string trimmed = text.strip();
            if (trimmed == "") return "";
            // Absolute path — store as-is
            if (trimmed.has_prefix("/")) return trimmed;
            // Try to find by display name
            var app = app_manager.find_by_name(trimmed);
            if (app != null) return app.id;
            // Try as an app ID directly
            app = app_manager.get_app(trimmed);
            if (app != null) return app.id;
            // Store as-is (could be a command name like "xterm")
            return trimmed;
        }

        private void on_app_entry_activate(int slot) {
            var entry = app_entries[slot - 1];
            string resolved = resolve_entry_text(entry.text);
            config.set_app_hotkey_id(slot, resolved);

            // Normalize display
            entry.text = display_for_app_id(resolved);

            var hotkey_button = app_hotkey_buttons[slot - 1];
            hotkey_button.sensitive = (resolved != "");

            if (resolved == "") {
                hotkey_button.clear();
                config.set_app_hotkey(slot, "");
            }

            schedule_apply();
        }

        private void on_browse_app(int slot) {
            var dialog = new Gtk.FileChooserDialog(
                "Choose Application", this, Gtk.FileChooserAction.OPEN,
                "_Cancel", Gtk.ResponseType.CANCEL,
                "_Open", Gtk.ResponseType.ACCEPT
            );
            dialog.set_current_folder("/usr/bin");

            if (dialog.run() == Gtk.ResponseType.ACCEPT) {
                string path = dialog.get_filename();
                app_entries[slot - 1].text = path;
                config.set_app_hotkey_id(slot, path);
                app_hotkey_buttons[slot - 1].sensitive = true;
                schedule_apply();
            }
            dialog.destroy();
        }

        private void on_clear_app_slot(int slot) {
            app_entries[slot - 1].text = "";
            app_hotkey_buttons[slot - 1].clear();
            config.set_app_hotkey_id(slot, "");
            config.set_app_hotkey(slot, "");
            schedule_apply();
        }

        private string? check_hotkey_conflict(string hotkey, string exclude_key) {
            if (hotkey == "") return null;

            if (exclude_key != "launcher" && config.get_launcher_hotkey() == hotkey) {
                return "Launcher";
            }

            for (int i = 0; i < 4; i++) {
                string key = "app_%d".printf(i + 1);
                string slot_hotkey = config.get_app_hotkey(i + 1);
                if (exclude_key != key && slot_hotkey == hotkey && slot_hotkey != "") {
                    var app = app_manager.get_app(config.get_app_hotkey_id(i + 1));
                    return app != null ? app.name : "Slot %d".printf(i + 1);
                }
            }

            return null;
        }

        private void show_conflict_dialog(string hotkey, string conflicting_action) {
            var dialog = new Gtk.MessageDialog(
                this,
                Gtk.DialogFlags.MODAL,
                Gtk.MessageType.WARNING,
                Gtk.ButtonsType.OK,
                "Hotkey Conflict"
            );
            dialog.secondary_text = "The hotkey '%s' is already assigned to '%s'.\n\nPlease choose a different hotkey.".printf(hotkey, conflicting_action);
            dialog.run();
            dialog.destroy();
        }

        private void on_create_folder() {
            var dialog = new Gtk.Dialog.with_buttons("New Folder", this,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                "_Cancel", Gtk.ResponseType.CANCEL,
                "_Create", Gtk.ResponseType.OK);
            dialog.set_default_response(Gtk.ResponseType.OK);

            var entry = new Gtk.Entry();
            entry.placeholder_text = "Folder name";
            entry.margin = 12;
            entry.activates_default = true;
            dialog.get_content_area().add(entry);
            dialog.show_all();

            if (dialog.run() == Gtk.ResponseType.OK) {
                string name = entry.text.strip();
                if (name != "") {
                    string folder_id = "f_%s".printf(new DateTime.now_utc().to_unix().to_string());
                    config.create_folder(folder_id, name, {});
                    // Add folder reference to pinned apps list
                    var pinned = config.get_pinned_apps();
                    string[] new_pinned = {};
                    foreach (var p in pinned) new_pinned += p;
                    new_pinned += "folder:" + folder_id;
                    config.set_pinned_apps(new_pinned);
                    schedule_apply();
                }
            }
            dialog.destroy();
        }
    }
}
