namespace Dokku {
    public class LauncherWindow : Gtk.Window {
        private AppManager app_manager;
        private ConfigManager config;
        private UsageTracker usage_tracker;
        private Gtk.SearchEntry search_entry;
        private Gtk.Stack page_stack;
        private Gtk.Box page_indicator;
        private Gtk.Box category_bar;
        private string active_category = "All";
        private List<weak AppInfo> filtered_apps;
        private List<string> ordered_items;
        // Apps currently collected into each category group, by category name
        private HashTable<string, GenericArray<weak AppInfo>> category_groups =
            new HashTable<string, GenericArray<weak AppInfo>>(str_hash, str_equal);
        // Search relevance per app id for the current query (empty when not searching)
        private HashTable<string, int> match_scores = new HashTable<string, int>(str_hash, str_equal);
        private int cols = 7;
        private int rows = 5;
        private int current_page = 0;
        private int total_pages = 1;
        private Gtk.Popover? folder_popover = null;
        private string? newly_created_folder_id = null;
        private string? dragging_app_id = null;
        private Gtk.Widget? folder_preview_target = null;
        private uint folder_preview_timeout_id = 0;

        private int icon_size = 64;
        private int item_size = 100;
        private int grid_spacing = 25;

        // Smooth scroll accumulation for touchpad gestures
        private double scroll_accumulator_x = 0.0;
        private double scroll_accumulator_y = 0.0;
        private int64 last_scroll_event_us = 0;
        // Set after a flip: the rest of that gesture (inertia included) is ignored
        private bool scroll_gesture_consumed = false;
        private int64 wheel_locked_until_us = 0;
        private const double SCROLL_THRESHOLD = 1.5;
        // A pause this long between scroll events means a new gesture started
        private const int64 SCROLL_GESTURE_GAP_US = 150000;
        // Wheel notches arriving faster than this don't each flip a page
        private const int64 WHEEL_LOCKOUT_US = 300000;

        private HashTable<string, Gdk.Pixbuf?> icon_cache;
        private Queue<string> icon_cache_order;
        private const int MAX_ICON_CACHE_SIZE = 512;
        // The most-used apps are also kept in the grid, outside their folder
        private const int TOP_USED_APPS = 10;
        // A category needs at least this many apps to become a folder
        private const int GROUP_MIN_APPS = 3;
        private static bool css_applied = false;

        // Rows under the search box for calculations, recent files and web search
        private Gtk.Box quick_box;
        private const int QUICK_RECENT_MAX = 3;

        // Fade animation (frame-clock driven)
        private uint fade_tick_id = 0;
        private bool fading_out = false;
        private const int FADE_DURATION_MS = 220;
        private bool pages_dirty = true;
        private bool has_shown_once = false;
        private uint rebuild_idle_id = 0;

        // DOKKU_TIMING=1 logs how long each step of an open takes
        private static bool timing = Environment.get_variable("DOKKU_TIMING") == "1";
        private int64 timing_t0 = 0;
        private bool timing_wait_draw = false;

        private void timing_log(string what) {
            if (!timing || timing_t0 == 0) return;
            message("launcher timing: %s at +%.1f ms", what,
                (GLib.get_monotonic_time() - timing_t0) / 1000.0);
        }

        // Collects the frame-clock interval of every fade frame, printed as one line
        private string trace_buf = "";
        private int64 trace_last_frame_us = 0;

        private void trace_frame(string what, Gdk.FrameClock clock) {
            int64 ft = clock.get_frame_time();
            if (trace_last_frame_us != 0) {
                trace_buf += " %.1f".printf((ft - trace_last_frame_us) / 1000.0);
            } else {
                trace_buf = "";
            }
            trace_last_frame_us = ft;
        }

        private void trace_flush(string what) {
            message("launcher timing: %s frame intervals (ms):%s", what, trace_buf);
            trace_buf = "";
            trace_last_frame_us = 0;
        }

        public signal void pin_to_dock_requested(string app_id, string desktop_file);

        public LauncherWindow(AppManager app_manager, ConfigManager config, UsageTracker usage_tracker) {
            Object(
                type: Gtk.WindowType.TOPLEVEL,
                decorated: false,
                skip_taskbar_hint: true,
                skip_pager_hint: true
            );

            this.app_manager = app_manager;
            this.config = config;
            this.usage_tracker = usage_tracker;
            filtered_apps = new List<weak AppInfo>();
            ordered_items = new List<string>();
            icon_cache = new HashTable<string, Gdk.Pixbuf?>(str_hash, str_equal);
            icon_cache_order = new Queue<string>();

            if (timing) {
                map_event.connect_after(() => { timing_log("map-event"); return false; });
                draw.connect_after(() => {
                    if (timing_wait_draw) {
                        timing_wait_draw = false;
                        timing_log("first draw done (opacity %.2f)".printf(fade_level));
                    }
                    return false;
                });
            }
            // Tag the window so compositor rules for Dokku windows (no shadow,
            // no blur) apply to it
            realize.connect_after(() => CompositorHints.apply(get_window(), false));
            set_app_paintable(true);
            var visual = get_screen().get_rgba_visual();
            if (visual != null) set_visual(visual);

            fullscreen();
            set_keep_above(true);

            add_events(Gdk.EventMask.KEY_PRESS_MASK | Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.SCROLL_MASK);
            key_press_event.connect(on_key_press);
            button_press_event.connect(on_bg_click);
            scroll_event.connect(on_scroll);
            draw.connect(on_draw);

            calculate_scale();
            build_ui();

            // Pre-build pages in idle so they're ready before the user opens
            schedule_rebuild();
        }

        private void calculate_scale() {
            var display = Gdk.Display.get_default();
            var monitor = display.get_primary_monitor() ?? display.get_monitor(0);
            var geom = monitor.get_geometry();
            int height = geom.height;

            // Scale based on vertical resolution (1080p as baseline)
            double scale = height / 1080.0;
            scale = double.max(1.0, scale);  // Never go below 1x

            icon_size = (int)(64 * scale);
            item_size = (int)(100 * scale);
            grid_spacing = (int)(25 * scale);

        }

        private void build_ui() {
            var main_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 15);
            main_box.halign = Gtk.Align.FILL;
            main_box.valign = Gtk.Align.FILL;
            main_box.margin_top = 90;
            main_box.margin_bottom = 80;
            main_box.margin_start = 40;
            main_box.margin_end = 40;

            // Search bar
            var search_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            search_box.halign = Gtk.Align.CENTER;
            search_entry = new Gtk.SearchEntry();
            search_entry.placeholder_text = "Search";
            search_entry.width_request = 220;
            search_entry.get_style_context().add_class("launcher-search");
            search_entry.search_changed.connect(on_search_changed);
            search_box.pack_start(search_entry, false, false, 0);

            var add_shortcut_btn = new Gtk.Button.from_icon_name("list-add-symbolic", Gtk.IconSize.BUTTON);
            add_shortcut_btn.get_style_context().add_class("category-btn");
            add_shortcut_btn.tooltip_text = "Create Shortcut";
            add_shortcut_btn.clicked.connect(() => show_shortcut_dialog(null));
            search_box.pack_start(add_shortcut_btn, false, false, 8);

            main_box.pack_start(search_box, false, false, 0);

            // Category filter bar
            category_bar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
            category_bar.halign = Gtk.Align.CENTER;
            category_bar.margin_top = 8;
            build_category_buttons();
            main_box.pack_start(category_bar, false, false, 0);

            quick_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
            quick_box.halign = Gtk.Align.CENTER;
            quick_box.no_show_all = true;
            quick_box.visible = false;
            main_box.pack_start(quick_box, false, false, 0);

            // Page stack (horizontal slide transitions)
            page_stack = new Gtk.Stack();
            page_stack.transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
            page_stack.transition_duration = 300;
            page_stack.halign = Gtk.Align.CENTER;
            page_stack.valign = Gtk.Align.CENTER;
            page_stack.vexpand = true;
            page_stack.hexpand = true;
            main_box.pack_start(page_stack, true, true, 0);

            // Page indicator dots
            page_indicator = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            page_indicator.halign = Gtk.Align.CENTER;
            page_indicator.margin_top = 20;
            main_box.pack_start(page_indicator, false, false, 0);

            add(main_box);

            apply_css();
        }

