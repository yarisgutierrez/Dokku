namespace Dokku {
    // Quit for the dock menu. An app that exports the standard GApplication "quit" action
    // over D-Bus is asked to quit through it, so it runs its own save prompts and leaves the
    // tray. Any other app gets a close request on each of its windows.
    namespace AppQuit {
        private void close_windows(List<weak TrackedWindow> windows) {
            foreach (var window in windows) window.close();
        }

        public async void quit(string app_id, List<weak TrackedWindow> windows) {
            // Windows are closed from a copy: the dock's list changes as they go away
            var snapshot = new List<weak TrackedWindow>();
            foreach (var window in windows) snapshot.append(window);

            if (!GLib.Application.id_is_valid(app_id)) { close_windows(snapshot); return; }
            string path = "/" + app_id.replace(".", "/").replace("-", "_");
            try {
                var bus = yield Bus.get(BusType.SESSION);
                // NO_AUTO_START: an app that is not running must not be started to be quit
                var reply = yield bus.call(app_id, path, "org.gtk.Actions", "List", null,
                    new VariantType("(as)"), DBusCallFlags.NO_AUTO_START, 500);
                foreach (var name in reply.get_child_value(0).get_strv()) {
                    if (name == "quit") {
                        yield bus.call(app_id, path, "org.gtk.Actions", "Activate",
                            new Variant.tuple({ new Variant.string("quit"),
                                new Variant.array(VariantType.VARIANT, {}),
                                new Variant.array(new VariantType("{sv}"), {}) }),
                            null, DBusCallFlags.NO_AUTO_START, 500);
                        return;
                    }
                }
            } catch (Error e) {
                // No such name or interface: the app does not offer a quit action
            }
            close_windows(snapshot);
        }
    }
}
