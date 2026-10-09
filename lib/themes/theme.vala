namespace Dokku {
    public class Theme : Object {
        public string id { get; set; }
        public string name { get; set; }
        public string path { get; set; }

        public double bg_red { get; set; default = 0.12; }
        public double bg_green { get; set; default = 0.12; }
        public double bg_blue { get; set; default = 0.12; }
        public double bg_alpha { get; set; default = 0.55; }

        public double border_red { get; set; default = 1.0; }
        public double border_green { get; set; default = 1.0; }
        public double border_blue { get; set; default = 1.0; }
        public double border_alpha { get; set; default = 0.08; }

        public double indicator_red { get; set; default = 1.0; }
        public double indicator_green { get; set; default = 1.0; }
        public double indicator_blue { get; set; default = 1.0; }
        public double indicator_alpha { get; set; default = 0.4; }

        public double corner_radius { get; set; default = 16; }
        public double border_width { get; set; default = 1; }

        public bool is_light() {
            return (0.299 * bg_red + 0.587 * bg_green + 0.114 * bg_blue) > 0.5;
        }

        public Theme(string id, string name) {
            this.id = id;
            this.name = name;
        }

        public Theme.from_file(string path) {
            this.path = path;
            this.id = Path.get_basename(Path.get_dirname(path));
            load();
        }

        // Reads one number, keeping `fallback` if the section or key is missing or
        // the value isn't numeric. (has_key() throws when the whole group is absent,
        // so a theme without e.g. [Border] must not abort the rest of the parse.)
        private static double read_double(KeyFile keyfile, string group, string key, double fallback) {
            try {
                if (keyfile.has_key(group, key))
                    return keyfile.get_double(group, key);
            } catch (Error e) {
                // fall through to the default
            }
            return fallback;
        }

        private void load() {
            var keyfile = new KeyFile();
            try {
                keyfile.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
                name = id;
                return;
            }

            try {
                name = keyfile.get_string("Theme", "name");
            } catch (Error e) {
                name = id;
            }

            bg_red = read_double(keyfile, "Background", "red", bg_red);
            bg_green = read_double(keyfile, "Background", "green", bg_green);
            bg_blue = read_double(keyfile, "Background", "blue", bg_blue);
            bg_alpha = read_double(keyfile, "Background", "alpha", bg_alpha);

            border_red = read_double(keyfile, "Border", "red", border_red);
            border_green = read_double(keyfile, "Border", "green", border_green);
            border_blue = read_double(keyfile, "Border", "blue", border_blue);
            border_alpha = read_double(keyfile, "Border", "alpha", border_alpha);

            indicator_red = read_double(keyfile, "Indicator", "red", indicator_red);
            indicator_green = read_double(keyfile, "Indicator", "green", indicator_green);
            indicator_blue = read_double(keyfile, "Indicator", "blue", indicator_blue);
            indicator_alpha = read_double(keyfile, "Indicator", "alpha", indicator_alpha);

            corner_radius = read_double(keyfile, "Style", "corner_radius", corner_radius);
            border_width = read_double(keyfile, "Style", "border_width", border_width);

            // Clamp all values to safe ranges
            bg_red = bg_red.clamp(0.0, 1.0);
            bg_green = bg_green.clamp(0.0, 1.0);
            bg_blue = bg_blue.clamp(0.0, 1.0);
            bg_alpha = bg_alpha.clamp(0.0, 1.0);
            border_red = border_red.clamp(0.0, 1.0);
            border_green = border_green.clamp(0.0, 1.0);
            border_blue = border_blue.clamp(0.0, 1.0);
            border_alpha = border_alpha.clamp(0.0, 1.0);
            indicator_red = indicator_red.clamp(0.0, 1.0);
            indicator_green = indicator_green.clamp(0.0, 1.0);
            indicator_blue = indicator_blue.clamp(0.0, 1.0);
            indicator_alpha = indicator_alpha.clamp(0.0, 1.0);
            corner_radius = corner_radius.clamp(0.0, 100.0);
            border_width = border_width.clamp(0.0, 20.0);
        }
    }
}