        private void apply_css() {
            if (css_applied) return;
            css_applied = true;
            var css = new Gtk.CssProvider();
            try {
                css.load_from_data("""
                    .launcher-search {
                        font-size: 13px;
                        padding: 6px 14px;
                        border-radius: 8px;
                        background: rgba(255,255,255,0.08);
                        border: 1px solid rgba(255,255,255,0.12);
                        color: white;
                        caret-color: white;
                    }
                    .launcher-search image {
                        color: white;
                        -gtk-icon-style: symbolic;
                    }
                    .launcher-search:focus {
                        background: rgba(255,255,255,0.14);
                        border: 1px solid rgba(255,255,255,0.20);
                        color: white;
                    }
                    .quick-row {
                        padding: 8px 14px;
                        border-radius: 10px;
                        background: rgba(255,255,255,0.07);
                        border: 1px solid rgba(255,255,255,0.10);
                        box-shadow: none;
                        color: white;
                    }
                    .quick-row:hover, .quick-row:focus {
                        background: rgba(255,255,255,0.16);
                    }
                    .quick-row label { color: white; }
                    .quick-row .quick-secondary { color: rgba(255,255,255,0.55); font-size: 11px; }
                    .app-item {
                        padding: 10px;
                        border-radius: 14px;
                        background: transparent;
                        outline: none;
                        outline-width: 0;
                        -gtk-outline-radius: 0;
                        box-shadow: none;
                        border: none;
                    }
                    .app-item:hover {
                        background: rgba(255,255,255,0.08);
                        outline: none;
                        border: none;
                    }
                    .app-item:focus {
                        outline: none;
                        outline-width: 0;
                        -gtk-outline-radius: 0;
                        box-shadow: none;
                        border: none;
                        background: rgba(255,255,255,0.16);
                    }
                    .app-item:active {
                        outline: none;
                        border: none;
                        background: rgba(255,255,255,0.12);
                    }
                    .app-item:checked {
                        outline: none;
                        border: none;
                        background: rgba(255,255,255,0.10);
                    }
                    .app-item:selected {
                        outline: none;
                        border: none;
                        background: rgba(255,255,255,0.2);
                    }
                    .app-name {
                        color: white;
                        font-size: 11px;
                    }
                    .page-dot {
                        min-width: 8px;
                        min-height: 8px;
                        padding: 0;
                        border-radius: 4px;
                        background: rgba(255,255,255,0.3);
                        border: none;
                        outline: none;
                    }
                    .page-dot:hover {
                        background: rgba(255,255,255,0.5);
                    }
                    .page-dot.active {
                        background: rgba(255,255,255,0.8);
                    }
                    .folder-icon {
                        background: rgba(160, 165, 180, 0.35);
                        border-radius: 16px;
                        border: none;
                        outline: none;
                        padding: 6px;
                    }
                    .folder-forming {
                        background: rgba(170, 175, 190, 0.45);
                        border-radius: 16px;
                        border: none;
                        outline: none;
                    }
                    .folder-title {
                        font-size: 14px;
                        font-weight: bold;
                        color: white;
                        background: transparent;
                    }
                    .folder-popover {
                        background: rgba(40, 40, 40, 0.95);
                        border: 1px solid rgba(255,255,255,0.15);
                    }
                    .folder-popover * {
                        color: white;
                    }
                    .category-btn {
                        font-size: 11px;
                        padding: 3px 10px;
                        border-radius: 12px;
                        background: rgba(255,255,255,0.06);
                        border: 1px solid rgba(255,255,255,0.08);
                        color: rgba(255,255,255,0.65);
                        min-height: 0;
                        outline: none;
                    }
                    .category-btn:hover {
                        background: rgba(255,255,255,0.12);
                        color: white;
                    }
                    .category-active {
                        background: rgba(255,255,255,0.18);
                        border: 1px solid rgba(255,255,255,0.25);
                        color: white;
                    }
                """);
                Gtk.StyleContext.add_provider_for_screen(
                    get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
                );
            } catch (Error e) {}
        }

        private void build_category_buttons() {
            category_bar.foreach((w) => category_bar.remove(w));

            var all_btn = create_category_button("All");
            category_bar.pack_start(all_btn, false, false, 0);

            foreach (var cat in app_manager.get_populated_categories()) {
                var btn = create_category_button(cat);
                category_bar.pack_start(btn, false, false, 0);
            }
            category_bar.show_all();
        }

        private Gtk.Button create_category_button(string label) {
            var btn = new Gtk.Button.with_label(label);
            btn.get_style_context().add_class("category-btn");
            if (label == active_category) {
                btn.get_style_context().add_class("category-active");
            }
            btn.clicked.connect(() => {
                active_category = label;
                build_category_buttons();
                on_search_changed();
            });
            return btn;
        }

        private Gdk.Pixbuf? load_cached_icon(string icon_name, int size) {
            string key = "%s_%d".printf(icon_name, size);
            if (icon_cache.contains(key)) {
                return icon_cache.get(key);
            }

            // Evict oldest 25% of cache if it exceeds the limit
            if (icon_cache.size() >= MAX_ICON_CACHE_SIZE) {
                int to_remove = MAX_ICON_CACHE_SIZE / 4;
                for (int i = 0; i < to_remove && !icon_cache_order.is_empty(); i++) {
                    string old_key = icon_cache_order.pop_head();
                    icon_cache.remove(old_key);
                }
            }

            Gdk.Pixbuf? pixbuf = IconLoader.load(icon_name, size);
            icon_cache.set(key, pixbuf);
            icon_cache_order.push_tail(key);
            return pixbuf;
        }

        private bool on_draw(Cairo.Context cr) {
            int height = get_allocated_height();

            // Vertical gradient: slightly darker at top for the search area
            var gradient = new Cairo.Pattern.linear(0, 0, 0, height);
            gradient.add_color_stop_rgba(0, 0.05, 0.05, 0.08, 0.92);
            gradient.add_color_stop_rgba(1, 0.12, 0.10, 0.12, 0.88);
            cr.set_source(gradient);
            cr.paint();
            return false;
        }

        // How well an app matches the query: 0 when there is no query, -1 for no match.
        // Name matches beat id/command matches, and earlier-in-name beats later.
        private static int match_score(AppInfo app, string query) {
            if (query == "") return 0;
            string name = app.name_lower;
            if (name == query) return 100;
            if (name.has_prefix(query)) return 80;
            if (name.contains(" " + query) || name.contains("-" + query)) return 60;
            if (name.contains(query)) return 40;
            if (app.id_lower.has_prefix(query) || app.exec_base.has_prefix(query)) return 30;
            if (app.id_lower.contains(query) || app.exec_base.contains(query)) return 20;
            return -1;
        }

        private void on_search_changed() {
            string query = search_entry.text.strip().down();
            filtered_apps = new List<weak AppInfo>();
            match_scores.remove_all();

            foreach (var app in app_manager.get_all_apps()) {
                if (app.redundant || config.is_app_hidden(app.id)) continue;
                if (config.get_app_folder(app.id) != null) continue;

                // Category filter
                if (active_category != "All" && app.display_category != active_category) continue;

                int score = match_score(app, query);
                if (score >= 0) {
                    filtered_apps.append(app);
                    match_scores.set(app.id, score);
                }
            }
            current_page = 0;
            rebuild_pages();
            update_quick_results();
        }

        private void clear_quick_results() {
            quick_box.foreach((w) => quick_box.remove(w));
            quick_box.visible = false;
        }

        private Gtk.Button make_quick_row(Gtk.Widget icon, string primary, string secondary) {
            var btn = new Gtk.Button();
            btn.relief = Gtk.ReliefStyle.NONE;
            btn.get_style_context().add_class("quick-row");
            btn.width_request = 480;
            var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
            box.pack_start(icon, false, false, 0);
            var texts = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            var first = new Gtk.Label(primary);
            first.halign = Gtk.Align.START;
            first.xalign = 0;
            first.ellipsize = Pango.EllipsizeMode.END;
            texts.pack_start(first, false, false, 0);
            if (secondary != "") {
                var second = new Gtk.Label(secondary);
                second.halign = Gtk.Align.START;
                second.xalign = 0;
                second.ellipsize = Pango.EllipsizeMode.MIDDLE;
                second.get_style_context().add_class("quick-secondary");
                texts.pack_start(second, false, false, 0);
            }
            box.pack_start(texts, true, true, 0);
            btn.add(box);
            return btn;
        }

