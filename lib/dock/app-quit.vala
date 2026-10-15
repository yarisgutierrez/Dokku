namespace Dokku {
    // Quit for the dock menu. An app that exports the standard GApplication "quit" action
    // over D-Bus is asked to quit through it, so it runs its own save prompts and leaves the
    // tray. Any other app gets a close request on each of its windows, and if it is still
    // running once they are gone (Spotify and other tray apps just hide) it is sent SIGTERM.
    namespace AppQuit {
        private const uint POLL_MS = 250;
        private const int WINDOW_WAIT_POLLS = 20;  // 5 s for the windows to go away
        private const int TERM_GRACE_POLLS = 12;   // 3 s for the process to exit on SIGTERM

        private void close_windows(List<weak TrackedWindow> windows) {
            foreach (var window in windows) window.close();
        }

        public async void quit(DockItem item) {
            item.quitting = true;
            yield quit_item(item);
            item.quitting = false;
        }

        private async void quit_item(DockItem item) {
            // Windows are closed from a copy: the dock's list changes as they go away
            var snapshot = new List<weak TrackedWindow>();
            foreach (var window in item.windows) snapshot.append(window);

            // Find the processes before the windows go: afterwards nothing says whose they were
            var pids = find_pids(item, snapshot);
            debug("quit %s: %u windows, pids [%s], remembered [%s]", item.id, snapshot.length(),
                  join_ints(pids), join_ints(item.pids));

            if (yield quit_over_dbus(item.id)) { debug("quit %s: done over D-Bus", item.id); return; }

            // A media player (Spotify, VLC...) ends itself through MPRIS even when it ignores
            // SIGTERM, and with no window to close
            if (pids.length > 0 && yield quit_over_mpris(pids)) {
                debug("quit %s: done over MPRIS", item.id);
                return;
            }

            close_windows(snapshot);
            if (pids.length == 0) { debug("quit %s: no process found, windows closed only", item.id); return; }

            // Hold off while a window is still up: it may be a "save changes?" prompt
            for (int i = 0; i < WINDOW_WAIT_POLLS && item.windows.length() > 0; i++) yield sleep(POLL_MS);
            if (item.windows.length() > 0) {
                debug("quit %s: %u window(s) still open after the wait, not terminating", item.id, item.windows.length());
                return;
            }

            debug("quit %s: windows gone, SIGTERM [%s]", item.id, join_ints(pids));
            yield terminate(pids);
        }

        // True when the app took the quit through its GApplication "quit" action
        private async bool quit_over_dbus(string app_id) {
            if (!GLib.Application.id_is_valid(app_id)) return false;
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
                        return true;
                    }
                }
            } catch (Error e) {
                // No such name or interface: the app does not offer a quit action
            }
            return false;
        }

        // Calls org.mpris.MediaPlayer2.Quit on a player that belongs to `pids` and allows it,
        // then waits briefly. True when the processes are gone afterwards.
        private async bool quit_over_mpris(int[] pids) {
            bool asked = false;
            try {
                var bus = yield Bus.get(BusType.SESSION);
                var list = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "ListNames", null, new VariantType("(as)"),
                    DBusCallFlags.NONE, 500);
                foreach (var name in list.get_child_value(0).get_strv()) {
                    if (!name.has_prefix("org.mpris.MediaPlayer2.")) continue;
                    try {
                        var owner = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                            "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                            new Variant("(s)", name), new VariantType("(u)"), DBusCallFlags.NONE, 500);
                        uint owner_pid;
                        owner.get("(u)", out owner_pid);
                        if (!is_in_tree((int) owner_pid, pids)) continue;

                        var can = yield bus.call(name, "/org/mpris/MediaPlayer2",
                            "org.freedesktop.DBus.Properties", "Get",
                            new Variant("(ss)", "org.mpris.MediaPlayer2", "CanQuit"),
                            new VariantType("(v)"), DBusCallFlags.NO_AUTO_START, 500);
                        Variant value;
                        can.get_child_value(0).get("v", out value);
                        if (!value.get_boolean()) continue;
                        yield bus.call(name, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2",
                            "Quit", null, null, DBusCallFlags.NO_AUTO_START, 500);
                        asked = true;
                    } catch (Error e) {
                        // This player did not answer: try the next, or fall back
                    }
                }
            } catch (Error e) {
                return false;
            }
            if (!asked) return false;
            for (int i = 0; i < 8; i++) {
                yield sleep(POLL_MS);
                bool alive = false;
                foreach (var pid in pids) if (is_alive(pid)) alive = true;
                if (!alive) return true;
            }
            return false;
        }

        private async void sleep(uint ms) {
            Timeout.add(ms, () => { sleep.callback(); return false; });
            yield;
        }

        // SIGTERM, and a check afterwards that it worked. SIGKILL stays with Force Close.
        private async void terminate(int[] pids) {
            foreach (var pid in pids) Posix.kill(pid, Posix.Signal.TERM);
            for (int i = 0; i < TERM_GRACE_POLLS; i++) {
                yield sleep(POLL_MS);
                bool alive = false;
                foreach (var pid in pids) if (is_alive(pid)) alive = true;
                if (!alive) return;
            }
            warning("%d process(es) ignored SIGTERM; use Force Close", pids.length);
        }

        private string join_ints(int[] values) {
            string[] parts = {};
            foreach (var v in values) parts += v.to_string();
            return string.joinv(" ", parts);
        }

        public bool is_alive(int pid) {
            return FileUtils.test("/proc/%d".printf(pid), FileTest.EXISTS);
        }

        // The app's top-level processes. X11 windows carry their PID. On Wayland nothing
        // does, so the app's processes are matched by executable name instead.
        public int[] find_pids(DockItem item, List<weak TrackedWindow> windows) {
            int[] found = {};
            foreach (var window in windows) {
                int pid = window.get_pid();
                if (pid > 1 && !is_own(pid) && !(pid in found)) found += pid;
            }
            if (found.length > 0) return found;
            // No window now: use the PIDs seen while it had one, if they are still alive
            foreach (var pid in item.pids) if (is_alive(pid)) found += pid;
            return found.length > 0 ? found : scan_proc(executable_names(item));
        }

        private bool is_own(int pid) { return pid == (int) Posix.getpid(); }

        // Lower-case executable names the app can be running as
        private string[] executable_names(DockItem item) {
            string[] names = {};
            if (item.id != "") names += item.id.down();
            if (item.desktop_file != null && item.desktop_file != "") {
                var info = new DesktopAppInfo.from_filename(item.desktop_file);
                if (info != null) {
                    string? exec = info.get_string("Exec");
                    try {
                        string[] argv = {};
                        if (exec != null) {
                            Shell.parse_argv(exec, out argv);
                            foreach (var arg in argv) {
                                // Skip a wrapper such as "env FOO=1" to reach the program
                                if (arg == "env" || arg.contains("=") || arg.has_prefix("-")) continue;
                                string program = Path.get_basename(arg).down();
                                if (!is_generic_program(program)) names += program;
                                break;
                            }
                        }
                    } catch (ShellError e) {}
                }
            }
            return names;
        }

        // Interpreters and launchers: many unrelated processes run as these, so an app
        // that starts through one cannot be told apart by its name
        private bool is_generic_program(string name) {
            if (name.has_prefix("python") || name.has_prefix("perl") || name.has_prefix("ruby") ||
                name.has_prefix("node") || name.has_prefix("java")) return true;
            string[] generic = { "env", "sh", "bash", "dash", "zsh", "fish", "flatpak", "snap", "gjs",
                "mono", "wine", "electron", "xdg-open", "gtk-launch", "dbus-launch", "dbus-run-session",
                "systemd-run", "sudo", "pkexec", "nohup", "setsid", "firejail", "bwrap" };
            return name in generic;
        }

        // This user's processes whose executable is one of `names`, minus any whose
        // parent is also a match: ending the root takes its helpers with it.
        private int[] scan_proc(string[] names) {
            if (names.length == 0) return {};
            int[] pids = {};
            int[] ppids = {};
            try {
                var dir = Dir.open("/proc");
                string? entry;
                while ((entry = dir.read_name()) != null) {
                    int pid = int.parse(entry);
                    if (pid <= 1 || is_own(pid)) continue;
                    string cmdline;
                    if (!FileUtils.get_contents("/proc/%d/cmdline".printf(pid), out cmdline)) continue;
                    // The file holds argv separated by NULs; read as a string it ends at the first
                    string argv0 = Path.get_basename(cmdline).down();
                    if (!(argv0 in names)) continue;
                    Posix.Stat st;
                    if (Posix.stat("/proc/%d".printf(pid), out st) != 0 || st.st_uid != Posix.getuid()) continue;
                    pids += pid;
                    ppids += parent_of(pid);
                }
            } catch (Error e) {
                return {};
            }
            int[] roots = {};
            for (int i = 0; i < pids.length; i++) {
                if (!(ppids[i] in pids)) roots += pids[i];
            }
            return roots;
        }

        // Whether `pid` is one of `roots` or started by one of them
        public bool is_in_tree(int pid, int[] roots) {
            for (int depth = 0; pid > 1 && depth < 32; depth++) {
                if (pid in roots) return true;
                pid = parent_of(pid);
            }
            return false;
        }

        private int parent_of(int pid) {
            string stat;
            try {
                if (!FileUtils.get_contents("/proc/%d/stat".printf(pid), out stat)) return 0;
            } catch (Error e) { return 0; }
            // "pid (comm) S ppid ...": comm may hold spaces and parentheses, so read after the last ")"
            int close = stat.last_index_of(")");
            if (close < 0) return 0;
            var fields = stat.substring(close + 2).split(" ");
            return fields.length > 1 ? int.parse(fields[1]) : 0;
        }
    }
}
