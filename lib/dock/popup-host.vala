namespace Dokku {
    // What a dock popup needs to know about the dock that owns it.
    public interface PopupHost : GLib.Object {
        public abstract DockItem? popup_item(int index);
        public abstract Theme? popup_theme();
        public abstract bool popup_is_light();
        // Window popups must be transient for, or null when absolute positioning works
        // (X11). Wayland can only place a popup relative to a parent surface.
        public abstract Gtk.Window? popup_parent();
        // Show `popup` next to dock item `index`, `gap` pixels away, on the side of the
        // dock that faces the screen. Call after the popup's content is built.
        // With `modal`, the popup grabs the pointer (and keyboard) so the caller can
        // close it on any click elsewhere; see PopupHelper.connect_dismissal().
        public abstract void show_popup(Gtk.Window popup, int index, int gap, bool modal = false);
    }
}
