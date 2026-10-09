namespace Dokku {
    public class Application : Gtk.Application {
        private DockWindow dock;
        private List<DockWindow> extra_docks;
        private LauncherWindow launcher;
        private SettingsWindow settings;
        private AppManager app_manager;
        private ConfigManager config;
        private HotkeyManager hotkey_manager;
        private UsageTracker usage_tracker;
        private DBusService? dbus_service;
        private uint dbus_owner_id = 0;

        private bool show_launcher = false;
        private bool show_settings = false;

        public Application() {
            Object(
                application_id: "org.dokku.app",
                flags: ApplicationFlags.HANDLES_COMMAND_LINE
            );
            
            // Add command-line options
            add_main_option("launcher", 'l', 0, OptionArg.NONE, "Open the application launcher", null);
            add_main_option("settings", 's', 0, OptionArg.NONE, "Open the settings window", null);
            add_main_option("version", 'v', 0, OptionArg.NONE, "Print the version and exit", null);
        }
        
        protected override int handle_local_options(VariantDict options) {
            if (options.contains("version")) {
                print("dokku %s\n", VERSION);
                return 0;
            }

            // --launcher and --settings are handled in command_line(): this method only
            // runs in the process the user typed the command in, which is not the
            // running dock when one already exists.
            return -1;
        }

        protected override int command_line(ApplicationCommandLine command_line) {
            // Runs in the primary instance, with the options forwarded from the caller
            var options = command_line.get_options_dict();
            if (options.contains("launcher")) {
                show_launcher = true;
            }
            if (options.contains("settings")) {
                show_settings = true;
            }
            activate();
            return 0;
        }

        protected override void shutdown() {
            if (dbus_owner_id != 0) {
                Bus.unown_name(dbus_owner_id);
                dbus_owner_id = 0;
            }
            if (usage_tracker != null) usage_tracker.flush();
            base.shutdown();
        }

        protected override void startup() {
            base.startup();
            // Falls back silently if the icon theme has no "dokku" icon (not installed)
            Gtk.Window.set_default_icon_name("dokku");
        }

        protected override void activate() {
            if (dock != null) {
                if (show_launcher) {
                    launcher.toggle();
                    show_launcher = false;
                }
                if (show_settings) {
                    settings.show_all();
                    show_settings = false;
                }
                dock.present();
                return;
            }

            config = new ConfigManager();
            app_manager = new AppManager();
            usage_tracker = new UsageTracker(config);
            extra_docks = new List<DockWindow>();
            dock = new DockWindow(this, app_manager, config, usage_tracker);
            launcher = new LauncherWindow(app_manager, config, usage_tracker);
            settings = new SettingsWindow(config, app_manager);

            dock.launcher_requested.connect(() => {
                launcher.toggle();
            });
            launcher.pin_to_dock_requested.connect((app_id, desktop_file) => {
                var pinned = config.get_pinned_apps();
                foreach (var p in pinned) {
                    if (p == app_id || p == desktop_file) return;
                }
                string[] new_pinned = pinned;
                new_pinned += (desktop_file != "" ? desktop_file : app_id);
                config.set_pinned_apps(new_pinned);
                dock.reload_settings();
            });
            dock.settings_requested.connect(() => settings.show_all());
            settings.settings_changed.connect(() => {
                dock.reload_settings();
                foreach (var extra in extra_docks) {
                    extra.reload_settings();
                }
                sync_multi_monitor();
            });
            settings.settings_changed.connect(() => {
                launcher.mark_dirty();
                if (hotkey_manager != null) {
                    hotkey_manager.reload_hotkeys();
                }
            });
            settings.delete_event.connect(() => { settings.hide(); return true; });

            app_manager.apps_changed.connect(() => {
                launcher.refresh_apps();
                dock.reload_settings();
            });

            var caps = Capabilities.current;
            message("Session: %s", caps.describe());
            if (caps.supports(Feature.GLOBAL_HOTKEYS)) {
                hotkey_manager = new HotkeyManager(config, launcher, app_manager, usage_tracker);
                hotkey_manager.hotkey_error.connect((message) => {
                    warning("Hotkey error: %s", message);
                    var notification = new Notification("Dokku Hotkey Error");
                    notification.set_body(message);
                    send_notification(null, notification);
                });
                if (hotkey_manager.initialize()) {
                    hotkey_manager.reload_hotkeys();
                }
            } else {
                // Not an error: this session has no global-hotkey mechanism we can use
                message("Global hotkeys: %s", caps.why_not(Feature.GLOBAL_HOTKEYS));
            }

            // Register D-Bus service for external control
            if (dbus_service == null) {
                dbus_service = new DBusService(dock, launcher, settings, config, app_manager);
                settings.settings_changed.connect(() => dbus_service.settings_changed());
                launcher.show.connect(() => dbus_service.launcher_toggled(true));
                launcher.hide.connect(() => dbus_service.launcher_toggled(false));

                dbus_owner_id = Bus.own_name(BusType.SESSION, "org.dokku.Dock",
                    BusNameOwnerFlags.NONE,
                    (connection) => {
                        try {
                            connection.register_object("/org/dokku/Dock", dbus_service);
                        } catch (IOError e) {
                            warning("Failed to register D-Bus object: %s", e.message);
                        }
                    },
                    () => {},
                    () => { warning("Failed to acquire D-Bus name org.dokku.Dock"); }
                );
            }

            dock.show_all();
            dock.present();
            dock.set_visible(true);

            sync_multi_monitor();

            if (show_launcher) {
                launcher.toggle();
                show_launcher = false;
            }
            if (show_settings) {
                settings.show_all();
                show_settings = false;
            }
        }

        private void sync_multi_monitor() {
            bool multi = config.get_multi_monitor();
            var display = Gdk.Display.get_default();
            int n_monitors = display.get_n_monitors();

            if (!multi || n_monitors <= 1) {
                // Destroy extra docks
                foreach (var extra in extra_docks) {
                    extra.destroy();
                }
                extra_docks = new List<DockWindow>();
                return;
            }

            // Pin primary dock to primary monitor
            var primary = display.get_primary_monitor();
            if (primary == null) primary = display.get_monitor(0);
            dock.set_target_monitor(primary);

            // Build set of monitors that need docks
            var needed = new List<Gdk.Monitor>();
            for (int i = 0; i < n_monitors; i++) {
                var mon = display.get_monitor(i);
                if (mon != primary) {
                    needed.append(mon);
                }
            }

            // Remove extra docks for monitors no longer present
            var to_remove = new List<DockWindow>();
            foreach (var extra in extra_docks) {
                bool still_needed = false;
                foreach (var mon in needed) {
                    if (mon == extra.get_target_monitor_ref()) {
                        still_needed = true;
                        break;
                    }
                }
                if (!still_needed) {
                    to_remove.append(extra);
                }
            }
            foreach (var extra in to_remove) {
                extra.destroy();
                extra_docks.remove(extra);
            }

            // Create docks for new monitors
            foreach (var mon in needed) {
                bool already_has = false;
                foreach (var extra in extra_docks) {
                    if (extra.get_target_monitor_ref() == mon) {
                        already_has = true;
                        break;
                    }
                }
                if (!already_has) {
                    var extra = new DockWindow(this, app_manager, config, usage_tracker);
                    extra.set_target_monitor(mon);
                    extra.launcher_requested.connect(() => launcher.toggle());
                    extra.settings_requested.connect(() => settings.show_all());
                    extra.show_all();
                    extra.present();
                    extra_docks.append(extra);
                }
            }
        }
    }
}
