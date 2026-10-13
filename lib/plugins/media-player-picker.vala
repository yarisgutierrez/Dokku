namespace Dokku {
    public enum PlayerStatus {
        PLAYING,
        PAUSED,
        STOPPED,
        UNKNOWN;

        public static PlayerStatus parse(string? status) {
            switch (status) {
                case "Playing": return PLAYING;
                case "Paused": return PAUSED;
                case "Stopped": return STOPPED;
                default: return UNKNOWN;
            }
        }

        // Lower ranks are preferred
        public int rank() {
            switch (this) {
                case PLAYING: return 0;
                case PAUSED: return 1;
                case STOPPED: return 2;
                default: return 3;
            }
        }
    }

    // Decides which MPRIS2 player the media widget follows. No D-Bus here, so the
    // rules can be tested on their own.
    public class MediaPlayerPicker : Object {
        // Preferred players in priority order, used to break ties
        public const string[] PREFERRED = {
            "spotify", "vlc", "rhythmbox", "audacious", "clementine", "strawberry"
        };

        // Browsers and other non-music sources ignored unless the user changes the list
        public const string[] DEFAULT_BLOCKED = {
            "firefox", "chromium", "chrome", "brave", "opera",
            "vivaldi", "edge", "epiphany", "midori",
            "plasma-browser-integration", "kdeconnect"
        };

        public static bool is_blocked(string bus_name, string[] blocked) {
            var lower = bus_name.down();
            foreach (var entry in blocked) {
                var word = entry.strip().down();
                if (word != "" && lower.contains(word)) return true;
            }
            return false;
        }

        public static int priority(string bus_name) {
            var lower = bus_name.down();
            for (int i = 0; i < PREFERRED.length; i++) {
                if (lower.contains(PREFERRED[i])) return i;
            }
            return PREFERRED.length;
        }

        // The rules the widget used before it looked at playback state: the first
        // player in the fixed priority list, whatever it is doing.
        public static string? choose_by_priority(string[] names) {
            string? best = null;
            foreach (var n in names) {
                if (best == null || priority(n) < priority(best)) best = n;
            }
            return best;
        }

        // names and statuses are parallel; current is the player followed now, if any.
        //  1. A player that is playing wins. If the current one is playing it keeps
        //     the widget, so two players playing at once do not make it flip.
        //  2. With nothing playing the current player stays, so pausing does not
        //     hand the widget to another player.
        //  3. Otherwise paused beats stopped, then the priority list, then the name.
        public static string? choose(string[] names, PlayerStatus[] statuses, string? current) {
            if (names.length == 0) return null;

            int cur = -1;
            for (int i = 0; i < names.length; i++) {
                if (names[i] == current) cur = i;
            }
            if (cur >= 0 && statuses[cur] == PlayerStatus.PLAYING) return current;

            int best = -1;
            for (int i = 0; i < names.length; i++) {
                if (best < 0 || is_better(names[i], statuses[i], names[best], statuses[best])) {
                    best = i;
                }
            }
            if (statuses[best] != PlayerStatus.PLAYING && cur >= 0) return current;
            return names[best];
        }

        private static bool is_better(string a, PlayerStatus sa, string b, PlayerStatus sb) {
            if (sa.rank() != sb.rank()) return sa.rank() < sb.rank();
            if (priority(a) != priority(b)) return priority(a) < priority(b);
            return strcmp(a, b) < 0;
        }
    }
}
