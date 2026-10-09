namespace Dokku {
    // Measures the rendered width of a string.
    public delegate double TextWidthFunc(string text);

    // Text helpers that keep Cairo away from invalid UTF-8, which puts it into an
    // unrecoverable error state that drops all further drawing in the frame.
    public class TextUtil : GLib.Object {
        // Returns `text` if it is valid UTF-8, "" for null/empty, otherwise "?".
        public static string sanitize(string? text) {
            if (text == null || text == "") return "";
            if (text.validate()) return text;
            return "?";
        }

        // Shortens `text` with "..." until `width_of` says it fits `max_width`.
        // Removes whole UTF-8 characters, never bytes, and keeps at least one.
        public static string truncate(string text, double max_width, TextWidthFunc width_of) {
            string safe = sanitize(text);
            if (safe == "") return "";
            if (width_of(safe) <= max_width) return safe;

            int char_count = safe.char_count();
            string result = safe;
            while (char_count > 1) {
                char_count--;
                int byte_offset = safe.index_of_nth_char(char_count);
                result = safe.substring(0, byte_offset);
                if (width_of(result + "...") <= max_width) break;
            }
            return result + "...";
        }
    }
}
