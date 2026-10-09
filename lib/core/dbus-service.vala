namespace Dokku {

    [DBus (name = "org.dokku.Dock")]
    public class DBusService : Object {
        private DockWindow dock;
        private LauncherWindow launcher;
        private SettingsWindow settings;
        private ConfigManager config;
        private AppManager app_manager;

        public DBusService(DockWindow dock, LauncherWindow launcher,
                           SettingsWindow settings, ConfigManager config,
                           AppManager app_manager) {
            this.dock = dock;
            this.launcher = launcher;
            this.settings = settings;
            this.config = config;
            this.app_manager = app_manager;
        }

        // --- Methods: Actions ---

        public void reload() throws DBusError, IOError {
            config.reload();
            dock.reload_settings();
        }

        public void toggle_launcher() throws DBusError, IOError {
            launcher.toggle();
        }

        public void show_launcher() throws DBusError, IOError {
            if (!launcher.visible) launcher.toggle();
        }

        public void hide_launcher() throws DBusError, IOError {
            if (launcher.visible) launcher.toggle();
        }

        public void show_settings() throws DBusError, IOError {
            settings.show_all();
        }

        public bool launch_app(string app_id) throws DBusError, IOError {
            var app = app_manager.get_app(app_id);
            if (app == null) app = app_manager.find_by_name(app_id);
            if (app != null) {
                app.launch();
                return true;
            }
            return false;
        }

        // --- Methods: Pinned apps ---

        public string[] get_pinned_apps() throws DBusError, IOError {
            return config.get_pinned_apps();
        }

        public void set_pinned_apps(string[] apps) throws DBusError, IOError {
            if (apps.length > 200) {
                throw new DBusError.LIMITS_EXCEEDED("Too many pinned apps (%d > 200)".printf(apps.length));
            }
            config.set_pinned_apps(apps);
            dock.reload_settings();
        }

        public void pin_app(string app_id) throws DBusError, IOError {
            var pinned = config.get_pinned_apps();
            foreach (var p in pinned) {
                if (p == app_id) return;
            }
            string[] new_pinned = pinned;
            new_pinned += app_id;
            config.set_pinned_apps(new_pinned);
            dock.reload_settings();
        }

        public void unpin_app(string app_id) throws DBusError, IOError {
            var pinned = config.get_pinned_apps();
            string[] new_pinned = {};
            foreach (var p in pinned) {
                if (p != app_id) new_pinned += p;
            }
            config.set_pinned_apps(new_pinned);
            dock.reload_settings();
        }

        // --- Methods: Query state ---

        public string[] list_apps() throws DBusError, IOError {
            string[] result = {};
            foreach (var app in app_manager.get_all_apps()) {
                result += app.id;
            }
            return result;
        }

        public string get_app_name(string app_id) throws DBusError, IOError {
            var app = app_manager.get_app(app_id);
            if (app != null) return app.name;
            return "";
        }

        // --- Properties: Configuration ---

        public int icon_size {
            get { return config.get_icon_size(); }
            set { config.set_icon_size(value); dock.reload_settings(); }
        }

        public double magnification {
            get { return config.get_magnification(); }
            set { config.set_magnification(value); dock.reload_settings(); }
        }

        public bool auto_hide {
            get { return config.get_auto_hide(); }
            set { config.set_auto_hide(value); dock.reload_settings(); }
        }

        public int hide_delay {
            get { return config.get_hide_delay(); }
            set { config.set_hide_delay(value); dock.reload_settings(); }
        }

        public string position {
            owned get { return config.get_position(); }
            set { config.set_position(value); dock.reload_settings(); }
        }

        public string theme {
            owned get { return config.get_theme(); }
            set { config.set_theme(value); dock.reload_settings(); }
        }

        public double opacity {
            get { return config.get_dock_opacity(); }
            set { config.set_dock_opacity(value); dock.reload_settings(); }
        }

        public bool rounded_corners {
            get { return config.get_rounded_corners(); }
            set { config.set_rounded_corners(value); dock.reload_settings(); }
        }

        public bool notification_badges {
            get { return config.get_notification_badges(); }
            set { config.set_notification_badges(value); dock.reload_settings(); }
        }

        public bool launch_bounce {
            get { return config.get_launch_bounce(); }
            set { config.set_launch_bounce(value); dock.reload_settings(); }
        }

        public bool media_widget {
            get { return config.get_media_widget(); }
            set { config.set_media_widget(value); dock.reload_settings(); }
        }

        public bool multi_monitor {
            get { return config.get_multi_monitor(); }
            set { config.set_multi_monitor(value); dock.reload_settings(); }
        }

        // --- Signals ---

        public signal void settings_changed();
        public signal void launcher_toggled(bool visible);
    }
}
