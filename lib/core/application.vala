namespace Dokku {
    public class Application : Gtk.Application {
        private DockWindow dock;
        private List<DockWindow> extra_docks;
        // Built on first use: most sessions never open either, and each holds a
        // sizeable widget tree (the launcher also every app icon)
        private LauncherWindow? launcher = null;
        private SettingsWindow? settings = null;
        private AppManager app_manager;
        private ConfigManager config;
        private HotkeyManager hotkey_manager;
        private UsageTracker usage_tracker;
        // One of each for the whole application: every plugin watches D-Bus or runs a
        // timer, so a second copy would do all of that twice
        private PluginManager plugin_manager;
        private ThemeManager theme_manager;
        private ProgressMonitor progress_monitor;
        // Counts unread notifications for every dock; null while badges are switched off
        private NotificationMonitor? notification_monitor = null;
        private DBusService? dbus_service;
        private uint dbus_owner_id = 0;
        private uint monitor_sync_id = 0;

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
            if (monitor_sync_id != 0) {
                Source.remove(monitor_sync_id);
                monitor_sync_id = 0;
            }
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
                open_requested_windows();
                dock.present();
                return;
            }

            config = new ConfigManager();
            app_manager = new AppManager();
            usage_tracker = new UsageTracker(config);
            plugin_manager = new PluginManager(config);
            theme_manager = new ThemeManager();
            progress_monitor = new ProgressMonitor(app_manager);
            extra_docks = new List<DockWindow>();
            dock = new DockWindow(this, app_manager, config, usage_tracker, plugin_manager,
                                  theme_manager, progress_monitor);
            sync_notification_monitor();

            dock.launcher_requested.connect(() => get_launcher().toggle());
            dock.settings_requested.connect(() => get_settings().show_all());

            app_manager.apps_changed.connect(() => {
                if (launcher != null) launcher.refresh_apps();
                dock.reload_settings();
            });

            var caps = Capabilities.current;
            message("Session: %s", caps.describe());
            if (caps.supports(Feature.GLOBAL_HOTKEYS)) {
                hotkey_manager = new HotkeyManager(config, app_manager, usage_tracker);
                hotkey_manager.launcher_toggle_requested.connect(() => get_launcher().toggle());
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
                dbus_service = new DBusService(dock, get_launcher, get_settings, config, app_manager);
                // `Reload` over D-Bus does what changing a setting does
                dbus_service.reload_requested.connect(() => apply_settings());

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

            // Docks follow monitors as they are plugged in and out, not only at startup
            // and when a setting changes.
            var display = Gdk.Display.get_default();
            display.monitor_added.connect(() => schedule_monitor_sync());
            display.monitor_removed.connect(() => schedule_monitor_sync());

            open_requested_windows();
        }

        private LauncherWindow get_launcher() {
            if (launcher == null) {
                launcher = new LauncherWindow(app_manager, config, usage_tracker);
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
                launcher.show.connect(() => dbus_service.launcher_toggled(true));
                launcher.hide.connect(() => dbus_service.launcher_toggled(false));
            }
            return launcher;
        }

        private SettingsWindow get_settings() {
            if (settings == null) {
                settings = new SettingsWindow(config, app_manager, plugin_manager, theme_manager);
                settings.settings_changed.connect(() => {
                    apply_settings();
                    dbus_service.settings_changed();
                });
                settings.delete_event.connect(() => { settings.hide(); return true; });
            }
            return settings;
        }

        // --launcher and --settings, once the windows can be built
        private void open_requested_windows() {
            if (show_launcher) {
                show_launcher = false;
                get_launcher().toggle();
            }
            if (show_settings) {
                show_settings = false;
                get_settings().show_all();
            }
        }

        // Monitors usually change in bursts (a dock being connected adds several outputs),
        // so let things settle and resync once.
        private void schedule_monitor_sync() {
            if (monitor_sync_id != 0) return;
            monitor_sync_id = Timeout.add(300, () => {
                monitor_sync_id = 0;
                sync_multi_monitor();
                return false;
            });
        }

        // Settings changed, from the Settings window or a Reload over D-Bus: every dock
        // (one per monitor), the launcher and the hotkeys take the new values
        private void apply_settings() {
            sync_notification_monitor();
            dock.reload_settings();
            foreach (var extra in extra_docks) {
                extra.reload_settings();
            }
            sync_multi_monitor();
            if (launcher != null) launcher.mark_dirty();
            if (hotkey_manager != null) {
                hotkey_manager.reload_hotkeys();
            }
        }

        // Start or stop watching notifications to match the setting, and hand the result to
        // every dock
        private void sync_notification_monitor() {
            bool wanted = config.get_notification_badges();
            if (wanted && notification_monitor == null) {
                notification_monitor = new NotificationMonitor(app_manager);
            } else if (!wanted) {
                notification_monitor = null;
            }
            dock.set_notification_monitor(notification_monitor);
            foreach (var extra in extra_docks) extra.set_notification_monitor(notification_monitor);
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
            var primary = UiUtil.primary_monitor();
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
                    var extra = new DockWindow(this, app_manager, config, usage_tracker,
                                               plugin_manager, theme_manager, progress_monitor);
                    extra.set_notification_monitor(notification_monitor);
                    extra.set_target_monitor(mon);
                    extra.launcher_requested.connect(() => get_launcher().toggle());
                    extra.settings_requested.connect(() => get_settings().show_all());
                    extra.show_all();
                    extra.present();
                    extra_docks.append(extra);
                }
            }
        }
    }
}
