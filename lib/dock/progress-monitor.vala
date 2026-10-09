namespace Dokku {
    public class ProgressMonitor : Object {
        private AppManager app_manager;
        private uint subscription_id = 0;

        // Window-based progress detection
        private Wnck.Screen? screen;
        private HashTable<unowned Wnck.Window, string> progress_windows;
        private HashTable<unowned Wnck.Window, ulong> name_handlers;
        private HashTable<string, bool> launcher_entry_apps;

        // AT-SPI progress polling (optional dependency)
#if HAVE_ATSPI
        private bool atspi_available = false;
        private uint atspi_poll_id = 0;
#endif

        public signal void progress_changed(string app_id, double progress, bool visible);

        private DBusConnection? dbus_connection;

        public ProgressMonitor(AppManager app_manager) {
            this.app_manager = app_manager;
            progress_windows = new HashTable<unowned Wnck.Window, string>(direct_hash, direct_equal);
            name_handlers = new HashTable<unowned Wnck.Window, ulong>(direct_hash, direct_equal);
            launcher_entry_apps = new HashTable<string, bool>(str_hash, str_equal);

#if HAVE_ATSPI
            int atspi_status = Atspi.init();
            atspi_available = (atspi_status == 0);
#endif

            setup_monitor.begin();
            setup_window_monitor();
        }

        ~ProgressMonitor() {
            // Unsubscribe D-Bus signal
            if (dbus_connection != null && subscription_id != 0) {
                dbus_connection.signal_unsubscribe(subscription_id);
                subscription_id = 0;
            }

#if HAVE_ATSPI
            // Cancel AT-SPI polling timer
            if (atspi_poll_id != 0) {
                Source.remove(atspi_poll_id);
                atspi_poll_id = 0;
            }
#endif

            // Disconnect Wnck screen signals
            if (screen != null) {
                screen.window_opened.disconnect(on_wnck_window_opened);
                screen.window_closed.disconnect(on_wnck_window_closed);
            }

            // Disconnect remaining name_changed handlers from tracked windows
            name_handlers.foreach((window, handler_id) => {
                window.disconnect(handler_id);
            });
            name_handlers.remove_all();
        }

        private async void setup_monitor() {
            try {
                var connection = yield Bus.get(BusType.SESSION);
                dbus_connection = connection;

                subscription_id = connection.signal_subscribe(
                    null,
                    "com.canonical.Unity.LauncherEntry",
                    "Update",
                    null,
                    null,
                    DBusSignalFlags.NONE,
                    on_launcher_entry_update
                );
            } catch (Error e) {
                warning("ProgressMonitor: setup failed: %s", e.message);
            }
        }

        private void on_launcher_entry_update(DBusConnection connection, string? sender,
                                               string object_path, string interface_name,
                                               string signal_name, Variant parameters) {
            if (parameters.n_children() < 2) return;

            string desktop_file_uri = parameters.get_child_value(0).get_string();
            var properties = parameters.get_child_value(1);

            string? app_id = resolve_app_id(desktop_file_uri);
            if (app_id == null) return;

            var progress_visible_var = properties.lookup_value("progress-visible", VariantType.BOOLEAN);
            var progress_var = properties.lookup_value("progress", VariantType.DOUBLE);

            if (progress_visible_var != null || progress_var != null) {
                bool pv = progress_visible_var != null ? progress_visible_var.get_boolean() : false;
                double p = progress_var != null ? progress_var.get_double() : 0.0;

                // Track which apps have LauncherEntry progress (takes priority)
                if (pv) {
                    launcher_entry_apps.set(app_id, true);
                } else {
                    launcher_entry_apps.remove(app_id);
                }

                progress_changed(app_id, p, pv);
            }
        }

        private string? resolve_app_id(string desktop_file_uri) {
            string stripped = desktop_file_uri;
            if (stripped.has_prefix("application://")) {
                stripped = stripped.substring("application://".length);
            }
            if (stripped.has_suffix(".desktop")) {
                stripped = stripped.substring(0, stripped.length - ".desktop".length);
            }

            var app = app_manager.get_app(stripped);
            if (app != null) return app.id;

            app = app_manager.find_by_name(stripped);
            if (app != null) return app.id;

            return null;
        }

        // --- Window-based progress detection ---

        private void setup_window_monitor() {
            screen = WindowManager.default_screen();
            if (screen == null) return;
            screen.window_opened.connect(on_wnck_window_opened);
            screen.window_closed.connect(on_wnck_window_closed);
        }

        private void on_wnck_window_opened(Wnck.Window window) {
            // Listen for title changes — window name may not be set yet at open time
            ulong handler = window.name_changed.connect(() => {
                try_classify_progress_window(window);
            });
            name_handlers.set(window, handler);

            // Also check immediately
            try_classify_progress_window(window);
        }

        private void on_wnck_window_closed(Wnck.Window window) {
            // Disconnect name_changed handler
            if (name_handlers.contains(window)) {
                window.disconnect(name_handlers.get(window));
                name_handlers.remove(window);
            }

            if (progress_windows.contains(window)) {
                string app_id = progress_windows.get(window);
                progress_windows.remove(window);
                // Clear progress only if no other progress windows remain for this app
                if (!has_progress_window_for(app_id)) {
                    progress_changed(app_id, 0.0, false);
                }
            }
        }

        private void try_classify_progress_window(Wnck.Window window) {
            // Already tracked — don't re-evaluate
            if (progress_windows.contains(window)) return;

            if (!looks_like_progress_window(window)) return;

            var app = app_manager.find_by_window(window);
            if (app == null) return;

            // Don't override explicit LauncherEntry progress (it's determinate & more precise)
            if (launcher_entry_apps.contains(app.id)) return;

            progress_windows.set(window, app.id);

            // Emit indeterminate initially; AT-SPI polling will update with real values
            progress_changed(app.id, -1.0, true);
#if HAVE_ATSPI
            start_atspi_polling();
#endif

            // Stop listening for name changes once classified
            if (name_handlers.contains(window)) {
                window.disconnect(name_handlers.get(window));
                name_handlers.remove(window);
            }
        }

        private bool looks_like_progress_window(Wnck.Window window) {
            string? name = window.get_name();
            if (name == null || name == "") return false;
            string nl = name.down();

            // High-confidence patterns: match regardless of window type
            // These are specific to file managers and unlikely to appear in app content
            if (nl.contains("file operation") ||
                nl.contains("copying files") ||
                nl.contains("moving files") ||
                nl.contains("deleting files") ||
                nl.contains("extracting files") ||
                nl.contains("compressing files") ||
                nl.contains("transferring files")) {
                return true;
            }

            // Medium-confidence: generic keywords but only for DIALOG/UTILITY windows
            // Avoids false positives from browser tabs or document titles
            var wtype = window.get_window_type();
            if (wtype == Wnck.WindowType.DIALOG || wtype == Wnck.WindowType.UTILITY) {
                if (nl.contains("progress") ||
                    nl.contains("copying") ||
                    nl.contains("moving") ||
                    nl.contains("extracting") ||
                    nl.contains("compressing") ||
                    nl.contains("downloading") ||
                    nl.contains("uploading") ||
                    nl.contains("transferring") ||
                    nl.contains("installing")) {
                    return true;
                }
            }

            return false;
        }

        private bool has_progress_window_for(string app_id) {
            var iter = HashTableIter<unowned Wnck.Window, string>(progress_windows);
            unowned Wnck.Window w;
            unowned string id;
            while (iter.next(out w, out id)) {
                if (id == app_id) return true;
            }
            return false;
        }

        // --- AT-SPI progress value polling (optional) ---

#if HAVE_ATSPI
        private void start_atspi_polling() {
            if (!atspi_available) return;
            if (atspi_poll_id != 0) return;
            atspi_poll_id = Timeout.add(1000, () => {
                if (progress_windows.size() == 0) {
                    atspi_poll_id = 0;
                    return false;
                }
                poll_progress_values();
                return true;
            });
        }

        private void poll_progress_values() {
            var desktop = Atspi.get_desktop(0);
            if (desktop == null) return;

            var iter = HashTableIter<unowned Wnck.Window, string>(progress_windows);
            unowned Wnck.Window w;
            unowned string app_id;
            while (iter.next(out w, out app_id)) {
                double? value = read_progress_for_window(desktop, w);
                if (value != null) {
                    progress_changed(app_id, value, true);
                }
                // If null, keep previous value (indeterminate on first detection)
            }
        }

        private double? read_progress_for_window(Atspi.Accessible desktop, Wnck.Window window) {
            int target_pid = window.get_pid();
            if (target_pid <= 0) return null;

            try {
                int n_apps = desktop.get_child_count();
                for (int i = 0; i < n_apps; i++) {
                    Atspi.Accessible? app = desktop.get_child_at_index(i);
                    if (app == null) continue;
                    try {
                        uint pid = app.get_process_id();
                        if ((int)pid == target_pid) {
                            return find_progress_bar_value(app, 0);
                        }
                    } catch (GLib.Error e) { continue; }
                }
            } catch (GLib.Error e) {}
            return null;
        }

        private const int MAX_ATSPI_DEPTH = 20;

        private double? find_progress_bar_value(Atspi.Accessible node, int depth) {
            if (depth > MAX_ATSPI_DEPTH) return null;
            try {
                var role = node.get_role();
                if (role == Atspi.Role.PROGRESS_BAR) {
                    var val_iface = node.get_value_iface();
                    if (val_iface != null) {
                        double current = val_iface.get_current_value();
                        double maximum = val_iface.get_maximum_value();
                        double minimum = val_iface.get_minimum_value();
                        if (maximum > minimum) {
                            return (current - minimum) / (maximum - minimum);
                        }
                    }
                }

                int count = node.get_child_count();
                for (int i = 0; i < count; i++) {
                    Atspi.Accessible? child = node.get_child_at_index(i);
                    if (child == null) continue;
                    var result = find_progress_bar_value(child, depth + 1);
                    if (result != null) return result;
                }
            } catch (GLib.Error e) {}
            return null;
        }
#endif
    }
}