        // A calculation, matching recent files, or a web search, shown above the grid
        private void update_quick_results() {
            clear_quick_results();
            string text = search_entry.text.strip();
            if (text == "") return;

            double value;
            bool is_calc = QuickMath.evaluate(text, out value);
            if (is_calc) {
                string result = QuickMath.format(value);
                var row = make_quick_row(
                    new Gtk.Image.from_icon_name("accessories-calculator-symbolic", Gtk.IconSize.LARGE_TOOLBAR),
                    "= " + result, "Press Enter to copy the result");
                row.clicked.connect(() => {
                    var clipboard = Gtk.Clipboard.get_default(get_display());
                    clipboard.set_text(result, -1);
                    clipboard.store();
                    fade_hide();
                });
                quick_box.pack_start(row, false, false, 0);
            }

            if (text.length >= 2 && !is_calc) {
                foreach (var info in find_recent_files(text)) {
                    string uri = info.get_uri();
                    string folder = "";
                    try {
                        folder = Path.get_dirname(Filename.from_uri(uri)).replace(Environment.get_home_dir(), "~");
                    } catch (Error e) {}
                    var gicon = info.get_gicon();
                    Gtk.Widget icon = gicon != null
                        ? (Gtk.Widget) new Gtk.Image.from_gicon(gicon, Gtk.IconSize.LARGE_TOOLBAR)
                        : (Gtk.Widget) new Gtk.Image.from_icon_name("text-x-generic", Gtk.IconSize.LARGE_TOOLBAR);
                    var row = make_quick_row(icon, TextUtil.sanitize(info.get_display_name()), folder);
                    row.clicked.connect(() => {
                        try {
                            Gtk.show_uri_on_window(this, uri, Gdk.CURRENT_TIME);
                        } catch (Error e) {
                            warning("Failed to open %s: %s", uri, e.message);
                        }
                        fade_hide();
                    });
                    quick_box.pack_start(row, false, false, 0);
                }
            }

            // Only when nothing in the grid matches: the words may be for a browser
            if (!is_calc && ordered_items.length() == 0) {
                string? web = QuickResults.web_search_uri(config.get_web_search_url(), text);
                if (web != null) {
                    var row = make_quick_row(
                        new Gtk.Image.from_icon_name("system-search-symbolic", Gtk.IconSize.LARGE_TOOLBAR),
                        "Search the web for “%s”".printf(TextUtil.sanitize(text)),
                        "Press Enter to open your browser");
                    row.clicked.connect(() => {
                        try {
                            Gtk.show_uri_on_window(this, web, Gdk.CURRENT_TIME);
                        } catch (Error e) {
                            warning("Failed to open the browser: %s", e.message);
                        }
                        fade_hide();
                    });
                    quick_box.pack_start(row, false, false, 0);
                }
            }

            if (quick_box.get_children() != null) {
                // no_show_all keeps show_all() out of the box, so show the rows themselves
                quick_box.foreach((row) => row.show_all());
                quick_box.show();
            }
        }

        // Recent files whose names match every word typed, newest first
        private List<Gtk.RecentInfo> find_recent_files(string text) {
            var matches = new List<Gtk.RecentInfo>();
            foreach (var info in Gtk.RecentManager.get_default().get_items()) {
                if (!info.is_local()) continue;
                if (!QuickResults.name_matches(info.get_display_name(), text)) continue;
                matches.append(info);
            }
            matches.sort((a, b) => {
                long at = (long) a.get_modified();
                long bt = (long) b.get_modified();
                return at > bt ? -1 : (at < bt ? 1 : 0);
            });
            // The files can be gone; check only the few that would be shown
            var shown = new List<Gtk.RecentInfo>();
            foreach (var info in matches) {
                if (!info.exists()) continue;
                shown.append(info);
                if (shown.length() >= QUICK_RECENT_MAX) break;
            }
            return shown;
        }

        // Full rebuild of all pages (no animation — used on search/init)
        private void rebuild_pages() {
            // Remove all existing pages
            page_stack.foreach((w) => page_stack.remove(w));

            // Best match first, then by usage count (descending), then alphabetically
            var sort_arr = new GenericArray<unowned AppInfo>();
            foreach (var app in filtered_apps) {
                sort_arr.add(app);
            }
            sort_arr.sort_with_data((a, b) => {
                int score_a = match_scores.contains(a.id) ? match_scores.get(a.id) : 0;
                int score_b = match_scores.contains(b.id) ? match_scores.get(b.id) : 0;
                if (score_a != score_b) return score_b - score_a;
                int usage_a = usage_tracker.get_count(a.id);
                int usage_b = usage_tracker.get_count(b.id);
                if (usage_a != usage_b) return usage_b - usage_a;
                return strcmp(a.name, b.name);
            });
            filtered_apps = new List<weak AppInfo>();
            for (int si = 0; si < sort_arr.length; si++) {
                filtered_apps.append(sort_arr[si]);
            }

            string query = search_entry.text.down();

            // Collect items: folders + shortcuts + apps
            var items = new List<string>();
            if (search_entry.text == "") {
                foreach (var folder_id in config.get_folder_ids()) {
                    items.append("folder:" + folder_id);
                }
            }
            // Custom shortcuts (only in "All" category)
            if (active_category == "All") {
                foreach (var sid in config.get_shortcut_ids()) {
                    string sname = config.get_shortcut_name(sid);
                    if (query == "" || sname.down().contains(query)) {
                        items.append("shortcut:" + sid);
                    }
                }
            }
            // In the plain All view, each category with enough apps gets a folder holding all
            // of them. The most-used apps also stay in the grid, so they remain one click away.
            category_groups.remove_all();
            var top_used = new HashTable<string, bool>(str_hash, str_equal);
            if (active_category == "All" && query == "" && config.get_group_apps()) {
                int taken = 0;
                foreach (var app in filtered_apps) {   // already sorted by usage
                    if (taken >= TOP_USED_APPS || usage_tracker.get_count(app.id) <= 0) break;
                    top_used.set(app.id, true);
                    taken++;
                }
                var by_category = new HashTable<string, GenericArray<weak AppInfo>>(str_hash, str_equal);
                foreach (var app in filtered_apps) {
                    // The catch-all category and the menu's top-level entries stay loose
                    if (!app.groupable) continue;
                    if (!by_category.contains(app.display_category)) {
                        by_category.set(app.display_category, new GenericArray<weak AppInfo>());
                    }
                    by_category.get(app.display_category).add(app);
                }
                by_category.foreach((category, members) => {
                    if (members.length >= GROUP_MIN_APPS) category_groups.set(category, members);
                });
            }
            var placed = new HashTable<string, bool>(str_hash, str_equal);
            foreach (var app in filtered_apps) {
                string category = app.display_category;
                if (category_groups.contains(category) && is_in_group(category_groups, app)) {
                    // The folder sits where its first app that isn't already in the grid would be
                    if (top_used.contains(app.id)) {
                        items.append("app:" + app.id);
                    } else if (!placed.contains(category)) {
                        items.append("group:" + category);
                        placed.set(category, true);
                    }
                    continue;
                }
                items.append("app:" + app.id);
            }
            // A folder whose apps are all in the grid already still needs its tile
            category_groups.foreach((category, members) => {
                if (!placed.contains(category)) items.append("group:" + category);
            });

            // Store ordered items for Enter-key launch
            ordered_items = new List<string>();
            foreach (var item in items) {
                ordered_items.append(item);
            }

            int items_per_page = cols * rows;
            total_pages = (int)((items.length() + items_per_page - 1) / items_per_page);
            if (total_pages < 1) total_pages = 1;
            if (current_page >= total_pages) current_page = total_pages - 1;
            if (current_page < 0) current_page = 0;

            // Build a Gtk.Grid for each page
            for (int p = 0; p < total_pages; p++) {
                var grid = new Gtk.Grid();
                grid.row_spacing = grid_spacing;
                grid.column_spacing = grid_spacing;
                grid.halign = Gtk.Align.CENTER;
                grid.valign = Gtk.Align.CENTER;

                int start = p * items_per_page;
                int idx = 0;

                foreach (var item in items) {
                    if (idx < start) { idx++; continue; }
                    if (idx >= start + items_per_page) break;

                    int pos = idx - start;
                    int col = pos % cols;
                    int row = pos / cols;

                    Gtk.Widget widget;
                    if (item.has_prefix("folder:")) {
                        widget = create_folder_item(item.substring(7));
                    } else if (item.has_prefix("shortcut:")) {
                        widget = create_shortcut_item(item.substring(9));
                    } else if (item.has_prefix("group:")) {
                        string category = item.substring(6);
                        widget = create_group_item(category, category_groups.get(category));
                    } else {
                        var app = app_manager.get_app(item.substring(4));
                        if (app != null) {
                            widget = create_app_item(app);
                        } else {
                            idx++;
                            continue;
                        }
                    }
                    grid.attach(widget, col, row, 1, 1);
                    idx++;
                }

                page_stack.add_named(grid, "page_%d".printf(p));
            }

            page_stack.show_all();

            // Show current page without animation
            page_stack.set_visible_child_full("page_%d".printf(current_page),
                                              Gtk.StackTransitionType.NONE);
            update_page_indicator();
            pages_dirty = false;
        }

