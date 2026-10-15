namespace Dokku {
    public class NotificationMonitor : Object {
        private DBusConnection? monitor_bus;
        private uint filter_id;
        private HashTable<string, int> counts;
        private AppManager app_manager;

        public signal void notification_received(string app_id);

        public NotificationMonitor(AppManager app_manager) {
            this.app_manager = app_manager;
            counts = new HashTable<string, int>(str_hash, str_equal);
            setup_monitor.begin();
        }

        private async void setup_monitor() {
            try {
                var address = Environment.get_variable("DBUS_SESSION_BUS_ADDRESS");
                if (address == null) {
                    warning("NotificationMonitor: DBUS_SESSION_BUS_ADDRESS not set");
                    return;
                }

                monitor_bus = yield new DBusConnection.for_address(
                    address,
                    DBusConnectionFlags.AUTHENTICATION_CLIENT |
                    DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                    null, null
                );

                // Register filter BEFORE BecomeMonitor so no messages are missed.
                // The filter runs in GDBus's worker thread: only read immutable
                // Variant data there, defer everything else to the main thread.
                filter_id = monitor_bus.add_filter(on_message);

                // Build BecomeMonitor args: (asu), match rules + flags
                var rules_builder = new VariantBuilder(new VariantType("as"));
                rules_builder.add("s",
                    "type='method_call',interface='org.freedesktop.Notifications',member='Notify'");

                var args_builder = new VariantBuilder(new VariantType("(asu)"));
                args_builder.add_value(rules_builder.end());
                args_builder.add("u", (uint32) 0);

                yield monitor_bus.call(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus.Monitoring",
                    "BecomeMonitor",
                    args_builder.end(),
                    null,
                    DBusCallFlags.NONE,
                    -1, null
                );
            } catch (Error e) {
                warning("NotificationMonitor: setup failed: %s", e.message);
                if (monitor_bus != null && filter_id != 0) {
                    monitor_bus.remove_filter(filter_id);
                    filter_id = 0;
                }
                if (monitor_bus != null) {
                    try { monitor_bus.close_sync(); } catch (Error e2) {}
                    monitor_bus = null;
                }
            }
        }

        ~NotificationMonitor() {
            if (monitor_bus != null) {
                if (filter_id != 0) {
                    monitor_bus.remove_filter(filter_id);
                }
                try { monitor_bus.close_sync(); } catch (Error e) {}
            }
        }

        // Called in GDBus WORKER THREAD: must not access non-thread-safe state.
        // Only read immutable Variant data here; dispatch processing to main thread.
        private DBusMessage? on_message(DBusConnection conn,
                                         owned DBusMessage message,
                                         bool incoming) {
            if (!incoming) return message;

            // Let non-method-call messages through for GLib's internal dispatch
            // (e.g. METHOD_RETURN for the BecomeMonitor call itself)
            if (message.get_message_type() != DBusMessageType.METHOD_CALL)
                return message;

            // Extract data from the Notify call (Variants are immutable: thread-safe)
            string? iface = message.get_interface();
            string? member = message.get_member();

            if (iface == "org.freedesktop.Notifications" && member == "Notify") {
                var body = message.get_body();
                if (body != null && body.n_children() >= 7) {
                    // Notify signature: (susssasa{sv}i)
                    string app_name = body.get_child_value(0).get_string();

                    string? desktop_entry_hint = null;
                    var hints = body.get_child_value(6);
                    var de_variant = hints.lookup_value("desktop-entry", VariantType.STRING);
                    if (de_variant != null) {
                        desktop_entry_hint = de_variant.get_string();
                    }

                    // Dispatch to main thread for app matching and state updates
                    string an = app_name;
                    string? de = desktop_entry_hint;
                    Idle.add(() => {
                        process_notification(de, an);
                        return false;
                    });
                }
            }

            // CRITICAL: Return null for ALL method calls. This prevents GLib from
            // dispatching to (non-existent) object handlers and sending an
            // UnknownMethod error reply, which would fail on the monitor-only
            // connection and silently close it.
            return null;
        }

        // Called on the MAIN THREAD via Idle.add: safe to access all state.
        private void process_notification(string? desktop_entry, string app_name) {
            string? matched_id = null;

            // Try desktop-entry hint first (most reliable: maps to .desktop file ID)
            if (desktop_entry != null && desktop_entry != "") {
                var app = app_manager.get_app(desktop_entry);
                if (app == null) app = app_manager.find_by_name(desktop_entry);
                if (app != null) matched_id = app.id;
            }

            // Fall back to app_name
            if (matched_id == null && app_name != "") {
                var app = app_manager.find_by_name(app_name);
                if (app != null) matched_id = app.id;
            }

            if (matched_id == null) return;

            int current = counts.contains(matched_id) ? counts.get(matched_id) : 0;
            counts.set(matched_id, current + 1);
            notification_received(matched_id);
        }

        public int get_count(string app_id) {
            return counts.contains(app_id) ? counts.get(app_id) : 0;
        }

        public void clear(string app_id) {
            counts.remove(app_id);
        }
    }
}
