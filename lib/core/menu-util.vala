namespace Dokku {
    public delegate void MenuAction();

    // Shorthand for the menus Dokku builds by hand
    public class MenuUtil : GLib.Object {
        public static Gtk.MenuItem add_item(Gtk.MenuShell menu, string label, owned MenuAction action) {
            var item = new Gtk.MenuItem.with_label(label);
            item.activate.connect(() => action());
            menu.append(item);
            return item;
        }

        public static void add_separator(Gtk.MenuShell menu) {
            menu.append(new Gtk.SeparatorMenuItem());
        }

        // Show `menu` at the pointer for a mouse click, or under `anchor` for the
        // keyboard's menu key (no event)
        public static void popup(Gtk.Menu menu, Gdk.EventButton? event, Gtk.Widget? anchor = null) {
            menu.show_all();
            if (event != null || anchor == null) {
                menu.popup_at_pointer(event);
            } else {
                menu.popup_at_widget(anchor, Gdk.Gravity.SOUTH, Gdk.Gravity.NORTH, null);
            }
        }
    }
}
