namespace Dokku {
    public class MediaPlugin : Object, Plugin {
        public string id { get { return "media-player"; } }
        public string name { get { return "Now Playing"; } }
        public string icon { owned get { return _playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"; } }
        public bool has_action { get { return true; } }
        public bool has_menu { get { return _has_media; } }

        public string track_title { get; private set; default = ""; }
        public string track_artist { get; private set; default = ""; }
        public string art_url { get; private set; default = ""; }
        public bool is_playing { get { return _playing; } }
        public bool has_media { get { return _has_media; } }
        public string player_name { get; private set; default = ""; }

        public signal void changed();

        private bool _playing = false;
        private bool _has_media = false;
        private DBusProxy? player_proxy = null;
        private string? current_bus_name = null;
        private Gdk.Pixbuf? _art_pixbuf = null;
        private Gdk.Pixbuf? _art_scaled = null;
        private int _art_cached_size = 0;
        private DBusConnection? dbus_connection = null;
        private uint name_owner_subscription_id = 0;

        // Preferred MPRIS2 players in priority order
        private const string[] PREFERRED_PLAYERS = {
            "spotify",
            "vlc",
            "rhythmbox",
            "audacious",
            "clementine",
            "strawberry"
        };

        // Browsers and non-music sources to ignore
        private const string[] BLOCKED_PLAYERS = {
            "firefox", "chromium", "chrome", "brave", "opera",
            "vivaldi", "edge", "epiphany", "midori",
            "plasma-browser-integration", "kdeconnect"
        };

        public MediaPlugin() {
            watch_media_players.begin();
        }

        private bool is_blocked_player(string bus_name) {
            var lower = bus_name.down();
            foreach (var blocked in BLOCKED_PLAYERS) {
                if (lower.contains(blocked)) return true;
            }
            return false;
        }

        ~MediaPlugin() {
            if (dbus_connection != null && name_owner_subscription_id != 0) {
                dbus_connection.signal_unsubscribe(name_owner_subscription_id);
                name_owner_subscription_id = 0;
            }
            disconnect_player();
        }

        private async void watch_media_players() {
            try {
                var connection = yield Bus.get(BusType.SESSION);
                dbus_connection = connection;

                // Watch for name changes (new players appearing/disappearing)
                name_owner_subscription_id = connection.signal_subscribe(
                    "org.freedesktop.DBus",
                    "org.freedesktop.DBus",
                    "NameOwnerChanged",
                    "/org/freedesktop/DBus",
                    null,
                    DBusSignalFlags.NONE,
                    on_name_owner_changed
                );

                // Scan for existing players
                yield scan_for_players(connection);
            } catch (Error e) {
                warning("MediaPlugin: Failed to watch D-Bus: %s", e.message);
            }
        }

        private async void scan_for_players(DBusConnection connection) {
            try {
                var result = yield connection.call(
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus",
                    "ListNames",
                    null,
                    new VariantType("(as)"),
                    DBusCallFlags.NONE,
                    5000,
                    null
                );

                var names = result.get_child_value(0);
                var iter = names.iterator();
                string? name_str;

                // Find best player by preference
                string? best = null;
                int best_priority = int.MAX;

                while (iter.next("s", out name_str)) {
                    if (!name_str.has_prefix("org.mpris.MediaPlayer2.")) continue;
                    if (is_blocked_player(name_str)) continue;

                    int priority = get_player_priority(name_str);
                    if (priority < best_priority) {
                        best_priority = priority;
                        best = name_str;
                    }
                }

                if (best != null) {
                    yield connect_to_player(best);
                }
            } catch (Error e) {
                warning("MediaPlugin: Failed to list D-Bus names: %s", e.message);
            }
        }

        private int get_player_priority(string bus_name) {
            var lower = bus_name.down();
            for (int i = 0; i < PREFERRED_PLAYERS.length; i++) {
                if (lower.contains(PREFERRED_PLAYERS[i])) return i;
            }
            return PREFERRED_PLAYERS.length;
        }

        private void on_name_owner_changed(DBusConnection connection, string? sender,
                                            string object_path, string interface_name,
                                            string signal_name, Variant parameters) {
            string name_str;
            string old_owner;
            string new_owner;
            parameters.get("(sss)", out name_str, out old_owner, out new_owner);

            if (!name_str.has_prefix("org.mpris.MediaPlayer2.")) return;
            if (is_blocked_player(name_str)) return;

            if (new_owner != "" && player_proxy == null) {
                // New player appeared and we don't have one yet
                connect_to_player.begin(name_str);
            } else if (new_owner != "" && player_proxy != null) {
                // New player appeared but we already have one — switch if higher priority
                int new_priority = get_player_priority(name_str);
                int cur_priority = current_bus_name != null ? get_player_priority(current_bus_name) : int.MAX;
                if (new_priority < cur_priority) {
                    disconnect_player();
                    connect_to_player.begin(name_str);
                }
            } else if (old_owner != "" && name_str == current_bus_name) {
                // Our player vanished
                disconnect_player();
                changed();
                // Try to find another player
                scan_for_players.begin(connection);
            }
        }

        private void disconnect_player() {
            player_proxy = null;
            current_bus_name = null;
            player_name = "";
            track_title = "";
            track_artist = "";
            art_url = "";
            _art_pixbuf = null;
            _art_scaled = null;
            _art_cached_size = 0;
            _playing = false;
            _has_media = false;
        }

        private async void connect_to_player(string bus_name) {
            try {
                player_proxy = yield new DBusProxy.for_bus(
                    BusType.SESSION,
                    DBusProxyFlags.GET_INVALIDATED_PROPERTIES,
                    null,
                    bus_name,
                    "/org/mpris/MediaPlayer2",
                    "org.mpris.MediaPlayer2.Player",
                    null
                );

                current_bus_name = bus_name;

                // Extract human-readable player name from bus name
                // e.g. "org.mpris.MediaPlayer2.spotify" -> "Spotify"
                var parts = bus_name.split(".");
                if (parts.length > 3) {
                    var raw = parts[3];
                    // Capitalize first letter
                    if (raw.length > 0) {
                        player_name = raw.substring(0, 1).up() + raw.substring(1);
                    } else {
                        player_name = raw;
                    }
                }

                player_proxy.g_properties_changed.connect(on_properties_changed);

                // Read initial state
                update_metadata();
                update_playback_status();
                refresh_has_media();

                if (_has_media) {
                    changed();
                }
            } catch (Error e) {
                warning("MediaPlugin: Failed to connect to %s: %s", bus_name, e.message);
            }
        }

        private void refresh_has_media() {
            // Only show widget when there's an actual track with a title
            _has_media = player_proxy != null && track_title != "";
        }

        private void on_properties_changed(DBusProxy proxy, Variant changed_properties,
                                            string[] invalidated) {
            var iter = changed_properties.iterator();
            string key;
            Variant val;
            bool updated = false;

            while (iter.next("{sv}", out key, out val)) {
                if (key == "Metadata") {
                    update_metadata_from_variant(val);
                    updated = true;
                } else if (key == "PlaybackStatus") {
                    update_playback_status_from_variant(val);
                    updated = true;
                }
            }

            foreach (var prop in invalidated) {
                if (prop == "Metadata") {
                    update_metadata();
                    updated = true;
                } else if (prop == "PlaybackStatus") {
                    update_playback_status();
                    updated = true;
                }
            }

            if (updated) {
                refresh_has_media();
                changed();
            }
        }

        private void update_metadata() {
            if (player_proxy == null) return;
            var metadata = player_proxy.get_cached_property("Metadata");
            if (metadata != null) {
                update_metadata_from_variant(metadata);
            }
        }

        private void update_metadata_from_variant(Variant metadata) {
            var title_val = metadata.lookup_value("xesam:title", VariantType.STRING);
            track_title = title_val != null ? title_val.get_string() : "";

            var artist_val = metadata.lookup_value("xesam:artist", new VariantType("as"));
            if (artist_val != null && artist_val.n_children() > 0) {
                track_artist = artist_val.get_child_value(0).get_string();
            } else {
                track_artist = "";
            }

            // Album art URL
            var art_val = metadata.lookup_value("mpris:artUrl", VariantType.STRING);
            string new_art_url = art_val != null ? art_val.get_string() : "";
            if (new_art_url != art_url) {
                art_url = new_art_url;
                if (art_url != "") {
                    load_art_async.begin(art_url);
                } else {
                    _art_pixbuf = null;
                    _art_scaled = null;
                    _art_cached_size = 0;
                }
            }
        }

        private bool is_safe_art_url(string url) {
            return url.has_prefix("https://") || url.has_prefix("http://") || url.has_prefix("file://");
        }

        private async void load_art_async(string url) {
            if (!is_safe_art_url(url)) {
                _art_pixbuf = null;
                _art_scaled = null;
                _art_cached_size = 0;
                return;
            }
            try {
                var file = File.new_for_uri(url);
                var stream = yield file.read_async(Priority.DEFAULT, null);
                _art_pixbuf = yield new Gdk.Pixbuf.from_stream_async(stream, null);
                _art_scaled = null;
                _art_cached_size = 0;
                changed();
            } catch (Error e) {
                _art_pixbuf = null;
                _art_scaled = null;
                _art_cached_size = 0;
            }
        }

        public Gdk.Pixbuf? get_art(int size) {
            if (_art_pixbuf == null) return null;
            if (_art_cached_size == size && _art_scaled != null) return _art_scaled;
            _art_scaled = _art_pixbuf.scale_simple(size, size, Gdk.InterpType.BILINEAR);
            _art_cached_size = size;
            return _art_scaled;
        }

        private void update_playback_status() {
            if (player_proxy == null) return;
            var status = player_proxy.get_cached_property("PlaybackStatus");
            if (status != null) {
                update_playback_status_from_variant(status);
            }
        }

        private void update_playback_status_from_variant(Variant status) {
            _playing = status.get_string() == "Playing";
        }

        public void activate() {
            if (player_proxy == null) return;
            player_proxy.call.begin(
                "PlayPause", null, DBusCallFlags.NONE, 5000, null,
                (obj, res) => {
                    try { player_proxy.call.end(res); }
                    catch (Error e) { warning("MediaPlugin: PlayPause failed: %s", e.message); }
                }
            );
        }

        public void next() {
            if (player_proxy == null) return;
            player_proxy.call.begin(
                "Next", null, DBusCallFlags.NONE, 5000, null,
                (obj, res) => {
                    try { player_proxy.call.end(res); }
                    catch (Error e) { warning("MediaPlugin: Next failed: %s", e.message); }
                }
            );
        }

        public void previous() {
            if (player_proxy == null) return;
            player_proxy.call.begin(
                "Previous", null, DBusCallFlags.NONE, 5000, null,
                (obj, res) => {
                    try { player_proxy.call.end(res); }
                    catch (Error e) { warning("MediaPlugin: Previous failed: %s", e.message); }
                }
            );
        }

        public Gtk.Menu? get_menu() {
            if (!_has_media) return null;
            var menu = new Gtk.Menu();
            // Track info (disabled, informational)
            var info = new Gtk.MenuItem.with_label(track_title + " — " + track_artist);
            info.sensitive = false;
            menu.append(info);
            menu.append(new Gtk.SeparatorMenuItem());
            // Play/Pause
            var pp = new Gtk.MenuItem.with_label(_playing ? "Pause" : "Play");
            pp.activate.connect(() => activate());
            menu.append(pp);
            // Next
            var next_item = new Gtk.MenuItem.with_label("Next Track");
            next_item.activate.connect(() => next());
            menu.append(next_item);
            // Previous
            var prev_item = new Gtk.MenuItem.with_label("Previous Track");
            prev_item.activate.connect(() => previous());
            menu.append(prev_item);
            menu.show_all();
            return menu;
        }

    }
}