        // Animated page switch
        private void go_to_page(int page) {
            if (page < 0 || page >= total_pages || page == current_page) return;
            current_page = page;
            page_stack.set_visible_child_name("page_%d".printf(current_page));
            update_page_indicator();
        }

        private void update_page_indicator() {
            // Rebuilding the dots mid-slide forces a layout pass, so only do it when the
            // number of pages changed; otherwise just move the active highlight.
            var dots = page_indicator.get_children();
            if (dots.length() != total_pages) {
                dots.foreach((w) => page_indicator.remove(w));
                for (int i = 0; i < total_pages; i++) {
                    var dot = new Gtk.Button();
                    dot.set_size_request(8, 8);
                    dot.get_style_context().add_class("page-dot");
                    int page = i;
                    dot.clicked.connect(() => {
                        go_to_page(page);
                    });
                    page_indicator.pack_start(dot, false, false, 0);
                }
                page_indicator.show_all();
                dots = page_indicator.get_children();
            }

            int index = 0;
            foreach (var dot in dots) {
                var ctx = dot.get_style_context();
                if (index == current_page) ctx.add_class("active");
                else ctx.remove_class("active");
                index++;
            }
        }

        private bool is_app_pinned(AppInfo app) {
            foreach (var pinned in config.get_pinned_apps()) {
                if (pinned == app.id || pinned == app.desktop_file) return true;
            }
            return false;
        }

        private Gtk.Widget create_app_item(AppInfo app) {
            var btn = new Gtk.Button();
            btn.relief = Gtk.ReliefStyle.NONE;
            btn.get_style_context().add_class("app-item");

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
            box.set_data("app-id", app.id);

            var icon = new Gtk.Image();
            var pixbuf = load_cached_icon(app.icon, icon_size);
            if (pixbuf != null) icon.set_from_pixbuf(pixbuf);
            else icon.set_from_icon_name("application-x-executable", Gtk.IconSize.DIALOG);

            var label = new Gtk.Label(app.name);
            label.get_style_context().add_class("app-name");
            label.max_width_chars = 12;
            label.ellipsize = Pango.EllipsizeMode.END;

            box.pack_start(icon, false, false, 0);
            box.pack_start(label, false, false, 0);

            btn.add(box);
            btn.set_size_request(item_size, item_size);

            // Left click - launch
            btn.clicked.connect(() => {
                usage_tracker.record_launch(app.id);
                app.launch();
                fade_hide();
            });

            // Right click - context menu
            btn.button_press_event.connect((event) => {
                if (event.button == 3) {
                    show_app_menu(app, btn, event);
                    return true;
                }
                return false;
            });
            // Menu key / Shift+F10
            btn.popup_menu.connect(() => {
                show_app_menu(app, btn, null);
                return true;
            });

            // Drag source - supports text (internal folders) + URI (dock drops)
            Gtk.drag_source_set(btn, Gdk.ModifierType.BUTTON1_MASK, {}, Gdk.DragAction.MOVE | Gdk.DragAction.COPY);
            Gtk.drag_source_add_text_targets(btn);
            if (app.desktop_file != null && app.desktop_file != "") {
                Gtk.drag_source_add_uri_targets(btn);
            }

            // Show the app icon while dragging
            if (pixbuf != null) {
                Gtk.drag_source_set_icon_pixbuf(btn, pixbuf);
            }

            btn.drag_data_get.connect((ctx, data, info, time) => {
                var target = data.get_target();
                if (target == Gdk.Atom.intern("text/uri-list", false) && app.desktop_file != null) {
                    data.set_uris({"file://" + app.desktop_file});
                } else {
                    data.set_text("app:" + app.id, -1);
                }
            });
            // Track which app is being dragged (for folder preview self-detection)
            btn.drag_begin.connect((ctx) => { dragging_app_id = app.id; });
            btn.drag_end.connect((ctx) => {
                dragging_app_id = null;
                cancel_folder_preview();
            });

            // Drop target (to create folder)
            Gtk.drag_dest_set(btn, Gtk.DestDefaults.DROP, {}, Gdk.DragAction.MOVE);
            Gtk.drag_dest_add_text_targets(btn);

            // Folder preview: show container animation after short hover
            btn.drag_motion.connect((ctx, x, y, time) => {
                Gdk.drag_status(ctx, Gdk.DragAction.MOVE, time);
                // Don't preview when hovering over self
                if (dragging_app_id != null && dragging_app_id == app.id) return true;
                if (folder_preview_target != btn) {
                    cancel_folder_preview();
                    folder_preview_target = btn;
                    folder_preview_timeout_id = Timeout.add(250, () => {
                        folder_preview_timeout_id = 0;
                        show_folder_preview(btn);
                        return false;
                    });
                }
                return true;
            });
            btn.drag_leave.connect((ctx, time) => {
                if (folder_preview_target == btn) {
                    cancel_folder_preview();
                }
            });

            btn.drag_data_received.connect((ctx, x, y, data, info, time) => {
                cancel_folder_preview();
                string? dropped = data.get_text();
                if (dropped != null && dropped.has_prefix("app:")) {
                    string other_id = dropped.substring(4);
                    if (other_id != app.id) {
                        string folder_id = "folder_%s".printf(GLib.get_real_time().to_string());
                        config.create_folder(folder_id, "New Folder", {other_id, app.id});
                        newly_created_folder_id = folder_id;
                        on_search_changed();
                    }
                }
            });

            return btn;
        }

        private void show_app_menu(AppInfo app, Gtk.Widget anchor, Gdk.EventButton? event) {
            var menu = new Gtk.Menu();

            var open_item = new Gtk.MenuItem.with_label("Open");
            open_item.activate.connect(() => {
                usage_tracker.record_launch(app.id);
                app.launch();
                fade_hide();
            });
            menu.append(open_item);

            // The app's own actions from its .desktop file (New Window, Private Window, ...)
            DesktopAppInfo? desktop_info = null;
            if (app.desktop_file != null && app.desktop_file != "") {
                desktop_info = new DesktopAppInfo.from_filename(app.desktop_file);
            }
            if (desktop_info != null && desktop_info.list_actions().length > 0) {
                menu.append(new Gtk.SeparatorMenuItem());
                foreach (var action in desktop_info.list_actions()) {
                    var action_item = new Gtk.MenuItem.with_label(desktop_info.get_action_name(action));
                    string action_name = action;
                    action_item.activate.connect(() => {
                        var display = Gdk.Display.get_default();
                        desktop_info.launch_action(action_name,
                            display != null ? display.get_app_launch_context() : null);
                        usage_tracker.record_launch(app.id);
                        fade_hide();
                    });
                    menu.append(action_item);
                }
            }

            menu.append(new Gtk.SeparatorMenuItem());

            if (!is_app_pinned(app)) {
                var dock_item = new Gtk.MenuItem.with_label("Add to Dock");
                dock_item.activate.connect(() => {
                    pin_to_dock_requested(app.id, app.desktop_file ?? "");
                });
                menu.append(dock_item);
            }

            var hide_item = new Gtk.MenuItem.with_label("Hide from Launcher");
            hide_item.activate.connect(() => {
                // The popover is anchored to a tile that the rebuild below destroys
                if (folder_popover != null) {
                    folder_popover.popdown();
                    folder_popover = null;
                }
                config.hide_app(app.id);
                on_search_changed();
            });
            menu.append(hide_item);

            menu.show_all();
            if (event != null) {
                menu.popup_at_pointer(event);
            } else {
                menu.popup_at_widget(anchor, Gdk.Gravity.SOUTH, Gdk.Gravity.NORTH, null);
            }
        }

        private Gtk.Widget create_folder_item(string folder_id) {
            var btn = new Gtk.Button();
            btn.relief = Gtk.ReliefStyle.NONE;
            btn.get_style_context().add_class("app-item");

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);

            var icon_box = new Gtk.Grid();
            icon_box.row_spacing = 1;
            icon_box.column_spacing = 1;
            icon_box.halign = Gtk.Align.CENTER;
            icon_box.valign = Gtk.Align.CENTER;

            int mini_icon = icon_size / 4;
            var apps = config.get_folder_apps(folder_id);
            int i = 0;
            foreach (var app_id in apps) {
                if (i >= 9) break;
                var app = app_manager.get_app(app_id);
                if (app != null) {
                    var icon = new Gtk.Image();
                    var pixbuf = load_cached_icon(app.icon, mini_icon);
                    if (pixbuf != null) icon.set_from_pixbuf(pixbuf);
                    else icon.set_from_icon_name("application-x-executable", Gtk.IconSize.LARGE_TOOLBAR);
                    icon_box.attach(icon, i % 3, i / 3, 1, 1);
                    i++;
                }
            }

