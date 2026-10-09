namespace Dokku {
    // What a dock popup needs to know about the dock that owns it.
    public interface PopupHost : GLib.Object {
        public abstract DockItem? popup_item(int index);
        public abstract Theme? popup_theme();
        public abstract bool popup_is_light();
        // Top-left screen position for a popup of the given size anchored to item `index`.
        public abstract void popup_position(int index, int popup_w, int popup_h, int gap,
                                            out int out_x, out int out_y);
    }
}
