namespace Dokku {
    public class ShowDesktopPlugin : Object, Plugin {
        public string id { get { return "show-desktop"; } }
        public string name { get { return "Show Desktop"; } }
        public string icon { owned get { return "desktop"; } }
        public bool has_action { get { return true; } }
        public bool has_menu { get { return false; } }

        private bool showing_desktop = false;

        public void activate() {
            if (WindowManager.toggle_showing_desktop(!showing_desktop)) {
                showing_desktop = !showing_desktop;
            }
        }

        public Gtk.Menu? get_menu() {
            return null;
        }

    }
}
