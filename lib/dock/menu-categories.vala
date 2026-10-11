namespace Dokku {
    // Files apps into categories the way the desktop's own application menu does, by
    // reading its definition (for Xfce, /etc/xdg/menus/xfce-applications.menu) instead of
    // guessing from a table of our own. That keeps Dokku in step with the panel menu:
    // Settings entries stay together, "Utility" no longer swallows editors that also say
    // "Development", and the folder names come from the menu's .directory files.
    //
    // Only the parts of the menu specification that these menus use are supported:
    // Menu, Name, Directory, Include, Exclude, And, Or, Not, Category, Filename, All and
    // OnlyUnallocated. Layout, Move and merge directives are ignored.
    public class MenuCategories : Object {
        private class Rule : Object {
            public string kind;                 // Category, Filename, All, And, Or or Not
            public string text = "";
            public GenericArray<Rule> children = new GenericArray<Rule>();

            public Rule(string kind, string text = "") {
                this.kind = kind;
                this.text = text;
            }

            public bool matches(string[] categories, string filename) {
                switch (kind) {
                    case "All":
                        return true;
                    case "Category":
                        return text in categories;
                    case "Filename":
                        return text == filename;
                    case "And":
                        for (int i = 0; i < children.length; i++) {
                            if (!children[i].matches(categories, filename)) return false;
                        }
                        return true;
                    default: // Or, Not (whose children are OR-ed, then negated)
                        bool any = false;
                        for (int i = 0; i < children.length; i++) {
                            if (children[i].matches(categories, filename)) {
                                any = true;
                                break;
                            }
                        }
                        return kind == "Not" ? !any : any;
                }
            }
        }

        private class Node : Object {
            public string name = "";
            public string directory = "";
            public string title = "";
            public Rule? include = null;
            public Rule? exclude = null;
            public bool only_unallocated = false;
            public GenericArray<Node> children = new GenericArray<Node>();

            public bool contains(string[] categories, string filename, bool ignore_exclude) {
                if (include != null && include.matches(categories, filename) &&
                    (ignore_exclude || exclude == null || !exclude.matches(categories, filename))) {
                    return true;
                }
                for (int i = 0; i < children.length; i++) {
                    if (children[i].contains(categories, filename, ignore_exclude)) return true;
                }
                return false;
            }
        }

        private Node root;
        private string other_title = "Other";

        // Category names in menu order, with the catch-all last
        public string[] order = {};

        private MenuCategories(Node root) {
            this.root = root;
        }

        public static MenuCategories? load() {
            string? path = find_menu_file();
            if (path == null) return null;

            string xml;
            try {
                FileUtils.get_contents(path, out xml);
            } catch (Error e) {
                warning("Failed to read %s: %s", path, e.message);
                return null;
            }

            var menu_root = parse(xml);
            // Anything with only a couple of submenus isn't a menu we understand
            if (menu_root == null || menu_root.children.length < 3) return null;

            var categories = new MenuCategories(menu_root);
            categories.prepare();
            return categories;
        }

        private static string? find_menu_file() {
            string[] names = {};
            string? prefix = Environment.get_variable("XDG_MENU_PREFIX");
            if (prefix != null && prefix != "") names += prefix + "applications.menu";
            names += "xfce-applications.menu";
            names += "applications.menu";

            string[] dirs = { Environment.get_user_config_dir() };
            foreach (var dir in Environment.get_system_config_dirs()) {
                dirs += dir;
            }
            foreach (var dir in dirs) {
                foreach (var name in names) {
                    string path = Path.build_filename(dir, "menus", name);
                    if (FileUtils.test(path, FileTest.IS_REGULAR)) return path;
                }
            }
            return null;
        }

        private static Node? parse(string source) {
            try {
                // Comments, the XML declaration and the DOCTYPE carry nothing we need
                var junk = new Regex("<!--.*?-->|<\\?.*?\\?>|<!DOCTYPE[^>]*>",
                                     RegexCompileFlags.DOTALL | RegexCompileFlags.UNGREEDY);
                string xml = junk.replace(source, -1, 0, "");
                var tag = new Regex("<(/?)([A-Za-z]+)([^>]*?)(/?)>");

                var menus = new GenericArray<Node>();
                var rules = new GenericArray<Rule>();
                Node? root = null;
                int skipped = 0;   // depth inside Layout, Move and similar: not ours to read
                int prev_end = 0;

                MatchInfo m;
                tag.match(xml, 0, out m);
                while (m.matches()) {
                    int start, end;
                    m.fetch_pos(0, out start, out end);
                    string text = xml.substring(prev_end, start - prev_end).strip();
                    prev_end = end;

                    bool closing = m.fetch(1) == "/";
                    string name = m.fetch(2);
                    bool self_closing = m.fetch(4) == "/";
                    Node? current = menus.length > 0 ? menus[menus.length - 1] : null;

                    if (name == "Layout" || name == "DefaultLayout" || name == "Move" || name == "Deleted") {
                        if (closing) skipped--;
                        else if (!self_closing) skipped++;
                    } else if (skipped == 0 && !closing) {
                        switch (name) {
                            case "Menu":
                                var node = new Node();
                                if (current != null) current.children.add(node);
                                else root = node;
                                menus.add(node);
                                break;
                            case "Include":
                            case "Exclude":
                                if (current != null) {
                                    Rule container;
                                    if (name == "Include") {
                                        if (current.include == null) current.include = new Rule("Or");
                                        container = current.include;
                                    } else {
                                        if (current.exclude == null) current.exclude = new Rule("Or");
                                        container = current.exclude;
                                    }
                                    rules.add(container);
                                }
                                break;
                            case "And":
                            case "Or":
                            case "Not":
                                if (rules.length > 0) {
                                    var rule = new Rule(name);
                                    rules[rules.length - 1].children.add(rule);
                                    rules.add(rule);
                                }
                                break;
                            case "All":
                                if (rules.length > 0) rules[rules.length - 1].children.add(new Rule("All"));
                                break;
                            case "OnlyUnallocated":
                                if (current != null) current.only_unallocated = true;
                                break;
                        }
                    } else if (skipped == 0 && closing) {
                        switch (name) {
                            case "Menu":
                                if (menus.length > 0) menus.remove_index(menus.length - 1);
                                break;
                            case "Include":
                            case "Exclude":
                            case "And":
                            case "Or":
                            case "Not":
                                if (rules.length > 0) rules.remove_index(rules.length - 1);
                                break;
                            case "Name":
                                if (current != null && rules.length == 0) current.name = text;
                                break;
                            case "Directory":
                                if (current != null) current.directory = text;
                                break;
                            case "Category":
                            case "Filename":
                                if (rules.length > 0) rules[rules.length - 1].children.add(new Rule(name, text));
                                break;
                        }
                    }
                    m.next();
                }
                return root;
            } catch (Error e) {
                warning("Failed to parse the application menu: %s", e.message);
                return null;
            }
        }

        private void prepare() {
            string[] titles = {};
            for (int i = 0; i < root.children.length; i++) {
                var node = root.children[i];
                node.title = title_for(node);
                if (node.only_unallocated) other_title = node.title;
                else titles += node.title;
            }
            titles += other_title;
            order = titles;
        }

        // The menu's .directory file has the localized name; the menu's own <Name> is the fallback
        private static string title_for(Node node) {
            if (node.directory != "") {
                string[] dirs = { Environment.get_user_data_dir() };
                foreach (var dir in Environment.get_system_data_dirs()) {
                    dirs += dir;
                }
                foreach (var dir in dirs) {
                    string path = Path.build_filename(dir, "desktop-directories", node.directory);
                    if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                    try {
                        var keyfile = new KeyFile();
                        keyfile.load_from_file(path, KeyFileFlags.NONE);
                        return keyfile.get_locale_string("Desktop Entry", "Name");
                    } catch (Error e) {
                        // Try the next directory
                    }
                }
            }
            return node.name;
        }

        // Settings entries belong with Settings even when they also claim another category,
        // and the generic Accessories ("Utility") is the last resort.
        private static int rank(Node node) {
            if (node.name == "Settings") return 0;
            if (node.name == "Accessories") return 2;
            return 1;
        }

        // Sets the app's category from the menu, and whether the menu lists it at the top
        // level (Terminal, File Manager, ...), which the launcher keeps out of folders.
        public void apply(AppInfo app) {
            string filename = Path.get_basename(app.desktop_file);
            string[] cats = app.categories;

            app.toplevel = root.include != null && root.include.matches(cats, filename) &&
                           (root.exclude == null || !root.exclude.matches(cats, filename));

            Node? best = null;
            for (int i = 0; i < root.children.length; i++) {
                var node = root.children[i];
                if (node.only_unallocated) continue;
                // Top-level entries are excluded from their normal menu; still file them there
                if (!node.contains(cats, filename, app.toplevel)) continue;
                if (best == null || rank(node) < rank(best)) best = node;
            }
            app.display_category = best != null ? best.title : other_title;
            app.groupable = !app.toplevel && best != null;
        }
    }
}