            var folder_frame = new Gtk.EventBox();
            folder_frame.get_style_context().add_class("folder-icon");
            folder_frame.set_size_request(icon_size, icon_size);
            folder_frame.add(icon_box);

            // Pop animation for newly created folders
            if (newly_created_folder_id == folder_id) {
                btn.opacity = 0;
                int64 anim_start = GLib.get_monotonic_time();
                btn.add_tick_callback((widget, clock) => {
                    int64 elapsed = GLib.get_monotonic_time() - anim_start;
                    double t = double.min(1.0, elapsed / 250000.0);
                    btn.opacity = ease_out_cubic(t);
                    if (t >= 1.0) {
                        newly_created_folder_id = null;
                        return false;
                    }
                    return true;
                });
            }

            var label = new Gtk.Label(config.get_folder_name(folder_id));
            label.get_style_context().add_class("app-name");
            label.max_width_chars = 12;
            label.ellipsize = Pango.EllipsizeMode.END;

            box.pack_start(folder_frame, false, false, 0);
            box.pack_start(label, false, false, 0);

            btn.add(box);
            btn.set_size_request(item_size, item_size);

            btn.clicked.connect(() => {
                open_folder(folder_id, btn);
            });

            btn.button_press_event.connect((event) => {
                if (event.button == 3) {
                    show_folder_menu(folder_id, event);
                    return true;
                }
                return false;
            });

            // Drag source for reordering folders
            Gtk.drag_source_set(btn, Gdk.ModifierType.BUTTON1_MASK, {}, Gdk.DragAction.MOVE);
            Gtk.drag_source_add_text_targets(btn);
            btn.drag_data_get.connect((ctx, data, info, time) => {
                data.set_text("folder:" + folder_id, -1);
            });

            // Drop target: accept apps (add to folder) and folders (swap positions)
            Gtk.drag_dest_set(btn, Gtk.DestDefaults.ALL, {}, Gdk.DragAction.MOVE);
            Gtk.drag_dest_add_text_targets(btn);
            btn.drag_data_received.connect((ctx, x, y, data, info, time) => {
                string? dropped = data.get_text();
                if (dropped == null) return;
                if (dropped.has_prefix("app:")) {
                    config.add_app_to_folder(folder_id, dropped.substring(4));
                    on_search_changed();
                } else if (dropped.has_prefix("folder:")) {
                    string other_folder_id = dropped.substring(7);
                    if (other_folder_id != folder_id) {
                        // Move dragged folder to this folder's position
                        var ids = config.get_folder_ids();
                        int target_pos = -1;
                        for (int j = 0; j < ids.length; j++) {
                            if (ids[j] == folder_id) { target_pos = j; break; }
                        }
                        if (target_pos >= 0) {
                            config.move_folder_to_position(other_folder_id, target_pos);
                            on_search_changed();
                        }
                    }
                }
            });

