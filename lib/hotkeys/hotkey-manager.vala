namespace Dokku {
    public class HotkeyManager : Object {
        private ConfigManager config;
        private AppManager app_manager;
        private UsageTracker usage_tracker;
        private Wnck.Screen screen;
        private HashTable<string, string> registered_hotkeys;  // hotkey -> action_id

        // Super key short-press detection (press/release on root window)
        private int64 super_press_time = 0;
        private uint super_l_keycode = 0;
        private uint super_r_keycode = 0;
        private bool super_other_key = false;
        private uint cached_super_target = 0;  // keycode for the configured Super key
        private const int64 SUPER_TAP_THRESHOLD_US = 400000; // 400ms

        public signal void hotkey_error(string message);
        public signal void launcher_toggle_requested();

        public HotkeyManager(ConfigManager config, AppManager app_manager, UsageTracker usage_tracker) {
            this.config = config;
            this.app_manager = app_manager;
            this.usage_tracker = usage_tracker;
            this.registered_hotkeys = new HashTable<string, string>(str_hash, str_equal);
        }

        public bool initialize() {
            // Check if keybinder is supported on this system
            if (!Keybinder.supported()) {
                warning("Keybinder not supported on this system");
                hotkey_error("Global hotkeys are not available on this system");
                return false;
            }

            // Initialize keybinder library
            Keybinder.init();

            // Initialize Wnck.Screen for window management
            screen = (!) WindowManager.default_screen();  // global hotkeys exist only on X11

            // Cache Super_L/R X11 keycodes for press/release timing
            var x11_display = (Gdk.X11.Display) Gdk.Display.get_default();
            unowned X.Display xdisplay = x11_display.get_xdisplay();
            super_l_keycode = xdisplay.keysym_to_keycode(Gdk.Key.Super_L);
            super_r_keycode = xdisplay.keysym_to_keycode(Gdk.Key.Super_R);

            // Filter on root window for Super key press/release timing.
            // GDK prepends filters, so this runs before keybinder's filter.
            Gdk.get_default_root_window().add_filter(on_root_x_filter);

            return true;
        }

        private Gdk.FilterReturn on_root_x_filter(Gdk.XEvent gdk_xevent, Gdk.Event gdk_event) {
            X.Event* xevent = (X.Event*) gdk_xevent;

            // Bail early for non-key events (mouse, property, expose, etc.)
            // to avoid any work on the vast majority of root window events.
            if (xevent->type != X.EventType.KeyPress &&
                xevent->type != X.EventType.KeyRelease) {
                return Gdk.FilterReturn.CONTINUE;
            }

            // Use cached hotkey — avoids KeyFile lookup on every key event.
            // Cache is refreshed in reload_hotkeys().
            if (cached_super_target == 0) {
                return Gdk.FilterReturn.CONTINUE;
            }

            if (xevent->type == X.EventType.KeyPress) {
                if (xevent->xkey.keycode == cached_super_target) {
                    super_press_time = GLib.get_monotonic_time();
                    super_other_key = false;
                } else if (super_press_time > 0) {
                    // Another key pressed while Super held — not a bare tap
                    super_other_key = true;
                }
            } else if (xevent->type == X.EventType.KeyRelease) {
                if (xevent->xkey.keycode == cached_super_target && super_press_time > 0) {
                    int64 hold = GLib.get_monotonic_time() - super_press_time;
                    super_press_time = 0;
                    if (!super_other_key && hold < SUPER_TAP_THRESHOLD_US) {
                        // Short tap, no combo — toggle launcher from idle
                        // to avoid reentrancy with X event processing
                        Idle.add(() => {
                            launcher_toggle_requested();
                            return false;
                        });
                    }
                }
            }

            return Gdk.FilterReturn.CONTINUE;
        }

        // Convert display format (Super+E) to keybinder format (<Super>e)
        private string to_keybinder_format(string hotkey_str) {
            // Standalone modifiers and empty strings pass through
            if (hotkey_str == "" || hotkey_str == "Super_L" || hotkey_str == "Super_R") {
                return hotkey_str;
            }

            var parts = hotkey_str.split("+");
            if (parts.length < 2) return hotkey_str;

            string result = "";
            for (int i = 0; i < parts.length - 1; i++) {
                result += "<%s>".printf(parts[i]);
            }

            // Last part is the key name
            string key = parts[parts.length - 1];
            // Lowercase single ASCII letters for correct keysym matching
            if (key.length == 1 && key[0] >= 'A' && key[0] <= 'Z') {
                result += key.down();
            } else {
                result += key;
            }
            return result;
        }

        public bool register_hotkey(string keystring, string action_id) {
            if (!Keybinder.bind_full(keystring, (ks) => {
                on_hotkey_pressed(ks);
            })) {
                warning("Failed to register hotkey: %s", keystring);
                hotkey_error("Failed to register hotkey: %s (may be in use by another application)".printf(keystring));
                return false;
            }

            registered_hotkeys.set(keystring, action_id);
            return true;
        }

        public void unregister_all() {
            var keys = registered_hotkeys.get_keys();
            foreach (var keystring in keys) {
                Keybinder.unbind_all(keystring);
            }
            registered_hotkeys.remove_all();
        }

        public void reload_hotkeys() {
            unregister_all();

            // Cache launcher hotkey for the X11 filter (avoids KeyFile
            // lookup on every key event from the root window)
            string launcher_hotkey = config.get_launcher_hotkey();
            if (launcher_hotkey == "Super_L") {
                cached_super_target = super_l_keycode;
            } else if (launcher_hotkey == "Super_R") {
                cached_super_target = super_r_keycode;
            } else {
                cached_super_target = 0;  // not a bare Super key — filter skips
            }
            if (launcher_hotkey != "") {
                string kb_str = to_keybinder_format(launcher_hotkey);
                if (!register_hotkey(kb_str, "launcher")) {
                    warning("Failed to register launcher hotkey: %s", launcher_hotkey);
                }
            }

            // Register all 4 app hotkey slots (convert format for keybinder)
            for (int slot = 1; slot <= 4; slot++) {
                string app_hotkey = config.get_app_hotkey(slot);
                string app_id = config.get_app_hotkey_id(slot);

                if (app_hotkey != "" && app_id != "") {
                    string kb_str = to_keybinder_format(app_hotkey);
                    string action_id = "app_%d".printf(slot);
                    if (!register_hotkey(kb_str, action_id)) {
                        warning("Failed to register app hotkey for slot %d: %s", slot, app_hotkey);
                    }
                }
            }
        }

        private void on_hotkey_pressed(string keystring) {
            string? action_id = registered_hotkeys.get(keystring);
            if (action_id == null) {
                warning("Hotkey pressed but no action found: %s", keystring);
                return;
            }

            if (action_id == "launcher") {
                handle_launcher_hotkey();
            } else if (action_id.has_prefix("app_")) {
                int slot = int.parse(action_id.substring(4));
                handle_app_hotkey(slot);
            }
        }

        private void handle_launcher_hotkey() {
            // Super_L / Super_R toggle is handled entirely by the X11 root
            // filter (press/release timing) — the keybinder callback is
            // ignored so the action fires exactly once per physical tap.
            if (cached_super_target != 0) {
                return;
            }
            launcher_toggle_requested();
        }

        private void handle_app_hotkey(int slot) {
            string app_id = config.get_app_hotkey_id(slot);
            if (app_id == "") {
                warning("No app configured for hotkey slot %d", slot);
                return;
            }
            launch_or_focus_app(app_id);
        }

        private void launch_or_focus_app(string app_id) {
            var app = app_manager.get_app(app_id);
            if (app == null) {
                // Try to launch as a command or path
                try {
                    string[] argv;
                    Shell.parse_argv(app_id, out argv);
                    Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
                } catch (Error e) {
                    warning("Failed to launch %s: %s", app_id, e.message);
                    hotkey_error("Failed to launch %s: %s".printf(app_id, e.message));
                }
                return;
            }

            var windows = find_app_windows(app_id);

            if (windows.length() > 0) {
                focus_window(windows.first().data);
            } else {
                usage_tracker.record_launch(app_id);
                app.launch();
            }
        }

        private List<Wnck.Window> find_app_windows(string app_id) {
            var result = new List<Wnck.Window>();

            unowned List<Wnck.Window> windows = screen.get_windows();
            foreach (var window in windows) {
                if (window.get_window_type() != Wnck.WindowType.NORMAL) {
                    continue;
                }

                var matched_app = app_manager.find_by_window(new WnckWindow(window));
                if (matched_app != null && matched_app.id == app_id) {
                    result.append(window);
                }
            }

            result.sort((a, b) => {
                return (int)(b.get_sort_order() - a.get_sort_order());
            });

            return result;
        }

        private void focus_window(Wnck.Window window) {
            uint32 timestamp = Keybinder.get_current_event_time();

            var workspace = window.get_workspace();
            var active_workspace = screen.get_active_workspace();

            if (workspace != null && workspace != active_workspace) {
                workspace.activate(timestamp);
            }

            window.activate(timestamp);
        }
    }
}
