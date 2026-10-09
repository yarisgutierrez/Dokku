namespace Dokku {
    public class SeparatorPlugin : Object, Plugin {
        public string id { get { return "separator"; } }
        public string name { get { return "Separator"; } }
        public string icon { owned get { return ""; } }
        public bool has_action { get { return false; } }
        public bool has_menu { get { return false; } }

        public void activate() {}

        public Gtk.Menu? get_menu() {
            return null;
        }

    }
}