            return btn;
        }

        private void show_folder_menu(string folder_id, Gdk.EventButton event) {
            var menu = new Gtk.Menu();

            var rename_item = new Gtk.MenuItem.with_label("Rename Folder");
            rename_item.activate.connect(() => {
                rename_folder_dialog(folder_id);
            });
            menu.append(rename_item);

            var delete_item = new Gtk.MenuItem.with_label("Delete Folder");
            delete_item.activate.connect(() => {
                config.delete_folder(folder_id);
                on_search_changed();
            });
            menu.append(delete_item);

            menu.show_all();
            menu.popup_at_pointer(event);
        }

        private void rename_folder_dialog(string folder_id) {
            var dialog = new Gtk.Dialog.with_buttons("Rename Folder", this,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                "_Cancel", Gtk.ResponseType.CANCEL,
                "_OK", Gtk.ResponseType.OK);

            var entry = new Gtk.Entry();
            entry.text = config.get_folder_name(folder_id);
            entry.margin = 20;
            entry.activates_default = true;
            dialog.set_default_response(Gtk.ResponseType.OK);
            dialog.get_content_area().add(entry);
            dialog.show_all();

            dialog.response.connect((response) => {
                if (response == Gtk.ResponseType.OK) {
                    config.rename_folder(folder_id, entry.text);
                    on_search_changed();
                }
                dialog.destroy();
            });
        }

        private void open_folder(string folder_id, Gtk.Widget anchor) {
            if (folder_popover != null) {
                folder_popover.popdown();
                folder_popover = null;
            }

            folder_popover = new Gtk.Popover(anchor);
            folder_popover.set_position(Gtk.PositionType.TOP);
            folder_popover.get_style_context().add_class("folder-popover");

            var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
            vbox.margin = 15;

            var name_label = new Gtk.Label(config.get_folder_name(folder_id));
            name_label.halign = Gtk.Align.CENTER;
            name_label.get_style_context().add_class("folder-title");
            vbox.pack_start(name_label, false, false, 0);

            var grid = new Gtk.Grid();
            grid.row_spacing = 10;
            grid.column_spacing = 10;
            grid.halign = Gtk.Align.CENTER;

            var apps = config.get_folder_apps(folder_id);
            int i = 0;
            foreach (var app_id in apps) {
                var app = app_manager.get_app(app_id);
                if (app != null) {
                    var item = create_folder_app_item(app, folder_id);
                    grid.attach(item, i % 4, i / 4, 1, 1);
                    i++;
                }
            }
            vbox.pack_start(grid, true, true, 0);

            folder_popover.add(vbox);
            folder_popover.show_all();

            folder_popover.closed.connect(() => {
                folder_popover = null;
            });
        }

        private Gtk.Widget create_folder_app_item(AppInfo app, string folder_id) {
            var btn = new Gtk.Button();
            btn.relief = Gtk.ReliefStyle.NONE;

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);

            var icon = new Gtk.Image();
            var pixbuf = load_cached_icon(app.icon, 48);
            if (pixbuf != null) icon.set_from_pixbuf(pixbuf);
            else icon.set_from_icon_name("application-x-executable", Gtk.IconSize.DIALOG);

            var label = new Gtk.Label(app.name);
            label.max_width_chars = 8;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.get_style_context().add_class("app-name");

            box.pack_start(icon, false, false, 0);
            box.pack_start(label, false, false, 0);
            btn.add(box);

            btn.clicked.connect(() => {
                usage_tracker.record_launch(app.id);
                app.launch();
                if (folder_popover != null) folder_popover.popdown();
                folder_popover = null;
                fade_hide();
            });

            Gtk.drag_source_set(btn, Gdk.ModifierType.BUTTON1_MASK, {}, Gdk.DragAction.MOVE);
            Gtk.drag_source_add_text_targets(btn);
            btn.drag_data_get.connect((ctx, data, info, time) => {
                data.set_text("folder_app:" + folder_id + ":" + app.id, -1);
            });
            btn.drag_end.connect((ctx) => {
                config.remove_app_from_folder(folder_id, app.id);
                if (config.get_folder_apps(folder_id).length <= 1) {
                    config.delete_folder(folder_id);
                }
                if (folder_popover != null) folder_popover.popdown();
                folder_popover = null;
                on_search_changed();
            });

            btn.button_press_event.connect((event) => {
                if (event.button == 3) {
                    var menu = new Gtk.Menu();
                    var remove = new Gtk.MenuItem.with_label("Remove from Folder");
                    remove.activate.connect(() => {
                        config.remove_app_from_folder(folder_id, app.id);
                        if (config.get_folder_apps(folder_id).length <= 1) {
                            config.delete_folder(folder_id);
                        }
                        if (folder_popover != null) folder_popover.popdown();
                        folder_popover = null;
                        on_search_changed();
                    });
                    menu.append(remove);
                    menu.show_all();
                    menu.popup_at_pointer(event);
                    return true;
                }
                return false;
            });

            return btn;
        }

        private static bool is_in_group(HashTable<string, GenericArray<weak AppInfo>> groups, AppInfo app) {
            var members = groups.get(app.display_category);
            if (members == null) return false;
            for (int i = 0; i < members.length; i++) {
                if (members[i] == app) return true;
            }
            return false;
        }

        // A folder-looking tile that holds a computed set of apps (not stored in the config)
        private Gtk.Widget create_group_item(string title, GenericArray<weak AppInfo> apps) {
            var btn = new Gtk.Button();
            btn.relief = Gtk.ReliefStyle.NONE;
            btn.get_style_context().add_class("app-item");

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);

            var icon_box = new Gtk.Grid();
            icon_box.row_spacing = 1;
            icon_box.column_spacing = 1;
            icon_box.halign = Gtk.Align.CENTER;
            icon_box.valign = Gtk.Align.CENTER;

            int mini_icon = icon_size / 4;
            for (int i = 0; i < apps.length && i < 9; i++) {
                var icon = new Gtk.Image();
                var pixbuf = load_cached_icon(apps[i].icon, mini_icon);
                if (pixbuf != null) icon.set_from_pixbuf(pixbuf);
                else icon.set_from_icon_name("application-x-executable", Gtk.IconSize.LARGE_TOOLBAR);
                icon_box.attach(icon, i % 3, i / 3, 1, 1);
            }

            var folder_frame = new Gtk.EventBox();
            folder_frame.get_style_context().add_class("folder-icon");
            folder_frame.set_size_request(icon_size, icon_size);
            folder_frame.add(icon_box);

            var label = new Gtk.Label(title);
            label.get_style_context().add_class("app-name");
            label.max_width_chars = 12;
            label.ellipsize = Pango.EllipsizeMode.END;

            box.pack_start(folder_frame, false, false, 0);
            box.pack_start(label, false, false, 0);
            btn.add(box);
            btn.set_size_request(item_size, item_size);

            btn.clicked.connect(() => open_group(title, apps, btn));
            return btn;
        }

        private void open_group(string title, GenericArray<weak AppInfo> apps, Gtk.Widget anchor) {
            if (folder_popover != null) {
                folder_popover.popdown();
                folder_popover = null;
            }

            folder_popover = new Gtk.Popover(anchor);
            folder_popover.set_position(Gtk.PositionType.TOP);
            folder_popover.get_style_context().add_class("folder-popover");

            var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
            vbox.margin = 15;

            var name_label = new Gtk.Label(title);
            name_label.halign = Gtk.Align.CENTER;
            name_label.get_style_context().add_class("folder-title");
            vbox.pack_start(name_label, false, false, 0);

            var grid = new Gtk.Grid();
            grid.row_spacing = 10;
            grid.column_spacing = 10;
            grid.halign = Gtk.Align.CENTER;
            for (int i = 0; i < apps.length; i++) {
                grid.attach(create_group_app_item(apps[i]), i % 4, i / 4, 1, 1);
            }

            // A big group scrolls instead of growing past the screen
            var scroll = new Gtk.ScrolledWindow(null, null);
            scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 480;
            scroll.add(grid);
            vbox.pack_start(scroll, true, true, 0);

            folder_popover.add(vbox);
            folder_popover.show_all();
            folder_popover.closed.connect(() => {
                folder_popover = null;
            });
        }

        private Gtk.Widget create_group_app_item(AppInfo app) {
            var btn = new Gtk.Button();
            btn.relief = Gtk.ReliefStyle.NONE;

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);

            var icon = new Gtk.Image();
            var pixbuf = load_cached_icon(app.icon, 48);
            if (pixbuf != null) icon.set_from_pixbuf(pixbuf);
            else icon.set_from_icon_name("application-x-executable", Gtk.IconSize.DIALOG);

            var label = new Gtk.Label(app.name);
            label.max_width_chars = 12;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.get_style_context().add_class("app-name");

            box.pack_start(icon, false, false, 0);
            box.pack_start(label, false, false, 0);
            btn.add(box);

            btn.clicked.connect(() => {
                usage_tracker.record_launch(app.id);
                app.launch();
                if (folder_popover != null) folder_popover.popdown();
                folder_popover = null;
                fade_hide();
            });
            btn.button_press_event.connect((event) => {
                if (event.button == 3) {
                    show_app_menu(app, btn, event);
                    return true;
                }
                return false;
            });
            btn.popup_menu.connect(() => {
                show_app_menu(app, btn, null);
                return true;
            });
            return btn;
        }

        private Gtk.Widget create_shortcut_item(string shortcut_id) {
            var btn = new Gtk.Button();
            btn.relief = Gtk.ReliefStyle.NONE;
            btn.get_style_context().add_class("app-item");

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);

            string icon_name = config.get_shortcut_icon(shortcut_id);
            if (icon_name == "") icon_name = "utilities-terminal";

            var icon = new Gtk.Image();
            var pixbuf = load_cached_icon(icon_name, icon_size);
            if (pixbuf != null) icon.set_from_pixbuf(pixbuf);
            else icon.set_from_icon_name(icon_name, Gtk.IconSize.DIALOG);

            var label = new Gtk.Label(config.get_shortcut_name(shortcut_id));
            label.get_style_context().add_class("app-name");
            label.max_width_chars = 12;
            label.ellipsize = Pango.EllipsizeMode.END;

            box.pack_start(icon, false, false, 0);
            box.pack_start(label, false, false, 0);

            btn.add(box);
            btn.set_size_request(item_size, item_size);

            btn.clicked.connect(() => {
                string cmd = config.get_shortcut_command(shortcut_id);
                try {
                    string[] argv;
                    Shell.parse_argv(cmd, out argv);
                    Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
                } catch (Error e) {
                    warning("Failed to launch shortcut: %s", e.message);
                }
                usage_tracker.record_launch("shortcut:" + shortcut_id);
                fade_hide();
            });

            btn.button_press_event.connect((event) => {
                if (event.button == 3) {
                    show_shortcut_menu(shortcut_id, event);
                    return true;
                }
                return false;
            });

            return btn;
        }

        private void show_shortcut_menu(string shortcut_id, Gdk.EventButton event) {
            var menu = new Gtk.Menu();

            var edit_item = new Gtk.MenuItem.with_label("Edit Shortcut");
            edit_item.activate.connect(() => {
                show_shortcut_dialog(shortcut_id);
            });
            menu.append(edit_item);

            var delete_item = new Gtk.MenuItem.with_label("Delete Shortcut");
            delete_item.activate.connect(() => {
                config.delete_shortcut(shortcut_id);
                on_search_changed();
            });
            menu.append(delete_item);

            menu.show_all();
            menu.popup_at_pointer(event);
        }

        private void show_shortcut_dialog(string? shortcut_id) {
            bool is_edit = shortcut_id != null;
            string title = is_edit ? "Edit Shortcut" : "Create Shortcut";

            var dialog = new Gtk.Dialog.with_buttons(title, this,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                "_Cancel", Gtk.ResponseType.CANCEL,
                "_OK", Gtk.ResponseType.OK);
            dialog.set_default_response(Gtk.ResponseType.OK);

            var content = dialog.get_content_area();
            content.spacing = 8;
            content.margin = 16;

            var name_label = new Gtk.Label("Name:");
            name_label.halign = Gtk.Align.START;
            content.add(name_label);

            var name_entry = new Gtk.Entry();
            name_entry.placeholder_text = "My Script";
            if (is_edit) name_entry.text = config.get_shortcut_name(shortcut_id);
            content.add(name_entry);

            var cmd_label = new Gtk.Label("Command:");
            cmd_label.halign = Gtk.Align.START;
            content.add(cmd_label);

            var cmd_entry = new Gtk.Entry();
            cmd_entry.placeholder_text = "/path/to/script.sh";
            if (is_edit) cmd_entry.text = config.get_shortcut_command(shortcut_id);
            content.add(cmd_entry);

            var icon_label = new Gtk.Label("Icon (optional):");
            icon_label.halign = Gtk.Align.START;
            content.add(icon_label);

            var icon_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);

            var icon_entry = new Gtk.Entry();
            icon_entry.placeholder_text = "utilities-terminal";
            icon_entry.hexpand = true;
            icon_entry.activates_default = true;
            if (is_edit) {
                string ic = config.get_shortcut_icon(shortcut_id);
                if (ic != "") icon_entry.text = ic;
            }
            icon_box.pack_start(icon_entry, true, true, 0);

            var browse_btn = new Gtk.Button.from_icon_name("document-open-symbolic", Gtk.IconSize.BUTTON);
            browse_btn.tooltip_text = "Browse for icon";
            icon_box.pack_start(browse_btn, false, false, 0);

            var icon_preview = new Gtk.Image.from_icon_name("utilities-terminal", Gtk.IconSize.LARGE_TOOLBAR);
            icon_box.pack_start(icon_preview, false, false, 0);

            // Live preview: update as user types (handles paths and theme names)
            icon_entry.changed.connect(() => {
                string text = icon_entry.text.strip();
                if (text == "") {
                    icon_preview.set_from_icon_name("utilities-terminal", Gtk.IconSize.LARGE_TOOLBAR);
                    return;
                }
                if (text.has_prefix("/") && FileUtils.test(text, FileTest.EXISTS)) {
                    try {
                        var pixbuf = new Gdk.Pixbuf.from_file_at_size(text, 24, 24);
                        icon_preview.set_from_pixbuf(pixbuf);
                    } catch (Error e) {
                        icon_preview.set_from_icon_name(text, Gtk.IconSize.LARGE_TOOLBAR);
                    }
                } else {
                    icon_preview.set_from_icon_name(text, Gtk.IconSize.LARGE_TOOLBAR);
                }
            });

            // Browse for icon file
            browse_btn.clicked.connect(() => {
                var chooser = new Gtk.FileChooserDialog("Choose Icon", dialog,
                    Gtk.FileChooserAction.OPEN,
                    "_Cancel", Gtk.ResponseType.CANCEL,
                    "_Open", Gtk.ResponseType.ACCEPT);

                var filter = new Gtk.FileFilter();
                filter.set_filter_name("Image files");
                filter.add_pattern("*.png");
                filter.add_pattern("*.svg");
                filter.add_pattern("*.xpm");
                filter.add_pattern("*.ico");
                chooser.add_filter(filter);

                var all_filter = new Gtk.FileFilter();
                all_filter.set_filter_name("All files");
                all_filter.add_pattern("*");
                chooser.add_filter(all_filter);

                chooser.set_current_folder("/usr/share/icons");

                var preview_img = new Gtk.Image();
                preview_img.set_size_request(64, 64);
                chooser.set_preview_widget(preview_img);
                chooser.update_preview.connect(() => {
                    string? path = chooser.get_preview_filename();
                    if (path != null) {
                        try {
                            var pixbuf = new Gdk.Pixbuf.from_file_at_size(path, 64, 64);
                            preview_img.set_from_pixbuf(pixbuf);
                            chooser.set_preview_widget_active(true);
                        } catch (Error e) {
                            chooser.set_preview_widget_active(false);
                        }
                    }
                });

                if (chooser.run() == Gtk.ResponseType.ACCEPT) {
                    icon_entry.text = chooser.get_filename();
                }
                chooser.destroy();
            });

            content.add(icon_box);

            dialog.show_all();

            dialog.response.connect((response) => {
                if (response == Gtk.ResponseType.OK) {
                    string name = name_entry.text.strip();
                    string cmd = cmd_entry.text.strip();
                    if (name != "" && cmd != "") {
                        string icon_name = icon_entry.text.strip();
                        if (icon_name == "") icon_name = "utilities-terminal";

                        if (is_edit) {
                            config.update_shortcut(shortcut_id, name, cmd, icon_name);
                        } else {
                            string new_id = "shortcut_%s".printf(GLib.get_real_time().to_string());
                            config.create_shortcut(new_id, name, cmd, icon_name);
                        }
                        on_search_changed();
                    }
                }
                dialog.destroy();
            });
        }

        private void show_folder_preview(Gtk.Widget btn) {
            btn.get_style_context().add_class("folder-forming");
            // Two-phase pop animation:
            //   Phase 1 (0–55%): smooth rise from dim to full (the "reveal")
            //   Phase 2 (55–100%): gentle bounce dip then settle (the "pop")
            btn.opacity = 0.3;
            int64 start = GLib.get_monotonic_time();
            btn.add_tick_callback((widget, clock) => {
                int64 elapsed = GLib.get_monotonic_time() - start;
                double t = double.min(1.0, elapsed / 380000.0);  // 380ms total

                if (t < 0.55) {
                    // Phase 1: ease-out cubic rise
                    double p = t / 0.55;
                    double f = 1.0 - p;
                    double ease = 1.0 - f * f * f;
                    widget.opacity = 0.3 + 0.7 * ease;
                } else {
                    // Phase 2: sine bounce — dips to ~0.92 then recovers
                    double p = (t - 0.55) / 0.45;
                    double bounce = Math.sin(p * Math.PI) * 0.09;
                    widget.opacity = 1.0 - bounce;
                }

                if (t >= 1.0) {
                    widget.opacity = 1.0;
                    return false;
                }
                return true;
            });
        }

        private void cancel_folder_preview() {
            if (folder_preview_timeout_id != 0) {
                Source.remove(folder_preview_timeout_id);
                folder_preview_timeout_id = 0;
            }
            if (folder_preview_target != null) {
                folder_preview_target.get_style_context().remove_class("folder-forming");
                folder_preview_target.opacity = 1.0;
                folder_preview_target = null;
            }
        }

        private Gtk.Grid? page_grid(int page) {
            return page_stack.get_child_by_name("page_%d".printf(page)) as Gtk.Grid;
        }

        // Grid cell of the focused app item on the visible page
        private bool focused_cell(out int col, out int row) {
            col = -1;
            row = -1;
            var grid = page_grid(current_page);
            var focus = get_focus();
            if (grid == null || focus == null) return false;
            for (int r = 0; r < rows; r++) {
                for (int c = 0; c < cols; c++) {
                    if (grid.get_child_at(c, r) == focus) {
                        col = c;
                        row = r;
                        return true;
                    }
                }
            }
            return false;
        }

        // Focus the item at (col, row), or the closest one before it in that row
        private bool focus_cell(Gtk.Grid? grid, int col, int row) {
            if (grid == null || row < 0) return false;
            for (int c = int.min(col, cols - 1); c >= 0; c--) {
                var item = grid.get_child_at(c, row);
                if (item != null) {
                    item.grab_focus();
                    return true;
                }
            }
            return false;
        }

        // Focus the nearest row at or above `row` that has an item in it
        private void focus_cell_up_from(Gtk.Grid? grid, int col, int row) {
            for (int r = row; r >= 0; r--) {
                if (focus_cell(grid, col, r)) return;
            }
        }

        private bool navigate_items(uint keyval, int col, int row) {
            var grid = page_grid(current_page);
            switch (keyval) {
                case Gdk.Key.Left:
                    if (col > 0) {
                        focus_cell(grid, col - 1, row);
                    } else if (current_page > 0) {
                        go_to_page(current_page - 1);
                        focus_cell(page_grid(current_page), cols - 1, row);
                    }
                    return true;
                case Gdk.Key.Right:
                    if (col < cols - 1 && grid.get_child_at(col + 1, row) != null) {
                        focus_cell(grid, col + 1, row);
                    } else if (current_page < total_pages - 1) {
                        go_to_page(current_page + 1);
                        focus_cell_up_from(page_grid(current_page), 0, row);
                    }
                    return true;
                case Gdk.Key.Down:
                    focus_cell(grid, col, row + 1);
                    return true;
                case Gdk.Key.Up:
                    if (row > 0) {
                        focus_cell(grid, col, row - 1);
                    } else {
                        search_entry.grab_focus();
                    }
                    return true;
            }
            return false;
        }

        private bool on_key_press(Gdk.EventKey event) {
            var focus = get_focus();
            bool on_item = focus != null && focus.get_style_context().has_class("app-item");
            bool entry_has_text = search_entry.has_focus && search_entry.text != "";

            if (event.keyval == Gdk.Key.Escape) {
                if (folder_popover != null) {
                    folder_popover.popdown();
                    folder_popover = null;
                    return true;
                }
                fade_hide();
                return true;
            }
            if (event.keyval == Gdk.Key.Return || event.keyval == Gdk.Key.KP_Enter) {
                // Nothing in the grid matches, but a calculation, file or web search does
                if (!on_item && search_entry.text != "" && ordered_items.length() == 0) {
                    var rows = quick_box.get_children();
                    if (rows != null) {
                        ((Gtk.Button) rows.data).clicked();
                        return true;
                    }
                }
                // With an icon focused, Enter activates that icon instead
                if (!on_item && search_entry.text != "" && ordered_items.length() > 0) {
                    string first = ordered_items.nth_data(0);
                    if (first.has_prefix("app:")) {
                        var app = app_manager.get_app(first.substring(4));
                        if (app != null) {
                            usage_tracker.record_launch(app.id);
                            app.launch();
                        }
                    } else if (first.has_prefix("shortcut:")) {
                        string sid = first.substring(9);
                        string cmd = config.get_shortcut_command(sid);
                        try {
                            string[] argv;
                            Shell.parse_argv(cmd, out argv);
                            Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
                        } catch (Error e) {}
                        usage_tracker.record_launch("shortcut:" + sid);
                    }
                    fade_hide();
                    return true;
                }
            }

            if (event.keyval == Gdk.Key.Page_Up) {
                go_to_page(current_page - 1);
                return true;
            }
            if (event.keyval == Gdk.Key.Page_Down) {
                go_to_page(current_page + 1);
                return true;
            }

            if (on_item) {
                int col, row;
                if (focused_cell(out col, out row) && navigate_items(event.keyval, col, row)) return true;
            } else if (search_entry.has_focus && event.keyval == Gdk.Key.Down) {
                // From the search box, Down drops into the grid
                var grid = page_grid(current_page);
                if (grid != null && focus_cell(grid, 0, 0)) return true;
            }

            // Left/Right/Home/End move the text cursor while there is something to edit;
            // otherwise they turn pages.
            if (!entry_has_text && !on_item) {
                switch (event.keyval) {
                    case Gdk.Key.Left:
                        go_to_page(current_page - 1);
                        return true;
                    case Gdk.Key.Right:
                        go_to_page(current_page + 1);
                        return true;
                    case Gdk.Key.Home:
                        go_to_page(0);
                        return true;
                    case Gdk.Key.End:
                        go_to_page(total_pages - 1);
                        return true;
                }
            }

            // Typing from anywhere goes to the search box. Space stays with a focused icon
            // (it activates it), and shortcuts like Ctrl+C are left alone.
            bool plain = (event.state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.MOD1_MASK)) == 0;
            // Control characters (Return, Tab, ...) also have a unicode value, so exclude them.
            uint32 typed = Gdk.keyval_to_unicode(event.keyval);
            bool printable = typed >= 0x20 && typed != 0x7f &&
                             !(on_item && event.keyval == Gdk.Key.space);
            if (!search_entry.has_focus && plain && (printable || event.keyval == Gdk.Key.BackSpace)) {
                search_entry.grab_focus();
            }
            return false;
        }

        private bool on_bg_click(Gdk.EventButton event) {
            if (folder_popover != null) {
                folder_popover.popdown();
                folder_popover = null;
                return true;
            }
            fade_hide();
            return true;
        }

        private bool on_scroll(Gdk.EventScroll event) {
            int64 now = GLib.get_monotonic_time();
            bool new_gesture = now - last_scroll_event_us > SCROLL_GESTURE_GAP_US;
            last_scroll_event_us = now;
            if (new_gesture) {
                scroll_accumulator_x = 0.0;
                scroll_accumulator_y = 0.0;
                scroll_gesture_consumed = false;
            }

            if (event.direction == Gdk.ScrollDirection.SMOOTH) {
                // Touchpad inertia keeps sending events after the flip; wait for a pause
                if (scroll_gesture_consumed) return true;

                scroll_accumulator_x += event.delta_x;
                scroll_accumulator_y += event.delta_y;

                double effective_delta = Math.fabs(scroll_accumulator_x) > Math.fabs(scroll_accumulator_y)
                    ? scroll_accumulator_x
                    : scroll_accumulator_y;

                if (effective_delta > SCROLL_THRESHOLD || effective_delta < -SCROLL_THRESHOLD) {
                    go_to_page(current_page + (effective_delta > 0 ? 1 : -1));
                    scroll_accumulator_x = 0.0;
                    scroll_accumulator_y = 0.0;
                    scroll_gesture_consumed = true;
                }
                return true;
            }

            int step;
            if (event.direction == Gdk.ScrollDirection.LEFT || event.direction == Gdk.ScrollDirection.UP) {
                step = -1;
            } else if (event.direction == Gdk.ScrollDirection.RIGHT || event.direction == Gdk.ScrollDirection.DOWN) {
                step = 1;
            } else {
                return false;
            }
            // Don't restart the slide on every notch of a fast wheel spin
            if (now >= wheel_locked_until_us) {
                go_to_page(current_page + step);
                wheel_locked_until_us = now + WHEEL_LOCKOUT_US;
            }
            return true;
        }

        public void toggle() {
            if (fading_out) return;

            if (timing && !visible) {
                timing_t0 = GLib.get_monotonic_time();
                timing_wait_draw = true;
                message("launcher timing: open requested (first=%s)", (!has_shown_once).to_string());
            }
            if (visible) {
                fade_hide();
            } else {
                search_entry.text = "";
                clear_quick_results();
                // Pages should already be pre-built via idle; fallback sync if not
                if (pages_dirty) {
                    if (rebuild_idle_id != 0) {
                        Source.remove(rebuild_idle_id);
                        rebuild_idle_id = 0;
                    }
                    on_search_changed();
                } else {
                    current_page = 0;
                    page_stack.set_visible_child_full("page_0",
                        Gtk.StackTransitionType.NONE);
                    update_page_indicator();
                }
                fade_show();
            }
        }

        // Called externally when pinned apps or folders change
        public void mark_dirty() {
            pages_dirty = true;
            schedule_rebuild();
        }

        // Called when app list changes (install/uninstall)
        public void refresh_apps() {
            build_category_buttons();
            mark_dirty();
        }

        // Pre-build pages in an idle callback so they're ready before the user opens
        private void schedule_rebuild() {
            if (rebuild_idle_id != 0) return;
            rebuild_idle_id = Idle.add(() => {
                rebuild_idle_id = 0;
                if (pages_dirty && !visible) {
                    search_entry.text = "";
                    on_search_changed();
                }
                prewarm();
                return false;
            });
        }

        // Show the children and realize the window without mapping it, so the
        // first real open skips most of the one-time widget setup
        private void prewarm() {
            if (has_shown_once || visible) return;
            var child = get_child();
            if (child != null) child.show_all();
            realize();
            has_shown_once = true;
            if (timing) message("launcher timing: prewarmed");
        }

        // Ease-out cubic: fast start, smooth deceleration
        private static double ease_out_cubic(double t) {
            double f = 1.0 - t;
            return 1.0 - f * f * f;
        }

        // Fade level of the whole window. On X11 this goes through the
        // window's opacity property so the compositor blends it; GtkWidget
        // opacity would make GTK repaint the fullscreen window every frame,
        // and that stream of damage makes picom stutter.
        private double fade_level = 1.0;

        private void set_fade_level(double level) {
            fade_level = level;
            var gdk_window = get_window();
            if (gdk_window != null && CompositorHints.set_window_opacity(gdk_window, level)) {
                return;
            }
            this.opacity = level;
        }

        private void cancel_fade() {
            if (fade_tick_id != 0) {
                remove_tick_callback(fade_tick_id);
                fade_tick_id = 0;
            }
        }

        private void fade_show() {
            cancel_fade();
            timing_log("prepared, showing");

            // Start transparent before mapping so the compositor never gets a
            // fully opaque first frame
            // The window must exist for the opacity property to be set before mapping
            if (!get_realized()) realize();
            set_fade_level(config.get_launcher_fade() ? 0.0 : 1.0);

            // First open needs show_all() to realize all children;
            // subsequent opens just need show() (children already realized)
            if (!has_shown_once) {
                show_all();
                has_shown_once = true;
            } else {
                show();
            }

            timing_log("shown");
            bool fade_enabled = config.get_launcher_fade();
            if (!fade_enabled) {
                set_fade_level(1.0);
                search_entry.grab_focus();
                return;
            }

            search_entry.grab_focus();
            timing_log("focused");

            int64 start_us = GLib.get_monotonic_time();
            fade_tick_id = add_tick_callback((widget, clock) => {
                int64 elapsed_us = GLib.get_monotonic_time() - start_us;
                if (timing) { trace_frame("fade-in", clock); }
                double t = double.min(1.0, elapsed_us / (FADE_DURATION_MS * 1000.0));
                set_fade_level(ease_out_cubic(t));
                if (t >= 1.0) {
                    fade_tick_id = 0;
                    if (timing) trace_flush("fade-in");
                    return false;
                }
                return true;
            });
        }

        private void fade_hide() {
            cancel_fade();

            bool fade_enabled = config.get_launcher_fade();
            if (!fade_enabled) {
                set_fade_level(1.0);
                hide();
                return;
            }
            fading_out = true;
            int64 start_us = GLib.get_monotonic_time();
            if (timing) message("launcher timing: fade-out start");
            fade_tick_id = add_tick_callback((widget, clock) => {
                int64 elapsed_us = GLib.get_monotonic_time() - start_us;
                if (timing) { trace_frame("fade-out", clock); }
                double t = double.min(1.0, elapsed_us / (FADE_DURATION_MS * 1000.0));
                set_fade_level(1.0 - ease_out_cubic(t));
                if (t >= 1.0) {
                    fade_tick_id = 0;
                    fading_out = false;
                    if (timing) { trace_flush("fade-out"); message("launcher timing: fade-out done, hiding"); }
                    // Unmap while still transparent and leave the opacity at 0.
                    // A compositor that fades unmapping windows (picom with
                    // fading on) would otherwise fade a full-opacity ghost out
                    // a second time. fade_show sets the opacity before mapping.
                    hide();
                    return false;
                }
                return true;
            });
        }
    }
}
