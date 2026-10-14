namespace Dokku {
    public class ScriptPlugin : Object, Plugin {
        private string? _id;
        private string _name;
        private string _icon;
        private string? _command;
        private string _path;
        private string _type;
        private string? _format;
        private string? _script;
        private int _interval;
        private string _display_text;
        private string _tooltip = "";
        private string? _tooltip_format;
        private string? _scroll_up;
        private string? _scroll_down;
        private bool _hide_when_empty = false;
        private bool _default_enabled = true;
        private uint _timer_id;

        public string id { get { return _id; } }
        public string name { get { return _name; } }
        public string icon { owned get { return _icon; } }
        public string path { get { return _path; } }
        public string display_text { get { return _display_text; } }
        // The name, unless the plugin has something more to say (a script's later lines,
        // or a tooltip_format)
        public string tooltip { owned get { return _tooltip != "" ? _tooltip : _name; } }
        public bool has_scroll { get { return _scroll_up != null || _scroll_down != null; } }
        // Plugins that ship with Dokku start switched off, so an upgrade adds nothing
        public bool enabled_by_default { get { return _default_enabled; } }
        // A widget with nothing to show (a battery plugin on a desktop) takes no space
        public bool visible_in_dock { get { return !_hide_when_empty || _display_text != ""; } }
        public bool has_action { get { return _command != null && _command.length > 0; } }
        public bool has_menu { get { return false; } }
        public bool is_widget { get { return _type == "widget"; } }

        public signal void updated();

        private const int MAX_OUTPUT = 1024;
        private const int MAX_TEXT = 64;
        private const int MAX_TOOLTIP = 400;

        // A script's output: the first line is shown on the icon, and the lines after it
        // become the tooltip. Anything that is not valid text is replaced, and both parts
        // are cut to a sensible length.
        public static void parse_output(string raw, out string text, out string tooltip) {
            string clean = TextUtil.sanitize(raw).replace("\r", "");
            int newline = clean.index_of_char('\n');
            string first = newline >= 0 ? clean.substring(0, newline) : clean;
            string rest = newline >= 0 ? clean.substring(newline + 1) : "";
            text = limit_chars(first.strip(), MAX_TEXT);
            tooltip = limit_chars(rest.strip(), MAX_TOOLTIP);
        }

        private static string limit_chars(string s, int max_chars) {
            if (s.char_count() <= max_chars) return s;
            int end = s.index_of_nth_char(max_chars);
            return s.substring(0, end);
        }

        public ScriptPlugin.from_file(string path) {
            _path = path;
            _display_text = "";
            load();
            if (is_widget) {
                update_widget();
                if (_interval > 0) {
                    _timer_id = Timeout.add_seconds(_interval, () => {
                        update_widget();
                        return true;
                    });
                }
            }
        }

        ~ScriptPlugin() {
            if (_timer_id > 0) Source.remove(_timer_id);
        }

        private void load() {
            try {
                var keyfile = new KeyFile();
                keyfile.load_from_file(_path, KeyFileFlags.NONE);

                _id = keyfile.get_string("Plugin", "id");
                _name = keyfile.get_string("Plugin", "name");
                _icon = keyfile.has_key("Plugin", "icon") ? keyfile.get_string("Plugin", "icon") : "";
                _type = keyfile.has_key("Plugin", "type") ? keyfile.get_string("Plugin", "type") : "launcher";
                
                if (keyfile.has_key("Plugin", "command"))
                    _command = keyfile.get_string("Plugin", "command");
                if (keyfile.has_key("Plugin", "format"))
                    _format = keyfile.get_string("Plugin", "format");
                if (keyfile.has_key("Plugin", "script"))
                    _script = keyfile.get_string("Plugin", "script");
                if (keyfile.has_key("Plugin", "interval"))
                    _interval = keyfile.get_integer("Plugin", "interval");
                else
                    _interval = 1;
                if (keyfile.has_key("Plugin", "tooltip_format"))
                    _tooltip_format = keyfile.get_string("Plugin", "tooltip_format");
                if (keyfile.has_key("Plugin", "scroll_up"))
                    _scroll_up = keyfile.get_string("Plugin", "scroll_up");
                if (keyfile.has_key("Plugin", "scroll_down"))
                    _scroll_down = keyfile.get_string("Plugin", "scroll_down");
                if (keyfile.has_key("Plugin", "hide_when_empty"))
                    _hide_when_empty = keyfile.get_boolean("Plugin", "hide_when_empty");
                if (keyfile.has_key("Plugin", "default_enabled"))
                    _default_enabled = keyfile.get_boolean("Plugin", "default_enabled");
            } catch (Error e) {
                _id = null;
            }
        }

        private void update_widget() {
            if (_format != null) {
                var now = new DateTime.now_local();
                _display_text = now.format(_format);
                if (_tooltip_format != null) _tooltip = now.format(_tooltip_format) ?? "";
                updated();
            } else if (_script != null) {
                try {
                    string[] argv;
                    Shell.parse_argv(resolve_command(_script), out argv);
                    Pid child_pid;
                    int stdout_fd;
                    Process.spawn_async_with_pipes(null, argv, null,
                        SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD,
                        null, out child_pid, null, out stdout_fd, null);
                    var channel = new IOChannel.unix_new(stdout_fd);
                    ChildWatch.add(child_pid, (pid, status) => {
                        Process.close_pid(pid);
                        try {
                            char[] buf = new char[MAX_OUTPUT];
                            size_t bytes_read;
                            channel.read_chars(buf, out bytes_read);
                            parse_output(((string) buf).substring(0, (long) bytes_read),
                                         out _display_text, out _tooltip);
                        } catch (Error read_err) {
                            _display_text = "?";
                            _tooltip = "";
                        }
                        try { channel.shutdown(false); } catch (Error e) {}
                        updated();
                    });
                } catch (Error e) {
                    warning("Script plugin %s: spawn failed: %s", _id ?? "unknown", e.message);
                    _display_text = "?";
                    updated();
                }
            }
        }

        public void activate() {
            if (_command != null) run_command(_command);
        }

        // Scroll over the widget: up or down
        public void scroll(bool up) {
            var cmd = up ? _scroll_up : _scroll_down;
            if (cmd != null) run_command(cmd);
        }

        // The program is the first word. A file of that name next to plugin.ini wins over
        // one on the path, so a plugin can ship its own scripts and give them arguments.
        private string resolve_command(string command) {
            string first_word = command.split(" ")[0];
            if (!Path.is_absolute(first_word) &&
                FileUtils.test(Path.build_filename(Path.get_dirname(_path), first_word), FileTest.EXISTS)) {
                return Path.build_filename(Path.get_dirname(_path), first_word) +
                       command.substring(first_word.length);
            }
            return command;
        }

        // Runs a plugin command (a file next to plugin.ini, or a command on the path). A
        // widget refreshes once the command is done, so a change shows at once.
        private void run_command(string command) {
            try {
                string[] argv;
                Shell.parse_argv(resolve_command(command), out argv);
                FileUtil.run_watched(argv, (ok) => {
                    if (is_widget) update_widget();
                });
            } catch (Error e) {
                warning("Script plugin %s: command failed: %s", _id ?? "unknown", e.message);
            }
        }

        public Gtk.Menu? get_menu() {
            return null;
        }

    }
}
