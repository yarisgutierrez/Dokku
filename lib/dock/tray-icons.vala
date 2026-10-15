namespace Dokku {
    // Which processes have a system tray icon. A tray app (Spotify, Signal, anything with a
    // StatusNotifier icon) is what the dock keeps showing after its last window closes; a
    // background daemon with no icon is not worth a dot.
    namespace TrayIcons {
        // Apps name their icon after either spelling of the protocol
        private const string ITEM_PREFIX = "org.kde.StatusNotifierItem-";
        private const string ITEM_PREFIX_FD = "org.freedesktop.StatusNotifierItem-";
        private const string WATCHER = "org.kde.StatusNotifierWatcher";

        // True when a process in `pids`, or one it started, owns a tray icon
        public async bool owned_by(int[] pids) {
            if (pids.length == 0) return false;
            DBusConnection bus;
            string[] names = {};
            try {
                bus = yield Bus.get(BusType.SESSION);
                var list = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "ListNames", null, new VariantType("(as)"),
                    DBusCallFlags.NONE, 500);
                foreach (var name in list.get_child_value(0).get_strv()) {
                    if (name.has_prefix(ITEM_PREFIX) || name.has_prefix(ITEM_PREFIX_FD)) names += name;
                }
            } catch (Error e) {
                return false;
            }

            // Icons that registered with the watcher under a name of their own (GTK and
            // libappindicator apps do this), as "service/path" or just "service"
            try {
                var reply = yield bus.call(WATCHER, "/StatusNotifierWatcher",
                    "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", WATCHER, "RegisteredStatusNotifierItems"),
                    new VariantType("(v)"), DBusCallFlags.NO_AUTO_START, 500);
                Variant items;
                reply.get_child_value(0).get("v", out items);
                foreach (var entry in items.get_strv()) {
                    int slash = entry.index_of("/");
                    names += slash > 0 ? entry.substring(0, slash) : entry;
                }
            } catch (Error e) {
                // No watcher running: only the icons named on the bus count
            }

            foreach (var name in names) {
                try {
                    var reply = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                        "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                        new Variant("(s)", name), new VariantType("(u)"),
                        DBusCallFlags.NONE, 500);
                    uint owner;
                    reply.get("(u)", out owner);
                    if (AppQuit.is_in_tree((int) owner, pids)) return true;
                } catch (Error e) {}
            }
            return false;
        }
    }
}
