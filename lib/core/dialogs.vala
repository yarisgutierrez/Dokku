namespace Dokku {
    // The small modal dialogs Dokku asks things in
    public class Dialogs : GLib.Object {
        // One line of text from the user, trimmed; null if they cancel or leave it empty
        public static string? ask_text(Gtk.Window parent, string title, string ok_label,
                                       string initial = "", string placeholder = "") {
            var dialog = new Gtk.Dialog.with_buttons(title, parent,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                "_Cancel", Gtk.ResponseType.CANCEL,
                ok_label, Gtk.ResponseType.OK);
            dialog.set_default_response(Gtk.ResponseType.OK);

            var entry = new Gtk.Entry();
            entry.text = initial;
            entry.placeholder_text = placeholder;
            entry.margin = 12;
            entry.activates_default = true;
            dialog.get_content_area().add(entry);
            dialog.show_all();

            string? answer = null;
            if (dialog.run() == Gtk.ResponseType.OK) {
                string text = entry.text.strip();
                if (text != "") answer = text;
            }
            dialog.destroy();
            return answer;
        }

        // The path of a file the user picks (or names, for SAVE), or null if they cancel.
        // `pattern` limits the files shown, e.g. "*.zip" labelled "Theme files (*.zip)".
        public static string? choose_file(Gtk.Window parent, string title, Gtk.FileChooserAction action,
                                          string? pattern = null, string? pattern_label = null,
                                          string? folder = null, string? suggested_name = null) {
            var dialog = new Gtk.FileChooserDialog(title, parent, action,
                "_Cancel", Gtk.ResponseType.CANCEL,
                action == Gtk.FileChooserAction.SAVE ? "_Save" : "_Open", Gtk.ResponseType.ACCEPT);
            if (pattern != null) {
                var filter = new Gtk.FileFilter();
                filter.set_filter_name(pattern_label ?? pattern);
                filter.add_pattern(pattern);
                dialog.add_filter(filter);
            }
            if (folder != null) dialog.set_current_folder(folder);
            if (action == Gtk.FileChooserAction.SAVE) {
                dialog.do_overwrite_confirmation = true;
                if (suggested_name != null) dialog.set_current_name(suggested_name);
            }

            string? path = null;
            if (dialog.run() == Gtk.ResponseType.ACCEPT) path = dialog.get_filename();
            dialog.destroy();
            return path;
        }
    }
}
