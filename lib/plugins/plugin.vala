namespace Dokku {
    public interface Plugin : Object {
        public abstract string id { get; }
        public abstract string name { get; }
        public abstract string icon { owned get; }
        public abstract bool has_action { get; }
        public abstract bool has_menu { get; }

        public abstract void activate();
        public abstract Gtk.Menu? get_menu();
    }
}
