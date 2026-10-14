namespace Dokku {
    public class SettingsWindow : Gtk.Window {
        private ConfigManager config;
        private AppManager app_manager;
        private ThemeManager theme_manager;
        private PluginManager plugin_manager;
        private Gtk.ComboBoxText theme_combo;
        private Gtk.Notebook? notebook = null;
        public signal void settings_changed();

        // Debounce timer for live apply
        private uint apply_timeout_id = 0;

        // Hotkey UI components
        private HotkeyCaptureButton launcher_hotkey_button;
        private Gtk.Entry[] app_entries;
        private HotkeyCaptureButton[] app_hotkey_buttons;

        public SettingsWindow(ConfigManager config, AppManager app_manager,
                              PluginManager plugin_manager, ThemeManager theme_manager) {
            Object(
                title: "Dokku Settings",
                default_width: 500,
                default_height: 560,
                resizable: false
            );
            this.config = config;
            this.app_manager = app_manager;
            this.theme_manager = theme_manager;
            this.plugin_manager = plugin_manager;
            apply_css();
            build_ui();

            // Tag the window so picom rules for Dokku windows (no blur, no shadow) match it
            this.realize.connect(() => {
                var gdk_window = get_window();
                if (gdk_window != null) CompositorHints.apply(gdk_window, false);
            });

            this.hide.connect(flush_apply);

            // The Monitors section lists what is connected, so it follows hot-plug
            var screen_display = Gdk.Display.get_default();
            if (screen_display != null) {
                screen_display.monitor_added.connect(() => schedule_monitor_refresh());
                screen_display.monitor_removed.connect(() => schedule_monitor_refresh());
            }
        }

        private uint monitor_refresh_id = 0;

        private void schedule_monitor_refresh() {
            if (monitor_refresh_id != 0) return;
            monitor_refresh_id = Timeout.add(500, () => {
                monitor_refresh_id = 0;
                rebuild_ui();
                return Source.REMOVE;
            });
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

        public delegate void BoolSetter(bool value);

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

        // Subtitle for a setting: the reason it is unavailable in this session, or `normal`.
        private string subtitle_for(Feature feature, string normal) {
            return Capabilities.current.why_not(feature) ?? normal;
        }

        private Gtk.Label make_section_header(string title, bool first = false) {
            var label = new Gtk.Label("<b>%s</b>".printf(title));
            label.use_markup = true;
            label.halign = Gtk.Align.START;
            label.margin_top = first ? 0 : 18;
            label.margin_bottom = 6;
            return label;
        }

        private Gtk.Box make_card(out Gtk.Grid grid) {
            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            card.get_style_context().add_class("settings-card");
            grid = new Gtk.Grid();
            grid.row_spacing = 10;
            grid.column_spacing = 12;
            card.pack_start(grid, true, true, 0);
            return card;
        }

        // A titled card on `outer`; the settings go in the grid it returns
        private Gtk.Grid add_section(Gtk.Box outer, string title, bool first = false) {
            Gtk.Grid grid;
            outer.pack_start(make_section_header(title, first), false, false, 0);
            outer.pack_start(make_card(out grid), false, false, 0);
            return grid;
        }

        // A row: the setting's name and description on the left, `control` on the right
        private void add_row(Gtk.Grid grid, ref int row, string title, string subtitle, Gtk.Widget control) {
            grid.attach(make_setting_label(title, subtitle), 0, row, 1, 1);
            grid.attach(control, 1, row++, 1, 1);
        }

        // A row with an on/off switch. `set` stores the new value; unless `apply` is false
        // the dock is told to pick it up. A switch that is not `available` is shown off and
        // greyed out.
        private void add_switch_row(Gtk.Grid grid, ref int row, string title, string subtitle,
                                    bool active, owned BoolSetter set, bool available = true,
                                    bool apply = true) {
            var toggle = new Gtk.Switch();
            toggle.active = available && active;
            toggle.sensitive = available;
            toggle.halign = Gtk.Align.START;
            toggle.valign = Gtk.Align.CENTER;
            toggle.notify["active"].connect(() => {
                set(toggle.active);
                if (apply) schedule_apply();
            });
            add_row(grid, ref row, title, subtitle, toggle);
        }

        // Run `commit` when the user leaves the entry or presses Enter, not on every key
        private void connect_commit(Gtk.Entry entry, owned MenuAction commit) {
            entry.activate.connect(() => commit());
            entry.focus_out_event.connect(() => {
                commit();
                return false;
            });
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

            build_notebook();
        }

        private void build_notebook() {
            notebook = new Gtk.Notebook();
            notebook.margin = 12;

            notebook.append_page(create_appearance_tab(), new Gtk.Label("Appearance"));
            notebook.append_page(create_behavior_tab(), new Gtk.Label("Behavior"));
            notebook.append_page(create_shortcuts_tab(), new Gtk.Label("Shortcuts"));

            add(notebook);
        }

        // After the settings are replaced from outside the controls, build them again so
        // they show the new values. The tab being looked at stays.
        private void rebuild_ui() {
            int page = notebook != null ? notebook.page : 0;
            if (notebook != null) remove(notebook);
            build_notebook();
            notebook.show_all();
            notebook.page = page;
        }

        // --- Appearance Tab ---

        private Gtk.Widget create_appearance_tab() {
            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            outer.margin = 16;

            var layout = add_section(outer, "Layout", true);
            int row = 0;

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
            add_row(layout, ref row, "Position", "Which edge of the screen to place the dock", position_combo);

            var size_scale = new Gtk.Scale.with_range(Gtk.Orientation.HORIZONTAL, 32, 72, 4);
            size_scale.set_value(config.get_icon_size());
            size_scale.hexpand = true;
            size_scale.value_changed.connect(() => {
                config.set_icon_size((int)size_scale.get_value());
                schedule_apply();
            });
            add_row(layout, ref row, "Icon size", "Size of dock icons in pixels", size_scale);

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
            add_row(layout, ref row, "Magnification", "Enlarge icons when hovering over them", mag_box);

            var style = add_section(outer, "Style");
            row = 0;

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
            add_row(style, ref row, "Theme", "Visual style for the dock background", theme_box);

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
            add_row(style, ref row, "Dock opacity", "Background transparency level", opacity_scale);

            add_switch_row(style, ref row, "Frosted glass",
                subtitle_for(Feature.COMPOSITOR_BLUR, "Requires a compositor with blur support (e.g. Picom)"),
                config.get_blur_enabled(), (on) => config.set_blur_enabled(on),
                Capabilities.current.supports(Feature.COMPOSITOR_BLUR));
            add_switch_row(style, ref row, "Rounded corners", "Round the edges of the dock background",
                config.get_rounded_corners(), (on) => config.set_rounded_corners(on));

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
            string? path = Dialogs.choose_file(this, "Install Theme", Gtk.FileChooserAction.OPEN,
                                               "*.zip", "Theme files (*.zip)");
            if (path != null && theme_manager.install_theme(path)) {
                refresh_theme_list();
            }
        }

        // --- Behavior Tab ---

        private Gtk.Widget create_behavior_tab() {
            var scroll = new Gtk.ScrolledWindow(null, null);
            scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

            var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            outer.margin = 16;

            var visibility = add_section(outer, "Visibility", true);
            int row = 0;
            add_switch_row(visibility, ref row, "Auto-hide", "Hide the dock when not in use",
                config.get_auto_hide(), (on) => config.set_auto_hide(on));
            add_switch_row(visibility, ref row, "Dodge windows",
                subtitle_for(Feature.DODGE_WINDOWS,
                    Capabilities.current.session == SessionType.WAYLAND
                        ? "Hide when a window is maximized or fullscreen on this screen"
                        : "Hide when a window overlaps the dock"),
                config.get_dodge_windows(), (on) => config.set_dodge_windows(on),
                Capabilities.current.supports(Feature.DODGE_WINDOWS));

            var delay_spin = new Gtk.SpinButton.with_range(0, 2000, 100);
            delay_spin.value = config.get_hide_delay();
            delay_spin.valign = Gtk.Align.CENTER;
            delay_spin.value_changed.connect(() => {
                config.set_hide_delay((int)delay_spin.value);
                schedule_apply();
            });
            add_row(visibility, ref row, "Hide delay", "Milliseconds before the dock hides", delay_spin);

            add_switch_row(visibility, ref row, "Show on all monitors", "Display the dock on every connected display",
                config.get_multi_monitor(), (on) => config.set_multi_monitor(on));

            // Monitors section: only when there is more than one to tell apart
            var display = Gdk.Display.get_default();
            if (display != null && display.get_n_monitors() > 1) {
                outer.pack_start(make_section_header("Monitors"), false, false, 0);
                outer.pack_start(create_monitors_card(display), false, false, 0);
            }

            var animations = add_section(outer, "Animations");
            row = 0;
            add_switch_row(animations, ref row, "Bounce on launch", "Bounce icon when opening an application",
                config.get_launch_bounce(), (on) => config.set_launch_bounce(on));
            add_switch_row(animations, ref row, "Launcher fade", "Fade animation when opening the app launcher",
                config.get_launcher_fade(), (on) => config.set_launcher_fade(on), true, false);

            var items = add_section(outer, "Dock Items");
            row = 0;
            add_switch_row(items, ref row, "Minimize on click", "Clicking the icon of the focused app minimizes it",
                config.get_minimize_on_click(), (on) => config.set_minimize_on_click(on));
            add_switch_row(items, ref row, "Media widget", "Show media player controls on the dock",
                config.get_media_widget(), (on) => config.set_media_widget(on));

            // Players the media widget ignores
            var blocked_entry = new Gtk.Entry();
            blocked_entry.text = string.joinv(", ", config.get_media_blocked_players());
            blocked_entry.width_chars = 28;
            blocked_entry.halign = Gtk.Align.START;
            blocked_entry.valign = Gtk.Align.CENTER;
            string saved_blocked = blocked_entry.text;
            connect_commit(blocked_entry, () => {
                if (blocked_entry.text == saved_blocked) return;
                saved_blocked = blocked_entry.text;
                string[] players = {};
                foreach (var part in blocked_entry.text.split(",")) {
                    var word = part.strip();
                    if (word != "") players += word;
                }
                config.set_media_blocked_players(players);
                schedule_apply();
            });
            add_row(items, ref row, "Ignored players",
                "Media players to skip, separated by commas. Matches part of the player's name", blocked_entry);

            add_switch_row(items, ref row, "Notification badges", "Show unread count on app icons",
                config.get_notification_badges(), (on) => config.set_notification_badges(on));
            add_switch_row(items, ref row, "Separator", "Divider between pinned and running apps",
                config.get_plugin_enabled("separator"), (on) => config.set_plugin_enabled("separator", on));
            add_switch_row(items, ref row, "Show Desktop", subtitle_for(Feature.WINDOW_TRACKING, "Button to minimize all windows"),
                config.get_plugin_enabled("show-desktop"), (on) => config.set_plugin_enabled("show-desktop", on),
                Capabilities.current.supports(Feature.WINDOW_TRACKING));
            add_switch_row(items, ref row, "Trash", "Quick access to the trash can",
                config.get_plugin_enabled("trash"), (on) => config.set_plugin_enabled("trash", on));

            foreach (var plugin in plugin_manager.get_user_plugins()) {
                var script_plugin = plugin as ScriptPlugin;
                bool on_by_default = script_plugin == null || script_plugin.enabled_by_default;
                string plugin_id = plugin.id;
                add_switch_row(items, ref row, plugin.name, "Plugin",
                    config.get_plugin_enabled(plugin_id, on_by_default),
                    (on) => config.set_plugin_enabled(plugin_id, on));
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

            items.attach(btn_box, 0, row++, 2, 1);

            var launcher = add_section(outer, "Launcher");
            row = 0;

            var hidden_btn = new Gtk.Button.with_label("Manage...");
            hidden_btn.halign = Gtk.Align.START;
            hidden_btn.valign = Gtk.Align.CENTER;
            hidden_btn.clicked.connect(show_hidden_apps_dialog);
            add_row(launcher, ref row, "Hidden apps", "Apps hidden from the application launcher", hidden_btn);

            add_switch_row(launcher, ref row, "Group apps by category",
                "In All, collect categories with many apps into one folder each. Your ten most-used apps stay out of folders",
                config.get_group_apps(), (on) => config.set_group_apps(on));

            var web_entry = new Gtk.Entry();
            web_entry.text = config.get_web_search_url();
            web_entry.width_chars = 30;
            web_entry.halign = Gtk.Align.START;
            web_entry.valign = Gtk.Align.CENTER;
            string saved_web = web_entry.text;
            connect_commit(web_entry, () => {
                string url = web_entry.text.strip();
                if (url == saved_web) return;
                // Only an empty value or an http(s) address with %s is kept
                if (url != "" && QuickResults.web_search_uri(url, "x") == null) {
                    web_entry.text = saved_web;
                    return;
                }
                saved_web = url;
                config.set_web_search_url(url);
                schedule_apply();
            });
            add_row(launcher, ref row, "Web search",
                "Where the launcher's search the web row goes. %s stands for the search words. Empty turns the row off",
                web_entry);

            var backup = add_section(outer, "Backup");
            var backup_buttons = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            backup_buttons.halign = Gtk.Align.END;
            backup_buttons.valign = Gtk.Align.CENTER;
            var export_btn = new Gtk.Button.with_label("Export...");
            export_btn.clicked.connect(on_export_settings);
            var import_btn = new Gtk.Button.with_label("Import...");
            import_btn.clicked.connect(on_import_settings);
            var reset_btn = new Gtk.Button.with_label("Reset...");
            reset_btn.get_style_context().add_class("destructive-action");
            reset_btn.clicked.connect(on_reset_settings);
            backup_buttons.pack_start(export_btn, false, false, 0);
            backup_buttons.pack_start(import_btn, false, false, 0);
            backup_buttons.pack_start(reset_btn, false, false, 0);
            row = 0;
            add_row(backup, ref row, "Settings file",
                "Save your settings, pinned apps and folders to a file, or load them back", backup_buttons);

            scroll.add(outer);
            return scroll;
        }

        // One row per connected monitor: its own edge, icon size and auto-hide, or "Default"
        // to follow the settings above
        private Gtk.Widget create_monitors_card(Gdk.Display display) {
            Gtk.Grid grid;
            var card = make_card(out grid);
            string[] keys = MonitorKey.all(display);
            int row = 0;

            var note = new Gtk.Label("<small>Each monitor can have its own edge, icon size and auto-hide. " +
                                     "Default follows the settings for all monitors. Turn on Show on all monitors " +
                                     "to get a dock on each one.</small>");
            note.use_markup = true;
            note.wrap = true;
            note.xalign = 0;
            note.max_width_chars = 70;
            note.get_style_context().add_class("dim-label");
            grid.attach(note, 0, row++, 2, 1);

            for (int i = 0; i < keys.length; i++) {
                string key = keys[i];
                grid.attach(make_setting_label(MonitorKey.label(display, i), "Settings for this monitor"),
                            0, row, 1, 1);

                var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
                box.halign = Gtk.Align.END;
                box.valign = Gtk.Align.CENTER;

                // Edge
                var edge = new Gtk.ComboBoxText();
                edge.append("", "Edge: Default");
                edge.append("bottom", "Bottom");
                edge.append("top", "Top");
                edge.append("left", "Left");
                edge.append("right", "Right");
                edge.active_id = config.get_monitor_position(key) ?? "";
                edge.changed.connect(() => {
                    string id = edge.active_id ?? "";
                    config.set_monitor_position(key, id == "" ? null : id);
                    schedule_apply();
                });
                box.pack_start(edge, false, false, 0);

                // Icon size: Default follows the setting for all monitors
                var size = new Gtk.ComboBoxText();
                size.append("0", "Size: Default");
                int[] presets = { 24, 32, 40, 48, 56, 64, 80, 96, 128 };
                int current = config.get_monitor_icon_size(key);
                bool listed = current == 0;
                foreach (int preset in presets) {
                    if (current > 0 && !listed && current < preset) {
                        size.append(current.to_string(), "%d px".printf(current));
                        listed = true;
                    }
                    if (preset == current) listed = true;
                    size.append(preset.to_string(), "%d px".printf(preset));
                }
                if (!listed) size.append(current.to_string(), "%d px".printf(current));
                size.active_id = current.to_string();
                size.changed.connect(() => {
                    config.set_monitor_icon_size(key, int.parse(size.active_id ?? "0"));
                    schedule_apply();
                });
                box.pack_start(size, false, false, 0);

                // Auto-hide
                var hide_combo = new Gtk.ComboBoxText();
                hide_combo.append("-1", "Auto-hide: Default");
                hide_combo.append("1", "On");
                hide_combo.append("0", "Off");
                hide_combo.active_id = config.get_monitor_auto_hide(key).to_string();
                hide_combo.changed.connect(() => {
                    config.set_monitor_auto_hide(key, int.parse(hide_combo.active_id ?? "-1"));
                    schedule_apply();
                });
                box.pack_start(hide_combo, false, false, 0);

                grid.attach(box, 1, row++, 1, 1);
            }

            return card;
        }

        // --- Export, import and reset ---

        private void tell(Gtk.MessageType type, string text, string? detail = null) {
            var box = new Gtk.MessageDialog(this, Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                                            type, Gtk.ButtonsType.OK, "%s", text);
            if (detail != null) box.secondary_text = detail;
            box.run();
            box.destroy();
        }

        private bool confirm(string text, string detail, string action, bool destructive) {
            var box = new Gtk.MessageDialog(this, Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                                            Gtk.MessageType.QUESTION, Gtk.ButtonsType.NONE, "%s", text);
            box.secondary_text = detail;
            box.add_button("_Cancel", Gtk.ResponseType.CANCEL);
            var go = box.add_button(action, Gtk.ResponseType.ACCEPT);
            if (destructive) {
                // Enter must not be able to throw settings away
                go.get_style_context().add_class("destructive-action");
                box.set_default_response(Gtk.ResponseType.CANCEL);
            } else {
                box.set_default_response(Gtk.ResponseType.ACCEPT);
            }
            bool accepted = box.run() == Gtk.ResponseType.ACCEPT;
            box.destroy();
            return accepted;
        }

        private void on_export_settings() {
            string? path = Dialogs.choose_file(this, "Export Settings", Gtk.FileChooserAction.SAVE,
                                               null, null, null, "dokku-settings.ini");
            if (path == null) return;
            try {
                config.export_to(path);
                tell(Gtk.MessageType.INFO, "Settings exported", path);
            } catch (Error e) {
                tell(Gtk.MessageType.ERROR, "Could not save the settings", e.message);
            }
        }

        private void on_import_settings() {
            string? path = Dialogs.choose_file(this, "Import Settings", Gtk.FileChooserAction.OPEN,
                                               "*.ini", "Settings files (*.ini)");
            if (path == null) return;

            if (!confirm("Replace your settings with this file?",
                         "A copy of your current settings is kept as config.ini.bak. " +
                         "Only import files you trust: settings can include launcher shortcuts that run commands.",
                         "_Import", false)) {
                return;
            }
            try {
                config.import_from(path);
            } catch (Error e) {
                tell(Gtk.MessageType.ERROR, "Could not import the settings", e.message);
                return;
            }
            settings_changed();
            rebuild_ui();
            tell(Gtk.MessageType.INFO, "Settings imported");
        }

        private void on_reset_settings() {
            if (!confirm("Reset all settings to the defaults?",
                         "Pinned apps, folders, shortcuts and other settings go back to how a fresh install starts. " +
                         "A copy of your current settings is kept as config.ini.bak.",
                         "_Reset", true)) {
                return;
            }
            config.reset_to_defaults();
            settings_changed();
            rebuild_ui();
            tell(Gtk.MessageType.INFO, "Settings reset to the defaults");
        }

        private void on_install_plugin() {
            string? path = Dialogs.choose_file(this, "Install Plugin", Gtk.FileChooserAction.OPEN,
                                               "*.zip", "Plugin files (*.zip)");
            if (path != null && plugin_manager.install_plugin(path)) {
                schedule_apply();
            }
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

            // Without global-hotkey support (Wayland), explain and offer the alternative
            string? hotkeys_unavailable = Capabilities.current.why_not(Feature.GLOBAL_HOTKEYS);
            if (hotkeys_unavailable != null) {
                var banner = new Gtk.Label(hotkeys_unavailable + ".");
                banner.wrap = true;
                banner.xalign = 0;
                banner.margin_bottom = 12;
                banner.get_style_context().add_class("dim-label");
                outer.pack_start(banner, false, false, 0);
            }

            // --- Launcher Hotkey section ---
            outer.pack_start(make_section_header("Launcher Hotkey", hotkeys_unavailable == null), false, false, 0);

            Gtk.Grid launcher_grid;
            var launcher_card = make_card(out launcher_grid);
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

            outer.pack_start(launcher_card, false, false, 0);

            // --- Application Hotkeys section ---
            outer.pack_start(make_section_header("Application Hotkeys"), false, false, 0);

            Gtk.Grid app_grid;
            var app_card = make_card(out app_grid);
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

            outer.pack_start(app_card, false, false, 0);

            if (hotkeys_unavailable != null) {
                launcher_card.sensitive = false;
                app_card.sensitive = false;
            }

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

            var version = new Gtk.Label("Version " + VERSION);
            version.get_style_context().add_class("dim-label");
            box.pack_start(version, false, false, 0);

            var session_label = new Gtk.Label("Session: " + Capabilities.current.describe());
            session_label.get_style_context().add_class("dim-label");
            box.pack_start(session_label, false, false, 0);

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
            string? path = Dialogs.choose_file(this, "Choose Application", Gtk.FileChooserAction.OPEN,
                                               null, null, "/usr/bin");
            if (path == null) return;
            app_entries[slot - 1].text = path;
            config.set_app_hotkey_id(slot, path);
            app_hotkey_buttons[slot - 1].sensitive = true;
            schedule_apply();
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
            string? name = Dialogs.ask_text(this, "New Folder", "_Create", "", "Folder name");
            if (name == null) return;
            string folder_id = "f_%s".printf(new DateTime.now_utc().to_unix().to_string());
            config.create_folder(folder_id, name, {});
            // Add folder reference to pinned apps list
            string[] new_pinned = config.get_pinned_apps();
            new_pinned += "folder:" + folder_id;
            config.set_pinned_apps(new_pinned);
            schedule_apply();
        }
    }
}
