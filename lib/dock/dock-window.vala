namespace Dokku {
    public class DockWindow : Gtk.Window {
        private WindowManager wm;
        private DockRenderer renderer;
        private AppManager app_manager;
        private ConfigManager config;
        private PluginManager plugin_manager;
        private ThemeManager theme_manager;
        private Theme current_theme;
        private NotificationMonitor? notification_monitor;
        private List<DockItem> items;
        private Gtk.Menu? context_menu;

        public signal void launcher_requested();
        public signal void settings_requested();

        private double mouse_x = -1;
        private double mouse_y = -1;
        private bool hovering = false;
        private bool auto_hide = false;
        private bool dodge_windows = false;
        private bool dodge_hiding = false;
        private uint dodge_check_timeout_id = 0;
        private bool hidden = false;
        private int base_height;
        private int dock_padding = 10;
        private int icon_area_height;
        private uint hide_timeout_id = 0;

        // Smooth slide animation for autohide
        private double dock_slide_offset = 0.0;  // 0.0 = shown, 1.0 = hidden
        private uint slide_tick_id = 0;
        private int64 slide_start_time = 0;
        private double slide_from = 0.0;
        private double slide_to = 0.0;
        private const int SLIDE_DURATION_MS = 250;
        private const int SEPARATOR_WIDTH = 24;

        private int drag_index = -1;
        private double drag_start_x;
        private int hovered_index = -1;
        private int drop_insert_index = -1;

        private uint launch_rehide_timeout_id = 0;

        private uint bounce_tick_id = 0;
        private HashTable<string, int64?> bounce_cooldowns;
        private const int64 BOUNCE_COOLDOWN_US = 5000000;  // 5 seconds in microseconds
        private bool initial_load_done = false;
        private bool is_reordering = false;
        private int reorder_insert_index = -1;
        private double reorder_mouse_x = -1;
        private const double DRAG_THRESHOLD = 5.0;

        // Drag-to-remove: unpin by dragging away from dock
        private bool drag_removing = false;
        private double drag_mouse_cross = -1;
        private const double REMOVE_THRESHOLD = 50.0;
        private Gtk.Window? drag_float_popup = null;
        private Gdk.Pixbuf? drag_float_icon = null;
        private bool drag_float_poofing = false;  // true = popup is playing poof
        private int64 poof_start_time = 0;
        private const int POOF_DURATION_MS = 300;

        private ProgressMonitor? progress_monitor;
        private uint progress_tick_id = 0;
        private UsageTracker usage_tracker;

        private uint hover_preview_timeout_id = 0;
        private uint media_play_update_id = 0;
        private Gtk.Window? preview_popup = null;
        private int preview_target_index = -1;
        private uint preview_dismiss_timeout_id = 0;

        private bool use_layer_shell = false;
        private bool rounded_corners = true;
        private double dock_opacity = 0.55;
        private int dock_margin_bottom = 2;
        private string dock_position = "bottom";
        private bool is_vertical = false;
        private Gdk.Monitor? target_monitor = null;

        // Compositor blur hint (Picom / KWin)
        private bool blur_enabled = false;
        // Separate blur-trigger window: capsule-sized, gets picom blur.
        // Keeps the main dock shape-free so magnified icons extend freely
        // above the dock background, exactly like macOS.
        private Gtk.Window? blur_bg = null;

        // Cached blur shape dimensions to avoid re-creating surface on every size_allocate
        private int blur_shape_w = 0;
        private int blur_shape_h = 0;
        private double blur_shape_radius = -1;

        // Coalesced redraw to avoid redundant queue_draw() calls
        private bool draw_queued = false;

        // Reusable layout buffer - avoids per-frame allocation
        private double[] layout_scales = {};
        private int layout_scales_len = 0;

        private const Gtk.TargetEntry[] DROP_TARGETS = {
            { "text/uri-list", 0, 0 }
        };

        public DockWindow(Gtk.Application app, AppManager app_manager, ConfigManager config, UsageTracker usage_tracker) {
            Object(application: app);

            use_layer_shell = GtkLayerShell.is_supported();

            if (use_layer_shell) {
                GtkLayerShell.init_for_window(this);
                GtkLayerShell.set_layer(this, GtkLayerShell.Layer.TOP);
                GtkLayerShell.set_namespace(this, "dokku");
                // Anchors set after dock_position is loaded (below)
            }

            // Always set these — DOCK type hint tells the WM and compositor
            // this is a dock (no decorations, no focus stealing, no taskbar)
            set_type_hint(Gdk.WindowTypeHint.DOCK);
            set_decorated(false);

            this.app_manager = app_manager;
            this.usage_tracker = usage_tracker;
            renderer = new DockRenderer();
            renderer.app_manager = app_manager;
            this.config = config;
            plugin_manager = new PluginManager(config);
            theme_manager = new ThemeManager();
            items = new List<DockItem>();
            bounce_cooldowns = new HashTable<string, int64?>(str_hash, str_equal);

            // Compositor blur hint
            blur_enabled = config.get_blur_enabled();

            load_theme();
            
            var launcher_item = new DockItem("dokku-launcher", "Applications", "view-app-grid-symbolic");
            launcher_item.pinned = true;
            launcher_item.is_launcher = true;
            items.append(launcher_item);

            load_pinned_apps();
            load_plugins();

            // Window setup
            set_skip_taskbar_hint(true);
            set_skip_pager_hint(true);
            set_keep_above(true);
            if (!use_layer_shell) {
                stick();
                get_screen().size_changed.connect(position_dock);
            }

            set_app_paintable(true);
            var visual = get_screen().get_rgba_visual();
            if (visual != null) set_visual(visual);

            add_events(Gdk.EventMask.POINTER_MOTION_MASK |
                       Gdk.EventMask.LEAVE_NOTIFY_MASK |
                       Gdk.EventMask.ENTER_NOTIFY_MASK |
                       Gdk.EventMask.BUTTON_PRESS_MASK |
                       Gdk.EventMask.BUTTON_RELEASE_MASK);

            // Enable drag-and-drop for .desktop files (no HIGHLIGHT — we draw our own indicator)
            Gtk.drag_dest_set(this, Gtk.DestDefaults.DROP, DROP_TARGETS, Gdk.DragAction.COPY);
            drag_data_received.connect(on_drag_data_received);
            drag_motion.connect(on_drag_motion);
            drag_leave.connect(on_drag_leave);

            if (is_vertical)
                set_default_size(base_height, calculate_dock_length());
            else
                set_default_size(calculate_dock_length(), base_height);

            if (!use_layer_shell) {
                realize.connect(position_dock);
            }

            // On X11: set override_redirect so the WM doesn't manage the dock.
            // This is required for proper ARGB transparency under XFwm4 and
            // other non-picom compositors. Picom still sees the window via
            // class_g matching and our custom X11 atoms.
            // On Wayland (layer shell), this is not needed.
            realize.connect(() => {
                if (!use_layer_shell) {
                    get_window().set_override_redirect(true);
                }
                update_compositor_hints();
            });
            // Re-apply hints after the window is mapped (visible to compositor).
            // Also create the blur background window if needed.
            map.connect(() => {
                update_compositor_hints();
                ensure_blur_bg();
                queue_draw();
            });

            wm = new WindowManager();
            wm.windows_changed.connect(update_running_apps);
            wm.window_geometry_changed.connect(schedule_dodge_check);
            wm.active_changed.connect(() => {
                clear_badge_for_focused_app();
                clear_bounce_for_focused_app();
                schedule_redraw();
            });
            wm.attention_requested.connect(on_attention_requested);

            if (config.get_notification_badges()) {
                notification_monitor = new NotificationMonitor(app_manager);
                notification_monitor.notification_received.connect(on_notification);
            }

            progress_monitor = new ProgressMonitor(app_manager);
            progress_monitor.progress_changed.connect(on_progress_changed);

            draw.connect(on_draw);
            motion_notify_event.connect(on_motion);
            leave_notify_event.connect(on_leave);
            enter_notify_event.connect(on_enter);
            button_press_event.connect(on_button_press);
            button_release_event.connect(on_button_release);

            this.destroy.connect(() => {
                // Pointer grab
                if (is_reordering) {
                    var seat = get_display().get_default_seat();
                    seat.ungrab();
                    is_reordering = false;
                }
                destroy_drag_float_popup();

                // Timeouts
                if (dodge_check_timeout_id != 0) { Source.remove(dodge_check_timeout_id); dodge_check_timeout_id = 0; }
                if (hide_timeout_id != 0) { Source.remove(hide_timeout_id); hide_timeout_id = 0; }
                if (launch_rehide_timeout_id != 0) { Source.remove(launch_rehide_timeout_id); launch_rehide_timeout_id = 0; }
                if (hover_preview_timeout_id != 0) { Source.remove(hover_preview_timeout_id); hover_preview_timeout_id = 0; }
                if (preview_dismiss_timeout_id != 0) { Source.remove(preview_dismiss_timeout_id); preview_dismiss_timeout_id = 0; }
                if (media_popup_dismiss_id != 0) { Source.remove(media_popup_dismiss_id); media_popup_dismiss_id = 0; }
                if (media_play_update_id != 0) { Source.remove(media_play_update_id); media_play_update_id = 0; }

                // Tick callbacks are auto-removed on widget destroy, but null IDs
                slide_tick_id = 0;
                bounce_tick_id = 0;
                progress_tick_id = 0;

                // Popups
                if (media_popup != null) { media_popup.destroy(); media_popup = null; }
                if (preview_popup != null) { preview_popup.destroy(); preview_popup = null; }
                if (blur_bg != null) { blur_bg.destroy(); blur_bg = null; }
            });

            auto_hide = config.get_auto_hide();
            dodge_windows = config.get_dodge_windows();
            dock_position = config.get_position();
            is_vertical = (dock_position == "left" || dock_position == "right");
            renderer.icon_size = config.get_icon_size();
            renderer.magnification = config.get_magnification();
            rounded_corners = config.get_rounded_corners();
            dock_opacity = config.get_dock_opacity();
            update_dock_dimensions();

            if (use_layer_shell) {
                apply_layer_shell_anchors();
                GtkLayerShell.set_exclusive_zone(this, (auto_hide || dodge_hiding) ? 0 : base_height);
            }
        }

        public void set_target_monitor(Gdk.Monitor monitor) {
            target_monitor = monitor;
            if (use_layer_shell) {
                GtkLayerShell.set_monitor(this, monitor);
            } else {
                position_dock();
            }
        }

        public Gdk.Monitor? get_target_monitor_ref() {
            return target_monitor;
        }

        /**
         * Returns the monitor this dock should display on.
         * Uses target_monitor if set (multi-monitor), otherwise falls back
         * to the primary monitor or monitor 0.
         */
        private Gdk.Monitor? get_dock_monitor() {
            if (target_monitor != null) return target_monitor;
            var display = Gdk.Display.get_default();
            var mon = display.get_primary_monitor();
            if (mon == null) mon = display.get_monitor(0);
            return mon;
        }

        private void apply_layer_shell_anchors() {
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.BOTTOM, dock_position == "bottom");
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.TOP, dock_position == "top");
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.LEFT, dock_position == "left");
            GtkLayerShell.set_anchor(this, GtkLayerShell.Edge.RIGHT, dock_position == "right");
        }

        private void update_dock_dimensions() {
            int icon_size = renderer.icon_size;
            int max_icon = (int)(icon_size * renderer.magnification);
            // Dock background tightly wraps resting icons (macOS-style capsule):
            // icon + top padding (8px) + bottom padding for dots (12px)
            icon_area_height = icon_size + 20;
            // Window must be tall enough for magnified icons that pop above the background
            base_height = max_icon + 34;
        }

        private void load_plugins() {
            if (config.get_plugin_enabled("separator")) {
                var sep = plugin_manager.get_plugin("separator");
                if (sep != null) items.append(new DockItem.from_plugin(sep));
            }

            // Media widget — inserted right after separator
            if (config.get_media_widget() && config.get_plugin_enabled("media-player")) {
                var media = plugin_manager.get_plugin("media-player") as MediaPlugin;
                if (media != null) {
                    media.changed.connect(() => {
                        update_media_widget(media);
                        schedule_redraw();
                    });
                    if (media.has_media) {
                        items.append(new DockItem.from_plugin(media));
                    }
                }
            }

            // User script widget plugins
            foreach (var up in plugin_manager.get_user_plugins()) {
                if (!config.get_plugin_enabled(up.id)) continue;
                var sp = up as ScriptPlugin;
                if (sp != null && sp.is_widget) {
                    items.append(new DockItem.from_plugin(sp));
                    sp.updated.connect(() => schedule_redraw());
                }
            }

            if (config.get_plugin_enabled("show-desktop")) {
                var p = plugin_manager.get_plugin("show-desktop");
                if (p != null) items.append(new DockItem.from_plugin(p));
            }
            if (config.get_plugin_enabled("trash")) {
                var trash = plugin_manager.get_plugin("trash") as TrashPlugin;
                if (trash != null) {
                    items.append(new DockItem.from_plugin(trash));
                    trash.changed.connect(() => {
                        renderer.clear_icon_cache("user-trash");
                        renderer.clear_icon_cache("user-trash-full");
                        schedule_redraw();
                    });
                }
            }
        }

        private void update_media_widget(MediaPlugin media) {
            // Find existing media widget item
            DockItem? existing = null;
            foreach (var item in items) {
                if (item.is_media_widget) {
                    existing = item;
                    break;
                }
            }

            if (media.has_media) {
                if (existing == null) {
                    // Add media widget after separator
                    var media_item = new DockItem.from_plugin(media);
                    int sep_idx = find_separator_index();
                    if (sep_idx >= 0) {
                        items.insert(media_item, sep_idx + 1);
                    } else {
                        items.append(media_item);
                    }
                }
                // If it exists already, queue_draw will refresh it
            } else {
                if (existing != null) {
                    items.remove(existing);
                }
            }
            position_dock();
        }

        private void load_pinned_apps() {
            foreach (var entry in config.get_pinned_apps()) {
                // Handle folder entries
                if (entry.has_prefix("folder:")) {
                    string folder_id = entry.substring("folder:".length);
                    string name = config.get_folder_name(folder_id);
                    if (name == "") continue;
                    var folder_item = new DockItem("folder:" + folder_id, name, "folder");
                    folder_item.is_folder = true;
                    folder_item.folder_id = folder_id;
                    folder_item.folder_apps = config.get_folder_apps(folder_id);
                    folder_item.pinned = true;
                    items.append(folder_item);
                    continue;
                }

                DockItem? item = null;

                // Check if it's a path to a .desktop file
                if (entry.has_suffix(".desktop") && FileUtils.test(entry, FileTest.EXISTS)) {
                    var app = new AppInfo.from_desktop_file(entry);
                    if (app.exec != "") {
                        item = new DockItem(app.id, app.name, app.icon);
                        item.desktop_file = app.desktop_file;
                    }
                } else {
                    // Try as app ID
                    var app = app_manager.get_app(entry);
                    if (app != null) {
                        item = new DockItem(app.id, app.name, app.icon);
                        item.desktop_file = app.desktop_file;
                    }
                }

                if (item != null) {
                    item.pinned = true;
                    string? custom_icon = config.get_custom_icon(item.id);
                    if (custom_icon != null) item.icon_name = custom_icon;
                    items.append(item);
                }
            }
            bool has_pinned = false;
            foreach (var item in items) {
                if (item.pinned && !item.is_launcher && !item.is_plugin) {
                    has_pinned = true;
                    break;
                }
            }
            if (!has_pinned) {
                var files = new DockItem("thunar", "Files", "system-file-manager");
                files.pinned = true;
                items.append(files);
                var term = new DockItem("xfce4-terminal", "Terminal", "utilities-terminal");
                term.pinned = true;
                items.append(term);
            }
        }

        private void save_pinned_apps() {
            string[] pinned = {};
            foreach (var item in items) {
                if (item.is_folder) {
                    pinned += "folder:" + item.folder_id;
                } else if (item.pinned && !item.is_launcher && !item.is_plugin) {
                    if (item.desktop_file != null && item.desktop_file != "")
                        pinned += item.desktop_file;
                    else
                        pinned += item.id;
                }
            }
            config.set_pinned_apps(pinned);
        }

        private void load_theme() {
            current_theme = theme_manager.get_theme(config.get_theme());
            if (current_theme == null) current_theme = theme_manager.get_theme("default");
            renderer.theme = current_theme;
        }

        private int calculate_dock_length() {
            int total = dock_padding * 2;
            foreach (var item in items) {
                if (item.is_separator) {
                    total += SEPARATOR_WIDTH;
                } else {
                    double wf = item.dock_width_factor;
                    if (is_vertical && item.is_media_widget) wf = 1.0;
                    double mag = (item.is_media_widget || item.is_launcher) ? 1.0 : renderer.magnification;
                    total += (int)(renderer.icon_size * wf * mag) + renderer.spacing;
                }
            }
            if (drop_insert_index >= 0) {
                total += renderer.spacing * 2;
            }
            return int.max(total, 200);
        }

        private void position_dock() {
            if (slide_tick_id == 0) {
                dock_slide_offset = hidden ? 1.0 : 0.0;
            }
            apply_dock_position();
        }

        private GtkLayerShell.Edge position_to_edge() {
            if (dock_position == "top") return GtkLayerShell.Edge.TOP;
            if (dock_position == "left") return GtkLayerShell.Edge.LEFT;
            if (dock_position == "right") return GtkLayerShell.Edge.RIGHT;
            return GtkLayerShell.Edge.BOTTOM;
        }

        private void apply_dock_position() {
            int dock_length = calculate_dock_length();
            int hide_pixels = (int)(dock_slide_offset * (base_height - 4));

            if (use_layer_shell) {
                GtkLayerShell.set_margin(this, position_to_edge(), dock_margin_bottom - hide_pixels);
                if (is_vertical)
                    resize(base_height, dock_length);
                else
                    resize(dock_length, base_height);
                return;
            }

            // X11 positioning
            var monitor = get_dock_monitor();
            if (monitor == null) return;
            var geometry = monitor.get_geometry();

            int x, y, w, h;
            if (dock_position == "top") {
                w = dock_length; h = base_height;
                x = geometry.x + (geometry.width - w) / 2;
                y = geometry.y - hide_pixels + dock_margin_bottom;
            } else if (dock_position == "left") {
                w = base_height; h = dock_length;
                x = geometry.x - hide_pixels + dock_margin_bottom;
                y = geometry.y + (geometry.height - h) / 2;
            } else if (dock_position == "right") {
                w = base_height; h = dock_length;
                x = geometry.x + geometry.width - w + hide_pixels - dock_margin_bottom;
                y = geometry.y + (geometry.height - h) / 2;
            } else { // bottom
                w = dock_length; h = base_height;
                x = geometry.x + (geometry.width - w) / 2;
                y = geometry.y + geometry.height - h + hide_pixels - dock_margin_bottom;
            }

            resize(w, h);
            move(x, y);

            // Sync blur background window to dock capsule position
            sync_blur_bg(x, y, w, h);
        }

        private static double ease_out_cubic(double t) {
            double f = 1.0 - t;
            return 1.0 - f * f * f;
        }

        private void animate_slide(double target) {
            if (slide_to == target && slide_tick_id != 0) return;
            slide_from = dock_slide_offset;
            slide_to = target;
            slide_start_time = -1;  // capture on first tick for vsync alignment
            if (slide_tick_id != 0) return;  // reuse running tick
            slide_tick_id = add_tick_callback((widget, frame_clock) => {
                int64 now = frame_clock.get_frame_time();
                if (slide_start_time < 0) slide_start_time = now;
                int64 elapsed_us = now - slide_start_time;
                double t = double.min(1.0, elapsed_us / (SLIDE_DURATION_MS * 1000.0));
                dock_slide_offset = slide_from + (slide_to - slide_from) * ease_out_cubic(t);
                apply_dock_position();
                queue_draw();
                if (t >= 1.0) {
                    dock_slide_offset = slide_to;
                    slide_tick_id = 0;
                    return false;
                }
                return true;
            });
        }

        // --- Dodge windows: hide when a window overlaps the dock ---

        private Gdk.Rectangle get_dock_resting_rect() {
            int dock_length = calculate_dock_length();
            var monitor = get_dock_monitor();
            Gdk.Rectangle rect = {};
            if (monitor == null) return rect;
            var geo = monitor.get_geometry();

            // Use the visible capsule height, not the full window height
            // (base_height includes magnification headroom above the capsule)
            int capsule = icon_area_height;

            if (dock_position == "top") {
                rect.width = dock_length;
                rect.height = capsule;
                rect.x = geo.x + (geo.width - rect.width) / 2;
                rect.y = geo.y + dock_margin_bottom;
            } else if (dock_position == "left") {
                rect.width = capsule;
                rect.height = dock_length;
                rect.x = geo.x + dock_margin_bottom;
                rect.y = geo.y + (geo.height - rect.height) / 2;
            } else if (dock_position == "right") {
                rect.width = capsule;
                rect.height = dock_length;
                rect.x = geo.x + geo.width - rect.width - dock_margin_bottom;
                rect.y = geo.y + (geo.height - rect.height) / 2;
            } else { // bottom
                rect.width = dock_length;
                rect.height = capsule;
                rect.x = geo.x + (geo.width - rect.width) / 2;
                rect.y = geo.y + geo.height - rect.height - dock_margin_bottom;
            }
            return rect;
        }

        private void schedule_dodge_check() {
            if (!dodge_windows) return;
            if (dodge_check_timeout_id != 0) return;
            dodge_check_timeout_id = Timeout.add(50, () => {
                dodge_check_timeout_id = 0;
                run_dodge_check();
                return false;
            });
        }

        private void run_dodge_check() {
            if (!dodge_windows) {
                set_dodge_hiding(false);
                return;
            }

            var dock_rect = get_dock_resting_rect();
            var monitor = get_dock_monitor();
            if (monitor == null) { set_dodge_hiding(false); return; }
            var mon_geo = monitor.get_geometry();

            foreach (var window in wm.get_windows()) {
                // Skip non-application windows (desktop, docks, panels, menus)
                var wtype = window.get_window_type();
                if (wtype != Wnck.WindowType.NORMAL &&
                    wtype != Wnck.WindowType.DIALOG &&
                    wtype != Wnck.WindowType.UTILITY) continue;

                // Skip minimized windows — not visible on screen
                if (window.is_minimized()) continue;

                // Skip Dokku's own windows
                string? cg = window.get_class_group_name();
                if (cg != null && cg.down() == "org.dokku.app") continue;

                // Check if window is on the same monitor
                int wx, wy, ww, wh;
                window.get_geometry(out wx, out wy, out ww, out wh);
                int wcx = wx + ww / 2;
                int wcy = wy + wh / 2;
                if (wcx < mon_geo.x || wcx >= mon_geo.x + mon_geo.width ||
                    wcy < mon_geo.y || wcy >= mon_geo.y + mon_geo.height) {
                    continue;
                }

                // Maximized window on this monitor → dodge
                if (window.is_maximized()) {
                    set_dodge_hiding(true);
                    return;
                }

                // Check rectangle intersection with dock
                if (wx < dock_rect.x + dock_rect.width &&
                    wx + ww > dock_rect.x &&
                    wy < dock_rect.y + dock_rect.height &&
                    wy + wh > dock_rect.y) {
                    set_dodge_hiding(true);
                    return;
                }
            }

            set_dodge_hiding(false);
        }

        private void set_dodge_hiding(bool should_hide) {
            if (should_hide == dodge_hiding) return;
            dodge_hiding = should_hide;

            if (use_layer_shell) {
                GtkLayerShell.set_exclusive_zone(this, (auto_hide || dodge_hiding) ? 0 : base_height);
            }

            if (hovering) return;

            if (should_hide && !hidden) {
                hidden = true;
                animate_slide(1.0);
            } else if (!should_hide && hidden && !auto_hide) {
                hidden = false;
                animate_slide(0.0);
            }
        }

        private void schedule_redraw() {
            if (!draw_queued) {
                draw_queued = true;
                Idle.add(() => {
                    draw_queued = false;
                    queue_draw();
                    return false;
                });
            }
        }

        private void update_running_apps() {
            var windows = wm.get_windows();

            // Snapshot which items were running before this update
            var was_running = new HashTable<string, bool>(str_hash, str_equal);
            foreach (var item in items) {
                if (!item.is_plugin && !item.is_launcher && item.running) {
                    was_running.set(item.id, true);
                }
                if (!item.is_plugin && !item.is_launcher) {
                    item.running = false;
                    item.windows = new List<weak Wnck.Window>();
                }
            }

            foreach (var window in windows) {
                var app = app_manager.find_by_window(window);
                if (app == null) continue;

                bool found = false;
                foreach (var item in items) {
                    if (item.is_launcher || item.is_plugin) continue;
                    if (item.id == app.id) {
                        item.running = true;
                        item.windows.append(window);
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    var item = new DockItem(app.id, app.name, app.icon);
                    item.desktop_file = app.desktop_file;
                    item.running = true;
                    item.windows.append(window);
                    string? custom_icon = config.get_custom_icon(app.id);
                    if (custom_icon != null) item.icon_name = custom_icon;
                    int sep_idx = find_separator_index();
                    if (sep_idx >= 0) items.insert(item, sep_idx);
                    else items.append(item);
                }
            }

            var to_remove = new List<DockItem>();
            foreach (var item in items) {
                if (!item.pinned && !item.running && !item.is_plugin && !item.is_launcher)
                    to_remove.append(item);
            }
            foreach (var item in to_remove) items.remove(item);

            // Bounce any app that just became running (newly launched)
            // Skip on initial load — these apps were already running before the dock started
            if (initial_load_done) {
                foreach (var item in items) {
                    if (item.running && !was_running.contains(item.id)) {
                        trigger_bounce(item.id, true);
                    }
                }
            } else {
                initial_load_done = true;
            }

            position_dock();
            schedule_redraw();
        }

        private int find_separator_index() {
            int i = 0;
            foreach (var item in items) {
                if (item.is_separator) return i;
                i++;
            }
            return -1;
        }

        private bool on_draw(Cairo.Context cr) {
            cr.set_operator(Cairo.Operator.SOURCE);
            cr.set_source_rgba(0, 0, 0, 0);
            cr.paint();
            cr.set_operator(Cairo.Operator.OVER);

            int n = (int)items.length();
            int width = get_allocated_width();
            int height = get_allocated_height();
            int container = is_vertical ? height : width;
            if (n != layout_scales_len) {
                layout_scales = new double[n];
                layout_scales_len = n;
            }
            double dock_dim;

            compute_layout(container, layout_scales, out dock_dim);

            // Sync blur background to the current dock_dim — this makes the
            // blur area grow/shrink dynamically during magnification and
            // immediately reflect item add/remove without waiting for a
            // full reposition cycle.
            if (blur_bg != null) {
                int dx, dy;
                get_position(out dx, out dy);
                sync_blur_bg(dx, dy, width, height, dock_dim);
            }

            draw_dock_background(cr, dock_dim);
            draw_items_with_layout(cr, width, height, layout_scales, dock_dim);

            update_input_shape(dock_dim);

            return false;
        }

        private void update_input_shape(double dock_dim) {
            var window = get_window();
            if (window == null) return;

            if (auto_hide || dodge_hiding) {
                window.input_shape_combine_region(null, 0, 0);
                return;
            }

            int width = get_allocated_width();
            int height = get_allocated_height();
            Cairo.RectangleInt rect;

            if (dock_position == "top") {
                rect = { (int)((width - dock_dim) / 2.0), 0, (int)dock_dim, icon_area_height + 2 };
            } else if (dock_position == "left") {
                rect = { 0, (int)((height - dock_dim) / 2.0), icon_area_height + 2, (int)dock_dim };
            } else if (dock_position == "right") {
                rect = { width - icon_area_height - 2, (int)((height - dock_dim) / 2.0), icon_area_height + 2, (int)dock_dim };
            } else { // bottom
                rect = { (int)((width - dock_dim) / 2.0), height - icon_area_height - 2, (int)dock_dim, icon_area_height + 2 };
            }

            var region = new Cairo.Region.rectangle(rect);
            window.input_shape_combine_region(region, 0, 0);
        }

        private void compute_layout(int container_size, double[] scales, out double dock_width) {
            double mouse_pos = is_vertical ? mouse_y : mouse_x;

            // Calculate base dimension and positions for scale calculation
            double base_dim = 0;
            int i = 0;
            foreach (var item in items) {
                double wf = item.dock_width_factor;
                if (is_vertical && item.is_media_widget) wf = 1.0;
                base_dim += item.is_separator ? (18 + renderer.spacing) :
                    (renderer.icon_size * wf + renderer.spacing);
                i++;
            }

            double base_offset = (container_size - base_dim) / 2.0;
            double pos = base_offset;
            i = 0;
            foreach (var item in items) {
                double wf = item.dock_width_factor;
                if (is_vertical && item.is_media_widget) wf = 1.0;
                double item_len = item.is_separator ? (18 + renderer.spacing) :
                    (renderer.icon_size * wf + renderer.spacing);
                double center = pos + item_len / 2.0;
                if (item.is_separator || item.is_launcher || item.is_media_widget) {
                    scales[i] = 1.0;
                } else {
                    double dist = hovering ? Math.fabs(mouse_pos - center) : 1000;
                    scales[i] = renderer.calculate_scale(dist, mouse_pos, hovering);
                }
                pos += item_len;
                i++;
            }

            // Calculate actual width with current scales
            double actual_width = 0;
            double gap_width = renderer.spacing * 2;
            int active_gap = drop_insert_index >= 0 ? drop_insert_index :
                (is_reordering ? reorder_insert_index : -1);
            i = 0;
            foreach (var item in items) {
                double wf = item.dock_width_factor;
                if (is_vertical && item.is_media_widget) wf = 1.0;
                if (active_gap >= 0 && i == active_gap) {
                    if (!is_reordering || i != drag_index)
                        actual_width += gap_width;
                }
                actual_width += item.is_separator ? (18 + renderer.spacing) :
                    (renderer.icon_size * wf * scales[i] + renderer.spacing);
                i++;
            }
            if (active_gap >= 0 && active_gap >= (int)items.length()) {
                actual_width += gap_width;
            }
            dock_width = actual_width + dock_padding * 2;
        }

        private bool is_light_theme() {
            return current_theme != null && current_theme.is_light();
        }

        private void draw_rounded_rect(Cairo.Context cr, double x, double y,
                                        double w, double h, double radius) {
            DockRenderer.draw_rounded_rect(cr, x, y, w, h, radius);
        }

        private void draw_dock_background(Cairo.Context cr, double dock_dim) {
            int width = get_allocated_width();
            int height = get_allocated_height();
            double margin = 2;
            double theme_radius = current_theme != null ? current_theme.corner_radius : 16;
            double radius = rounded_corners ? theme_radius : 0;

            double x, y, w, h;
            if (dock_position == "top") {
                w = dock_dim - margin * 2; h = (double)icon_area_height;
                x = (width - dock_dim) / 2.0 + margin; y = margin;
            } else if (dock_position == "left") {
                w = (double)icon_area_height; h = dock_dim - margin * 2;
                x = margin; y = (height - dock_dim) / 2.0 + margin;
            } else if (dock_position == "right") {
                w = (double)icon_area_height; h = dock_dim - margin * 2;
                x = width - icon_area_height - margin; y = (height - dock_dim) / 2.0 + margin;
            } else { // bottom
                w = dock_dim - margin * 2; h = (double)icon_area_height;
                x = (width - dock_dim) / 2.0 + margin; y = height - icon_area_height - margin;
            }

            bool light = is_light_theme();

            // Outer shadow — soft dark glow behind the dock for depth
            if (radius > 0) {
                double shadow_alpha = light ? 0.10 : 0.20;
                draw_rounded_rect(cr, x - 1, y + 1, w + 2, h + 1, radius + 2);
                cr.set_source_rgba(0, 0, 0, shadow_alpha * dock_opacity);
                cr.fill();
            }

            // --- Background fill ---
            draw_rounded_rect(cr, x, y, w, h, radius);
            double fill_alpha = blur_enabled ? dock_opacity * 0.45 : dock_opacity;
            if (current_theme != null)
                cr.set_source_rgba(current_theme.bg_red, current_theme.bg_green,
                                   current_theme.bg_blue, fill_alpha);
            else
                cr.set_source_rgba(0.12, 0.12, 0.12, fill_alpha);
            cr.fill();

            // --- Specular highlight + border ---
            if (radius > 0) {
                double bw = 1.5;
                double inset = bw / 2.0;
                draw_rounded_rect(cr, x + inset, y + inset, w - bw, h - bw, radius - inset);
                if (light) {
                    cr.set_source_rgba(1, 1, 1, 0.55 * dock_opacity);
                } else {
                    cr.set_source_rgba(1, 1, 1, 0.18 * dock_opacity);
                }
                cr.set_line_width(bw);
                cr.stroke();

                // Top edge glint
                cr.save();
                draw_rounded_rect(cr, x, y, w, h, radius);
                cr.clip();
                if (light) {
                    cr.move_to(x + radius, y + 0.5);
                    cr.line_to(x + w - radius, y + 0.5);
                    cr.set_source_rgba(1, 1, 1, 0.70 * dock_opacity);
                } else {
                    cr.move_to(x + radius, y + 0.5);
                    cr.line_to(x + w - radius, y + 0.5);
                    cr.set_source_rgba(1, 1, 1, 0.25 * dock_opacity);
                }
                cr.set_line_width(1);
                cr.stroke();
                cr.restore();
            } else {
                draw_rounded_rect(cr, x, y, w, h, 0);
                if (current_theme != null)
                    cr.set_source_rgba(current_theme.border_red, current_theme.border_green,
                                       current_theme.border_blue, current_theme.border_alpha * dock_opacity);
                else
                    cr.set_source_rgba(1, 1, 1, 0.08 * dock_opacity);
                cr.set_line_width(1);
                cr.stroke();
            }
        }

        /**
         * Set X11 compositor hints on the dock window:
         * - _DOKKU_WINDOW = 1: identifies this as the dock window for picom
         *   rule matching (works reliably for override_redirect windows where
         *   class_g matching may fail)
         * - _COMPTON_SHADOW = 0: disable compositor shadow
         * - _DOKKU_BLUR: set/removed to toggle blur; picom rule matches on
         *   _DOKKU_BLUR@ existence and re-evaluates via PropertyNotify
         */
        private void update_compositor_hints() {
            var gdk_window = get_window();
            if (gdk_window == null) return;

            var display = gdk_window.get_display();
            if (!(display is Gdk.X11.Display)) return;

            unowned X.Display xdisplay = ((Gdk.X11.Display) display).get_xdisplay();
            X.Window xid = ((Gdk.X11.Window) gdk_window).get_xid();

            // Identify this window as the Dokku dock — picom rules match on
            // this property instead of class_g (which is unreliable for
            // override_redirect windows)
            X.Atom dock_atom = xdisplay.intern_atom("_DOKKU_WINDOW", false);
            uchar[] dock_val = { 1, 0, 0, 0 };
            xdisplay.change_property(xid, dock_atom, X.XA_CARDINAL, 32,
                                      X.PropMode.Replace, dock_val, 1);

            // Disable compositor shadow
            X.Atom shadow_atom = xdisplay.intern_atom("_COMPTON_SHADOW", false);
            uchar[] shadow_off = { 0, 0, 0, 0 };
            xdisplay.change_property(xid, shadow_atom, X.XA_CARDINAL, 32,
                                      X.PropMode.Replace, shadow_off, 1);

            // Blur is handled by the separate blur_bg window (not the main dock).
            // Always ensure _DOKKU_BLUR is removed from the main dock so picom
            // never blurs behind it (which would cause a rectangle artifact over
            // the full window area including the magnification zone).
            X.Atom blur_atom = xdisplay.intern_atom("_DOKKU_BLUR", false);
            xdisplay.delete_property(xid, blur_atom);

            xdisplay.flush();
        }

        /**
         * Compute the dock length at rest (no magnification, all scales = 1.0).
         * This gives a stable value that doesn't change during hover,
         * matching the dock background size when no icons are magnified.
         */
        private double calculate_rest_dock_length() {
            double total = dock_padding * 2;
            foreach (var item in items) {
                double wf = item.dock_width_factor;
                if (is_vertical && item.is_media_widget) wf = 1.0;
                total += item.is_separator ? (18 + renderer.spacing) :
                    (renderer.icon_size * wf + renderer.spacing);
            }
            return Math.fmax(total, 200);
        }

        /**
         * Two-window blur approach:
         *
         * Problem: A single bounding shape cannot both (a) restrict picom blur
         * to the dock capsule and (b) allow magnified icons to extend above it.
         * Extending the shape for magnification causes picom to blur that area,
         * creating a visible rectangle artifact.
         *
         * Solution: Use a SEPARATE transparent popup window (blur_bg) positioned
         * behind the main dock at the capsule location. This window:
         * - Has _DOKKU_BLUR atom → picom blurs behind it
         * - Has a rounded-rect bounding shape matching the capsule
         * - Is transparent → blurred desktop shows through
         *
         * The main dock window has NO bounding shape and NO blur atom, so:
         * - Magnified icons extend freely (no clipping)
         * - Picom does NOT blur behind the main dock
         * - The semi-transparent dock background lets the blurred desktop
         *   (from the blur_bg below) show through → frosted glass effect
         *
         * Compositing order: desktop → blur (capsule area) → blur_bg → main dock
         */
        private void ensure_blur_bg() {
            if (blur_enabled && blur_bg == null && !use_layer_shell) {
                create_blur_bg();
            } else if ((!blur_enabled || use_layer_shell) && blur_bg != null) {
                blur_bg.destroy();
                blur_bg = null;
                blur_shape_w = 0;
                blur_shape_h = 0;
                blur_shape_radius = -1;
            }
            // Clear any leftover bounding shape from the main window
            var gdk_window = get_window();
            if (gdk_window != null) {
                gdk_window.shape_combine_region(null, 0, 0);
            }
        }

        private void create_blur_bg() {
            blur_bg = new Gtk.Window(Gtk.WindowType.POPUP);
            var visual = blur_bg.get_screen().get_rgba_visual();
            if (visual != null) blur_bg.set_visual(visual);
            blur_bg.set_app_paintable(true);
            blur_bg.set_decorated(false);
            blur_bg.set_skip_taskbar_hint(true);
            blur_bg.set_skip_pager_hint(true);
            blur_bg.set_accept_focus(false);
            blur_bg.set_type_hint(Gdk.WindowTypeHint.DOCK);

            blur_bg.draw.connect((cr) => {
                // Transparent — compositor blur shows through this window.
                cr.set_operator(Cairo.Operator.SOURCE);
                cr.set_source_rgba(0, 0, 0, 0);
                cr.paint();
                return true;
            });

            blur_bg.realize.connect(() => {
                if (blur_bg == null) return;
                var bgw = blur_bg.get_window();
                if (bgw == null) return;
                bgw.set_override_redirect(true);
                set_blur_bg_hints(bgw);
                apply_blur_bg_shape();
            });

            blur_bg.map.connect(() => {
                if (blur_bg == null) return;
                var bgw = blur_bg.get_window();
                if (bgw == null) return;
                set_blur_bg_hints(bgw);
                apply_blur_bg_shape();
                // Main dock must stay above the blur background
                var main_w = get_window();
                if (main_w != null) main_w.raise();
            });

            blur_bg.size_allocate.connect(() => {
                apply_blur_bg_shape();
            });

            blur_bg.set_default_size(1, 1);
            blur_bg.show_all();
            // Trigger immediate position sync
            apply_dock_position();
        }

        /**
         * Set X11 atoms on the blur background window:
         * _DOKKU_WINDOW = 1, _COMPTON_SHADOW = 0, _DOKKU_BLUR = 1
         */
        private void set_blur_bg_hints(Gdk.Window gdk_window) {
            var display = gdk_window.get_display();
            if (!(display is Gdk.X11.Display)) return;

            unowned X.Display xdisplay = ((Gdk.X11.Display) display).get_xdisplay();
            X.Window xid = ((Gdk.X11.Window) gdk_window).get_xid();

            X.Atom dock_atom = xdisplay.intern_atom("_DOKKU_WINDOW", false);
            uchar[] dock_val = { 1, 0, 0, 0 };
            xdisplay.change_property(xid, dock_atom, X.XA_CARDINAL, 32,
                                      X.PropMode.Replace, dock_val, 1);

            X.Atom shadow_atom = xdisplay.intern_atom("_COMPTON_SHADOW", false);
            uchar[] shadow_off = { 0, 0, 0, 0 };
            xdisplay.change_property(xid, shadow_atom, X.XA_CARDINAL, 32,
                                      X.PropMode.Replace, shadow_off, 1);

            X.Atom blur_atom = xdisplay.intern_atom("_DOKKU_BLUR", false);
            uchar[] blur_on = { 1, 0, 0, 0 };
            xdisplay.change_property(xid, blur_atom, X.XA_CARDINAL, 32,
                                      X.PropMode.Replace, blur_on, 1);

            xdisplay.flush();
        }

        /**
         * Apply a rounded-rectangle bounding shape to the blur background
         * window so picom only blurs behind the dock capsule shape.
         */
        private void apply_blur_bg_shape() {
            if (blur_bg == null) return;
            var bgw = blur_bg.get_window();
            if (bgw == null) return;

            int w = blur_bg.get_allocated_width();
            int h = blur_bg.get_allocated_height();
            if (w <= 1 || h <= 1) return;

            double theme_radius = current_theme != null ? current_theme.corner_radius : 16;
            double radius = rounded_corners ? theme_radius : 0;

            // Skip if dimensions and radius haven't changed
            if (w == blur_shape_w && h == blur_shape_h && radius == blur_shape_radius) return;
            blur_shape_w = w;
            blur_shape_h = h;
            blur_shape_radius = radius;

            var surface = new Cairo.ImageSurface(Cairo.Format.A8, w, h);
            var cr = new Cairo.Context(surface);
            cr.set_operator(Cairo.Operator.SOURCE);
            cr.set_source_rgba(0, 0, 0, 0);
            cr.paint();
            cr.set_source_rgba(0, 0, 0, 1);
            draw_rounded_rect(cr, 0, 0, w, h, radius);
            cr.fill();
            surface.flush();

            var region = Gdk.cairo_region_create_from_surface(surface);
            bgw.shape_combine_region(region, 0, 0);
        }

        /**
         * Position and resize the blur background window to match the dock
         * capsule area. Accepts the actual dock_dim (which changes during
         * magnification) so the blur area grows/shrinks with the capsule.
         *
         * Called from:
         * - apply_dock_position(): uses rest dock length (for reposition/resize)
         * - on_draw(): uses the live dock_dim from compute_layout() so the
         *   blur follows magnification and reflects item add/remove immediately
         */
        private void sync_blur_bg(int dock_x, int dock_y, int dock_w, int dock_h,
                                   double dock_dim = -1) {
            if (blur_bg == null) return;
            if (dock_dim < 0) dock_dim = calculate_rest_dock_length();

            double margin = 2;
            int bg_x, bg_y, bg_w, bg_h;

            if (dock_position == "bottom") {
                bg_w = (int)(dock_dim - margin * 2);
                bg_h = icon_area_height;
                bg_x = dock_x + (dock_w - (int)dock_dim) / 2 + (int)margin;
                bg_y = dock_y + dock_h - icon_area_height - (int)margin;
            } else if (dock_position == "top") {
                bg_w = (int)(dock_dim - margin * 2);
                bg_h = icon_area_height;
                bg_x = dock_x + (dock_w - (int)dock_dim) / 2 + (int)margin;
                bg_y = dock_y + (int)margin;
            } else if (dock_position == "left") {
                bg_w = icon_area_height;
                bg_h = (int)(dock_dim - margin * 2);
                bg_x = dock_x + (int)margin;
                bg_y = dock_y + (dock_h - (int)dock_dim) / 2 + (int)margin;
            } else { // right
                bg_w = icon_area_height;
                bg_h = (int)(dock_dim - margin * 2);
                bg_x = dock_x + dock_w - icon_area_height - (int)margin;
                bg_y = dock_y + (dock_h - (int)dock_dim) / 2 + (int)margin;
            }

            bg_w = int.max(bg_w, 1);
            bg_h = int.max(bg_h, 1);

            // Only call resize/move if values actually changed — avoids
            // recreating the X11 bounding shape 60 times/sec during hover
            int cur_w = blur_bg.get_allocated_width();
            int cur_h = blur_bg.get_allocated_height();
            int cur_x, cur_y;
            blur_bg.get_position(out cur_x, out cur_y);

            if (cur_w != bg_w || cur_h != bg_h) {
                blur_bg.resize(bg_w, bg_h);
            }
            if (cur_x != bg_x || cur_y != bg_y) {
                blur_bg.move(bg_x, bg_y);
            }
        }

        private void draw_items_with_layout(Cairo.Context cr, int width, int height, double[] scales, double dock_dim) {
            double dock_bg_margin = 2;

            // cross_center = center of dock background on the cross axis (perpendicular to item flow)
            // rest_center = slightly offset for indicator dots
            double cross_center, rest_center;
            if (dock_position == "bottom") {
                cross_center = height - dock_bg_margin - icon_area_height / 2.0;
                rest_center = cross_center - 2;
            } else if (dock_position == "top") {
                cross_center = dock_bg_margin + icon_area_height / 2.0;
                rest_center = cross_center + 2;
            } else if (dock_position == "left") {
                cross_center = dock_bg_margin + icon_area_height / 2.0;
                rest_center = cross_center + 2;
            } else { // right
                cross_center = width - dock_bg_margin - icon_area_height / 2.0;
                rest_center = cross_center - 2;
            }

            double actual_dim = dock_dim - dock_padding * 2;
            int container = is_vertical ? height : width;
            double start_pos = (container - actual_dim) / 2.0;
            double pos = start_pos;
            double gap_width = renderer.spacing * 2;
            double mouse_coord = is_vertical ? mouse_y : mouse_x;
            // Compute once outside the loop — this value is invariant per frame
            int active_gap_index = drop_insert_index >= 0 ? drop_insert_index :
                (is_reordering && !drag_removing ? reorder_insert_index : -1);
            int i = 0;

            foreach (var item in items) {
                if (active_gap_index >= 0 && i == active_gap_index) {
                    if (!is_reordering || i != drag_index) {
                        draw_gap_indicator(cr, pos + gap_width / 2.0, rest_center);
                        pos += gap_width;
                    }
                }

                if (is_reordering && i == drag_index) {
                    double skip_wf = item.dock_width_factor;
                    if (is_vertical && item.is_media_widget) skip_wf = 1.0;
                    double skip_w = item.is_separator ? (18 + renderer.spacing) :
                        (renderer.icon_size * scales[i] * skip_wf + renderer.spacing);
                    pos += skip_w;
                    i++;
                    continue;
                }

                double sz = renderer.icon_size * scales[i];
                double main_pos, item_len;
                double item_wf = item.dock_width_factor;
                if (is_vertical && item.is_media_widget) item_wf = 1.0;
                if (item.is_separator) {
                    item_len = 18 + renderer.spacing;
                    // Center the line between adjacent icons: the preceding item
                    // contributes renderer.spacing of trailing gap, so offset the
                    // line toward the start to compensate.
                    main_pos = pos + (item_len - renderer.spacing) / 2.0;
                } else {
                    double eff = sz * item_wf;
                    main_pos = pos + eff / 2.0;
                    item_len = eff + renderer.spacing;
                }

                double mag_offset = (sz - renderer.icon_size) / 2.0;
                double x, y;
                if (is_vertical) {
                    y = main_pos;
                    if (dock_position == "left")
                        x = rest_center + mag_offset;
                    else
                        x = rest_center - mag_offset;
                } else {
                    x = main_pos;
                    if (dock_position == "bottom")
                        y = rest_center - mag_offset;
                    else
                        y = rest_center + mag_offset;
                }

                renderer.draw_item(cr, item, x, y, scales[i], hovering && i == hovered_index, mouse_coord, dock_position);
                pos += item_len;
                i++;
            }

            // Gap at end (reuses active_gap_index computed before the loop)
            if (active_gap_index >= 0 && active_gap_index >= (int)items.length()) {
                draw_gap_indicator(cr, pos + gap_width / 2.0, rest_center);
            }

            // Floating icon during reorder
            if (is_reordering && drag_index >= 0) {
                var dragged_item = items.nth_data(drag_index);
                if (dragged_item != null && !drag_removing) {
                    // Normal reorder: icon follows main axis only
                    // (drag_removing is handled by the floating popup window)
                    double fx, fy;
                    if (is_vertical) {
                        fy = reorder_mouse_x;
                        fx = rest_center;
                    } else {
                        fx = reorder_mouse_x;
                        fy = rest_center - renderer.icon_size * 0.1;
                    }
                    cr.save();
                    cr.push_group();
                    renderer.draw_item(cr, dragged_item, fx, fy, 1.05, false, -1, dock_position);
                    cr.pop_group_to_source();
                    cr.paint_with_alpha(0.85);
                    cr.restore();
                }
            }

        }

        // --- Drag-to-remove floating popup ---
        // A small transparent overlay window that follows the cursor across the
        // entire screen, so the icon stays visible outside the dock bounds.

        private void show_drag_float_popup(DockItem item) {
            // Cancel any running poof before starting a new drag
            destroy_drag_float_popup();

            // Cache icon pixbuf
            string icon_name = item.icon_name;
            if (icon_name == null || icon_name == "") icon_name = "application-x-executable";
            try {
                var itheme = Gtk.IconTheme.get_default();
                drag_float_icon = itheme.load_icon(icon_name, renderer.icon_size,
                    Gtk.IconLookupFlags.FORCE_SIZE);
            } catch (Error e) {
                try {
                    var itheme = Gtk.IconTheme.get_default();
                    drag_float_icon = itheme.load_icon("application-x-executable",
                        renderer.icon_size, Gtk.IconLookupFlags.FORCE_SIZE);
                } catch (Error e2) {
                    drag_float_icon = null;
                    drag_removing = false;
                    return;
                }
            }

            drag_float_poofing = false;

            // Popup: large enough for the scaled icon + "Remove" label
            int popup_size = (int)(renderer.icon_size * 1.8);
            drag_float_popup = new Gtk.Window(Gtk.WindowType.POPUP);
            drag_float_popup.set_type_hint(Gdk.WindowTypeHint.DND);
            drag_float_popup.set_skip_taskbar_hint(true);
            drag_float_popup.set_skip_pager_hint(true);
            drag_float_popup.set_decorated(false);
            drag_float_popup.set_resizable(false);
            var vis = drag_float_popup.get_screen().get_rgba_visual();
            if (vis != null) drag_float_popup.set_visual(vis);
            drag_float_popup.set_app_paintable(true);
            drag_float_popup.set_size_request(popup_size, popup_size);
            drag_float_popup.resize(popup_size, popup_size);

            // Cache theme state once for the draw handler
            bool light = is_light_theme();

            // Single draw handler: switches between drag and poof modes
            drag_float_popup.draw.connect((cr) => {
                cr.set_operator(Cairo.Operator.SOURCE);
                cr.set_source_rgba(0, 0, 0, 0);
                cr.paint();
                cr.set_operator(Cairo.Operator.OVER);
                if (drag_float_icon == null) return false;

                var popup = drag_float_popup;
                if (popup == null) return false;
                int w = popup.get_allocated_width();
                int h = popup.get_allocated_height();
                double icon_w = drag_float_icon.get_width();
                double icon_h = drag_float_icon.get_height();

                if (drag_float_poofing) {
                    // Poof mode: scale up + fade out
                    int64 now = GLib.get_monotonic_time() / 1000;
                    double t = ((double)(now - poof_start_time)) / POOF_DURATION_MS;
                    if (t >= 1.0) return false;

                    double ease_t = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t);
                    double anim_scale = 1.0 + 0.5 * ease_t;
                    double alpha = 1.0 - ease_t;

                    cr.save();
                    cr.translate(w / 2.0, h / 2.0);
                    cr.scale(anim_scale, anim_scale);
                    cr.translate(-icon_w / 2.0, -icon_h / 2.0);
                    Gdk.cairo_set_source_pixbuf(cr, drag_float_icon, 0, 0);
                    cr.paint_with_alpha(alpha);
                    cr.restore();
                } else {
                    // Drag mode: shrink + fade + "Remove" label
                    double away = compute_away_distance(drag_mouse_cross);
                    double remove_t = ((away - REMOVE_THRESHOLD) / REMOVE_THRESHOLD).clamp(0, 1);
                    double scale = 1.05 - 0.45 * remove_t;
                    double alpha = 0.85 - 0.45 * remove_t;

                    cr.save();
                    cr.translate(w / 2.0, h / 2.0);
                    cr.scale(scale, scale);
                    cr.translate(-icon_w / 2.0, -icon_h / 2.0);
                    Gdk.cairo_set_source_pixbuf(cr, drag_float_icon, 0, 0);
                    cr.paint_with_alpha(alpha);
                    cr.restore();

                    // "Remove" label above the icon
                    cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
                    cr.set_font_size(11);
                    Cairo.TextExtents te;
                    cr.text_extents("Remove", out te);
                    double lx = (w - te.width) / 2.0;
                    double ly = (h / 2.0) - (icon_h * scale / 2.0) - 6;

                    cr.move_to(lx + 1, ly + 1);
                    cr.set_source_rgba(0, 0, 0, 0.6);
                    cr.show_text("Remove");
                    cr.move_to(lx, ly);
                    if (light) {
                        cr.set_source_rgba(0.15, 0.15, 0.15, 0.9);
                    } else {
                        cr.set_source_rgba(1, 1, 1, 0.9);
                    }
                    cr.show_text("Remove");
                }

                return false;
            });

            drag_float_popup.show_all();
            // X11: override_redirect + suppress compositor shadow
            var popup_gdk = drag_float_popup.get_window();
            if (!use_layer_shell && popup_gdk != null) {
                popup_gdk.set_override_redirect(true);
                var display = popup_gdk.get_display();
                if (display is Gdk.X11.Display) {
                    unowned X.Display xd = ((Gdk.X11.Display) display).get_xdisplay();
                    X.Window xid = ((Gdk.X11.Window) popup_gdk).get_xid();
                    X.Atom dock_atom = xd.intern_atom("_DOKKU_WINDOW", false);
                    uchar[] one = { 1, 0, 0, 0 };
                    xd.change_property(xid, dock_atom, X.XA_CARDINAL, 32,
                                       X.PropMode.Replace, one, 1);
                    X.Atom shadow_atom = xd.intern_atom("_COMPTON_SHADOW", false);
                    uchar[] zero = { 0, 0, 0, 0 };
                    xd.change_property(xid, shadow_atom, X.XA_CARDINAL, 32,
                                       X.PropMode.Replace, zero, 1);
                }
            }
        }

        private void update_drag_float_popup(double root_x, double root_y) {
            if (drag_float_popup == null) return;
            int popup_size = drag_float_popup.get_allocated_width();
            int px = (int)(root_x - popup_size / 2.0);
            int py = (int)(root_y - popup_size / 2.0);
            drag_float_popup.move(px, py);
            drag_float_popup.queue_draw();
        }

        private void destroy_drag_float_popup() {
            drag_float_poofing = false;
            if (drag_float_popup != null) {
                drag_float_popup.destroy();
                drag_float_popup = null;
            }
            drag_float_icon = null;
        }

        // Transition the floating popup into poof mode (scale-up + fade-out)
        private void start_poof_on_popup() {
            if (drag_float_popup == null || drag_float_icon == null) {
                destroy_drag_float_popup();
                return;
            }
            drag_float_poofing = true;
            poof_start_time = GLib.get_monotonic_time() / 1000;

            // Capture start time locally so a hypothetical second poof
            // can't corrupt this animation's timeline
            int64 local_start = poof_start_time;

            drag_float_popup.add_tick_callback((widget, frame_clock) => {
                int64 now = GLib.get_monotonic_time() / 1000;
                double t = ((double)(now - local_start)) / POOF_DURATION_MS;
                if (t >= 1.0) {
                    destroy_drag_float_popup();
                    return false;
                }
                if (drag_float_popup != null) {
                    drag_float_popup.queue_draw();
                }
                return true;
            });
        }

        private void draw_gap_indicator(Cairo.Context cr, double main_pos, double cross_center) {
            if (current_theme != null) {
                cr.set_source_rgba(current_theme.indicator_red, current_theme.indicator_green,
                                   current_theme.indicator_blue, 0.55);
            } else if (is_light_theme()) {
                cr.set_source_rgba(0.15, 0.15, 0.15, 0.45);
            } else {
                cr.set_source_rgba(1, 1, 1, 0.45);
            }
            cr.set_line_width(2);
            cr.set_line_cap(Cairo.LineCap.ROUND);
            double half = renderer.icon_size * 0.35;
            if (is_vertical) {
                cr.move_to(cross_center - half, main_pos);
                cr.line_to(cross_center + half, main_pos);
            } else {
                cr.move_to(main_pos, cross_center - half);
                cr.line_to(main_pos, cross_center + half);
            }
            cr.stroke();
        }

        private bool on_motion(Gdk.EventMotion event) {
            mouse_x = event.x;
            mouse_y = event.y;
            double main_coord = is_vertical ? event.y : event.x;
            hovered_index = get_item_at(main_coord);

            // Start reorder if dragging past threshold
            if (drag_index >= 0 && !is_reordering) {
                if (Math.fabs(main_coord - drag_start_x) > DRAG_THRESHOLD) {
                    var drag_item = items.nth_data(drag_index);
                    if (drag_item != null && !drag_item.is_launcher && !drag_item.is_separator) {
                        // Grab pointer so we receive events outside the window
                        var seat = get_display().get_default_seat();
                        var status = seat.grab(get_window(), Gdk.SeatCapabilities.POINTER, false, null, null, null);
                        if (status == Gdk.GrabStatus.SUCCESS) {
                            is_reordering = true;
                        }
                    }
                }
            }

            if (is_reordering) {
                reorder_mouse_x = main_coord;
                double cross_coord = is_vertical ? event.x : event.y;
                drag_mouse_cross = cross_coord;

                // Check if dragging away from dock (perpendicular distance)
                var drag_item = items.nth_data(drag_index);
                bool can_remove = drag_item != null && drag_item.pinned
                    && !drag_item.is_launcher && !drag_item.is_separator
                    && !drag_item.is_plugin;
                bool was_removing = drag_removing;
                if (can_remove) {
                    double away_dist = compute_away_distance(cross_coord);
                    drag_removing = away_dist > REMOVE_THRESHOLD;
                } else {
                    drag_removing = false;
                }

                if (drag_removing) {
                    // Show/move the floating icon popup that follows the cursor
                    // across the whole screen (the dock window would clip it)
                    if (!was_removing && drag_item != null) {
                        show_drag_float_popup(drag_item);
                    }
                    if (drag_float_popup != null) {
                        update_drag_float_popup(event.x_root, event.y_root);
                    }
                } else {
                    // Back on dock — destroy popup and resume normal reorder
                    destroy_drag_float_popup();
                    reorder_insert_index = get_reorder_target_index(main_coord);
                }
            }

            // Hover popup: multi-window apps get preview, others get name tooltip
            if (hovered_index >= 0 && !is_reordering) {
                var hovered_item = items.nth_data(hovered_index);
                if (hovered_item != null && hovered_item.running && hovered_item.windows.length() > 1) {
                    // Multi-window: window preview popup after 400ms
                    if (preview_target_index != hovered_index) {
                        cancel_preview_timer();
                        dismiss_preview_popup();
                        preview_target_index = hovered_index;
                        int idx = hovered_index;
                        hover_preview_timeout_id = Timeout.add(400, () => {
                            hover_preview_timeout_id = 0;
                            show_preview_popup(idx);
                            return false;
                        });
                    } else {
                        cancel_preview_dismiss();
                    }
                } else if (hovered_item != null && !hovered_item.is_separator
                           && !hovered_item.is_media_widget) {
                    // Single/zero-window or non-running: name tooltip after 300ms
                    if (preview_target_index != hovered_index) {
                        cancel_preview_timer();
                        dismiss_preview_popup();
                        preview_target_index = hovered_index;
                        int idx = hovered_index;
                        hover_preview_timeout_id = Timeout.add(300, () => {
                            hover_preview_timeout_id = 0;
                            show_name_tooltip(idx);
                            return false;
                        });
                    } else {
                        cancel_preview_dismiss();
                    }
                } else {
                    cancel_preview_timer();
                    dismiss_preview_popup();
                }
            } else {
                cancel_preview_timer();
            }

            schedule_redraw();
            return true;
        }

        private bool on_enter(Gdk.EventCrossing event) {
            hovering = true;
            if (hide_timeout_id != 0) { Source.remove(hide_timeout_id); hide_timeout_id = 0; }
            if (launch_rehide_timeout_id != 0) { Source.remove(launch_rehide_timeout_id); launch_rehide_timeout_id = 0; }
            cancel_media_popup_dismiss();
            if ((auto_hide || dodge_hiding) && hidden) {
                hidden = false;
                animate_slide(0.0);
            }
            schedule_redraw();
            return true;
        }

        private bool on_leave(Gdk.EventCrossing event) {
            // During a pointer-grabbed reorder the cursor leaves the window
            // geometry but we keep getting events — don't reset anything.
            if (is_reordering) {
                return true;
            }

            hovering = false;
            mouse_x = -1;
            mouse_y = -1;
            hovered_index = -1;

            cancel_preview_timer();
            schedule_preview_dismiss();
            schedule_media_popup_dismiss();

            // Only hide if auto-hide or dodge-hiding is active
            if ((auto_hide || dodge_hiding) && !hidden) {
                hide_timeout_id = Timeout.add(config.get_hide_delay(), () => {
                    hidden = true;
                    animate_slide(1.0);
                    hide_timeout_id = 0;
                    return false;
                });
            }
            schedule_redraw();
            return true;
        }

        private void on_drag_data_received(Gdk.DragContext context, int x, int y,
                                           Gtk.SelectionData data, uint info, uint time) {
            var uris = data.get_uris();
            int insert_at = drop_insert_index >= 0 ? drop_insert_index : find_separator_index();

            foreach (var uri in uris) {
                if (!uri.has_suffix(".desktop")) continue;

                string path;
                try {
                    path = Filename.from_uri(uri);
                } catch (Error e) { continue; }

                var app = new AppInfo.from_desktop_file(path);
                if (app.exec == "") continue;

                // Check if already in dock
                bool exists = false;
                foreach (var item in items) {
                    if (item.id == app.id) { exists = true; break; }
                }
                if (exists) continue;

                var item = new DockItem(app.id, app.name, app.icon);
                item.desktop_file = app.desktop_file;
                item.pinned = true;

                if (insert_at >= 0) {
                    items.insert(item, insert_at);
                    insert_at++;
                } else {
                    items.append(item);
                }
            }
            drop_insert_index = -1;
            save_pinned_apps();
            position_dock();
            schedule_redraw();
            Gtk.drag_finish(context, true, false, time);
        }

        private bool on_drag_motion(Gdk.DragContext context, int x, int y, uint time) {
            Gdk.drag_status(context, Gdk.DragAction.COPY, time);
            int new_index = get_drop_index(is_vertical ? (double)y : (double)x);
            if (new_index != drop_insert_index) {
                drop_insert_index = new_index;
                position_dock();
                schedule_redraw();
            }
            return true;
        }

        private void on_drag_leave(Gdk.DragContext context, uint time) {
            if (drop_insert_index >= 0) {
                drop_insert_index = -1;
                position_dock();
                schedule_redraw();
            }
        }

        private int get_drop_index(double x) {
            int sep_idx = find_separator_index();
            int max_insert = sep_idx >= 0 ? sep_idx : (int)items.length();
            int min_insert = 1;  // After launcher

            int width = is_vertical ? get_allocated_height() : get_allocated_width();
            double total_width = 0;
            double gap_width = renderer.spacing * 2;

            foreach (var item in items) {
                total_width += item.is_separator ? SEPARATOR_WIDTH :
                    (renderer.icon_size * effective_width_factor(item) + renderer.spacing);
            }
            if (drop_insert_index >= 0) total_width += gap_width;

            double pos = (width - total_width) / 2.0;
            int i = 0;
            foreach (var item in items) {
                // Cursor within existing gap → keep current index (prevents jitter)
                if (drop_insert_index >= 0 && i == drop_insert_index) {
                    if (x < pos + gap_width) return i;
                    pos += gap_width;
                }
                double w = item.is_separator ? SEPARATOR_WIDTH :
                    (renderer.icon_size * effective_width_factor(item) + renderer.spacing);
                if (i >= min_insert && i <= max_insert && x < pos + w / 2.0) {
                    return i;
                }
                pos += w;
                i++;
            }
            return max_insert;
        }

        private int get_reorder_target_index(double x) {
            int min_insert = 1;  // After launcher
            int sep_idx = find_separator_index();
            int max_insert = sep_idx >= 0 ? sep_idx : (int)items.length();

            int width = is_vertical ? get_allocated_height() : get_allocated_width();
            double total_width = 0;
            foreach (var item in items) {
                total_width += item.is_separator ? SEPARATOR_WIDTH :
                    (renderer.icon_size * effective_width_factor(item) + renderer.spacing);
            }

            double pos = (width - total_width) / 2.0;
            int i = 0;
            foreach (var item in items) {
                double w = item.is_separator ? SEPARATOR_WIDTH :
                    (renderer.icon_size * effective_width_factor(item) + renderer.spacing);
                if (i >= min_insert && i <= max_insert) {
                    if (x < pos + w / 2.0) return i;
                }
                pos += w;
                i++;
            }
            return max_insert;
        }

        // Returns how far the pointer is from the dock edge in the "away" direction.
        // Positive = moving away from screen edge; negative = still over the dock.
        // cross_coord is in widget-local coordinates (from motion_notify_event):
        //   bottom dock: y < 0 means above the dock window
        //   top dock:    y > alloc_h means below the dock window
        //   left dock:   x > alloc_w means right of the dock window
        //   right dock:  x < 0 means left of the dock window
        private double compute_away_distance(double cross_coord) {
            int alloc_w = get_allocated_width();
            int alloc_h = get_allocated_height();
            switch (dock_position) {
                case "bottom": return cross_coord < 0 ? -cross_coord : 0;
                case "top":    return cross_coord > alloc_h ? cross_coord - alloc_h : 0;
                case "left":   return cross_coord > alloc_w ? cross_coord - alloc_w : 0;
                case "right":  return cross_coord < 0 ? -cross_coord : 0;
                default:       return 0;
            }
        }

        private bool on_button_press(Gdk.EventButton event) {
            if (is_reordering) return true;  // Ignore during active drag
            double main_coord = is_vertical ? event.y : event.x;
            if (event.button == 1) {
                drag_start_x = main_coord;
                drag_index = get_item_at(main_coord);
            } else if (event.button == 3) {
                show_context_menu(event);
            }
            return true;
        }

        private bool on_button_release(Gdk.EventButton event) {
            // Always ungrab the pointer if we grabbed it
            if (is_reordering) {
                var seat = get_display().get_default_seat();
                seat.ungrab();
            }

            double main_coord = is_vertical ? event.y : event.x;
            if (event.button == 1 && drag_index >= 0) {
                if (is_reordering && drag_removing) {
                    // Drag-to-remove: unpin and animate poof
                    var item = items.nth_data(drag_index);
                    if (item != null) {
                        if (item.is_folder) {
                            config.delete_folder(item.folder_id);
                        }
                        if (item.running) {
                            // Keep in dock while running, just unpin
                            item.pinned = false;
                        } else {
                            items.remove(item);
                        }
                        // Reset drag_index before position_dock() to prevent
                        // stale index access if resize triggers a synchronous draw
                        drag_index = -1;
                        save_pinned_apps();
                        position_dock();
                        // Poof: reuse the floating popup for the dissolve animation
                        start_poof_on_popup();
                    }
                } else if (is_reordering && reorder_insert_index >= 0) {
                    var item = items.nth_data(drag_index);
                    if (item != null) {
                        items.remove(item);
                        int target = reorder_insert_index;
                        if (drag_index < reorder_insert_index) target--;
                        items.insert(item, int.max(0, target));
                        save_pinned_apps();
                    }
                } else {
                    int target = get_item_at(main_coord);
                    if (Math.fabs(main_coord - drag_start_x) < DRAG_THRESHOLD && target == drag_index) {
                        activate_item(drag_index, main_coord);
                    }
                }
            }
            drag_index = -1;
            is_reordering = false;
            reorder_insert_index = -1;
            reorder_mouse_x = -1;
            drag_removing = false;
            drag_mouse_cross = -1;
            // Destroy float popup if poof didn't claim it (e.g. normal reorder end)
            if (!drag_float_poofing) {
                destroy_drag_float_popup();
            }

            // After ungrabbing, check if cursor is actually outside the dock.
            // The on_leave was suppressed during grab, so simulate it now.
            int alloc_w = get_allocated_width();
            int alloc_h = get_allocated_height();
            if (event.x < 0 || event.x > alloc_w || event.y < 0 || event.y > alloc_h) {
                hovering = false;
                mouse_x = -1;
                mouse_y = -1;
                hovered_index = -1;
                cancel_preview_timer();
                schedule_preview_dismiss();
                schedule_media_popup_dismiss();
                if ((auto_hide || dodge_hiding) && !hidden) {
                    hide_timeout_id = Timeout.add(config.get_hide_delay(), () => {
                        hidden = true;
                        animate_slide(1.0);
                        hide_timeout_id = 0;
                        return false;
                    });
                }
            }

            schedule_redraw();
            return true;
        }

        private double effective_width_factor(DockItem item) {
            if (is_vertical && item.is_media_widget) return 1.0;
            return item.dock_width_factor;
        }

        private int get_item_at(double click_x) {
            int width = is_vertical ? get_allocated_height() : get_allocated_width();

            // Calculate total width first
            double total_width = 0;
            foreach (var item in items) {
                if (item.is_separator) {
                    total_width += SEPARATOR_WIDTH;
                } else {
                    total_width += renderer.icon_size * effective_width_factor(item) + renderer.spacing;
                }
            }

            double start_x = (width - total_width) / 2.0;
            double pos = start_x;
            int i = 0;
            foreach (var item in items) {
                double w = item.is_separator ? SEPARATOR_WIDTH :
                    (renderer.icon_size * effective_width_factor(item) + renderer.spacing);
                if (click_x >= pos && click_x < pos + w) return i;
                pos += w;
                i++;
            }
            return -1;
        }

        private void activate_item(int index, double click_x = -1) {
            var item = items.nth_data(index);
            if (item == null) return;

            if (item.is_launcher) { launcher_requested(); return; }
            if (item.is_folder) { show_folder_popup(item, index); return; }
            if (item.is_media_widget && item.plugin is MediaPlugin) {
                var mp = item.plugin as MediaPlugin;
                if (is_vertical) {
                    show_media_popup(mp, index);
                    return;
                }
                double item_start, item_w;
                get_item_bounds(index, out item_start, out item_w);
                // Compute button positions matching the renderer layout
                double widget_w = renderer.icon_size * item.dock_width_factor;
                double pad = 6;
                int ctrl_sz = 20;
                double skip_x = item_start + widget_w - pad - ctrl_sz;
                double pause_x = skip_x - 6 - ctrl_sz;
                if (click_x >= skip_x && click_x <= skip_x + ctrl_sz) {
                    mp.next();
                } else if (click_x >= pause_x && click_x <= pause_x + ctrl_sz) {
                    mp.activate();
                } else {
                    mp.activate();
                }
                return;
            }
            if (item.is_plugin && item.plugin != null) { item.plugin.activate(); return; }
            if (item.running && item.windows.length() > 1) { show_window_list(item); return; }
            if (item.running && item.windows.length() > 0) {
                wm.activate_window(item.windows.nth_data(0));
            } else {
                var app = app_manager.get_app(item.id);
                if (app != null) {
                    usage_tracker.record_launch(item.id);
                    app.launch();
                    trigger_bounce(item.id, true);
                }
            }
        }

        private void get_item_bounds(int target_index, out double start_x, out double item_width) {
            int width = is_vertical ? get_allocated_height() : get_allocated_width();
            double total_width = 0;
            foreach (var item in items) {
                if (item.is_separator) {
                    total_width += SEPARATOR_WIDTH;
                } else {
                    total_width += renderer.icon_size * effective_width_factor(item) + renderer.spacing;
                }
            }
            double pos = (width - total_width) / 2.0;
            int i = 0;
            start_x = pos;
            item_width = 0;
            foreach (var item in items) {
                double w = item.is_separator ? SEPARATOR_WIDTH :
                    (renderer.icon_size * effective_width_factor(item) + renderer.spacing);
                if (i == target_index) {
                    start_x = pos;
                    item_width = w;
                    return;
                }
                pos += w;
                i++;
            }
        }

        private void show_window_list(DockItem item) {
            var menu = new Gtk.Menu();
            foreach (var window in item.windows) {
                var mi = new Gtk.MenuItem.with_label(window.get_name());
                mi.activate.connect(() => wm.activate_window(window));
                menu.append(mi);
            }
            menu.show_all();
            menu.popup_at_pointer(null);
        }

        private void show_context_menu(Gdk.EventButton event) {
            int index = get_item_at(is_vertical ? event.y : event.x);
            if (index < 0) return;
            var item = items.nth_data(index);
            if (item == null) return;

            if (item.is_plugin && item.plugin != null && item.plugin.has_menu) {
                var m = item.plugin.get_menu();
                if (m != null) { m.popup_at_pointer(event); return; }
            }

            // Folder context menu
            if (item.is_folder) {
                context_menu = new Gtk.Menu();
                var rename_mi = new Gtk.MenuItem.with_label("Rename Folder...");
                rename_mi.activate.connect(() => show_rename_folder_dialog(item));
                context_menu.append(rename_mi);

                var delete_mi = new Gtk.MenuItem.with_label("Delete Folder");
                delete_mi.activate.connect(() => {
                    config.delete_folder(item.folder_id);
                    items.remove(item);
                    save_pinned_apps();
                    position_dock();
                    schedule_redraw();
                });
                context_menu.append(delete_mi);

                context_menu.append(new Gtk.SeparatorMenuItem());
                var st = new Gtk.MenuItem.with_label("Dock Settings...");
                st.activate.connect(() => settings_requested());
                context_menu.append(st);

                context_menu.show_all();
                context_menu.popup_at_pointer(event);
                return;
            }

            context_menu = new Gtk.Menu();

            if (item.running) {
                var nw = new Gtk.MenuItem.with_label("Open New Window");
                nw.activate.connect(() => { var a = app_manager.get_app(item.id); if (a != null) { usage_tracker.record_launch(item.id); a.launch(); trigger_bounce(item.id, true); } });
                context_menu.append(nw);
            }

            // Recent files submenu
            if (item.desktop_file != null && item.desktop_file != "") {
                var recent_submenu = build_recent_files_menu(item);
                if (recent_submenu != null) {
                    var recent_mi = new Gtk.MenuItem.with_label("Recent Files");
                    recent_mi.submenu = recent_submenu;
                    context_menu.append(recent_mi);
                }
            }

            if (item.running || (item.desktop_file != null && item.desktop_file != "")) {
                context_menu.append(new Gtk.SeparatorMenuItem());
            }

            if (item.pinned) {
                var unpin = new Gtk.MenuItem.with_label("Unpin from Dock");
                unpin.activate.connect(() => {
                    if (item.running) item.pinned = false; else items.remove(item);
                    save_pinned_apps(); schedule_redraw();
                });
                context_menu.append(unpin);
            } else {
                var pin = new Gtk.MenuItem.with_label("Pin to Dock");
                pin.activate.connect(() => { item.pinned = true; save_pinned_apps(); schedule_redraw(); });
                context_menu.append(pin);
            }

            if (item.running && item.windows.length() > 0) {
                context_menu.append(new Gtk.SeparatorMenuItem());
                var cl = new Gtk.MenuItem.with_label("Close Window");
                cl.activate.connect(() => item.windows.nth_data(0).close(Gtk.get_current_event_time()));
                context_menu.append(cl);
                
                var force_close = new Gtk.MenuItem.with_label("Force Close");
                force_close.activate.connect(() => {
                    var window = item.windows.nth_data(0);
                    if (window != null) {
                        int pid = window.get_pid();
                        if (pid > 0) {
                            Posix.kill(pid, Posix.Signal.KILL);
                        }
                    }
                });
                context_menu.append(force_close);
            }

            if (!item.is_launcher) {
                context_menu.append(new Gtk.SeparatorMenuItem());
                var props = new Gtk.MenuItem.with_label("Properties...");
                props.activate.connect(() => show_properties_dialog(item));
                context_menu.append(props);
            }

            context_menu.append(new Gtk.SeparatorMenuItem());
            var st = new Gtk.MenuItem.with_label("Dock Settings...");
            st.activate.connect(() => settings_requested());
            context_menu.append(st);

            context_menu.show_all();
            context_menu.popup_at_pointer(event);
        }

        private void on_notification(string app_id) {
            if (notification_monitor == null) return;
            foreach (var item in items) {
                if (item.id == app_id) {
                    item.notification_count = notification_monitor.get_count(app_id);
                    schedule_redraw();
                    // Also trigger bounce for the notification
                    trigger_bounce(app_id);
                    return;
                }
            }
        }

        private void clear_badge_for_focused_app() {
            if (notification_monitor == null) return;
            var active = wm.get_active_window();
            if (active == null) return;
            var app = app_manager.find_by_window(active);
            if (app == null) return;
            notification_monitor.clear(app.id);
            foreach (var item in items) {
                if (item.id == app.id) {
                    item.notification_count = 0;
                    schedule_redraw();
                    return;
                }
            }
        }

        public void reload_settings() {
            config.reload();
            dock_position = config.get_position();
            is_vertical = (dock_position == "left" || dock_position == "right");
            renderer.icon_size = config.get_icon_size();
            renderer.magnification = config.get_magnification();
            auto_hide = config.get_auto_hide();
            dodge_windows = config.get_dodge_windows();
            rounded_corners = config.get_rounded_corners();
            dock_opacity = config.get_dock_opacity();

            // Compositor blur hint
            blur_enabled = config.get_blur_enabled();
            update_compositor_hints();
            ensure_blur_bg();
            // Re-apply bounding shape in case rounded_corners changed
            apply_blur_bg_shape();

            update_dock_dimensions();
            load_theme();

            items = new List<DockItem>();
            var launcher_item = new DockItem("dokku-launcher", "Applications", "view-app-grid-symbolic");
            launcher_item.pinned = true;
            launcher_item.is_launcher = true;
            items.append(launcher_item);
            load_pinned_apps();
            load_plugins();

            // Re-create or destroy notification monitor based on setting
            if (config.get_notification_badges()) {
                if (notification_monitor == null) {
                    notification_monitor = new NotificationMonitor(app_manager);
                    notification_monitor.notification_received.connect(on_notification);
                }
            } else {
                notification_monitor = null;
            }

            // If dodge_windows was disabled, clear dodge state
            if (!dodge_windows && dodge_hiding) {
                dodge_hiding = false;
            }

            if (!auto_hide && !dodge_hiding && hidden) {
                // Nothing requires hiding — show dock
                hidden = false;
                dock_slide_offset = 0.0;
            } else if (auto_hide && !hovering && !hidden) {
                // Auto-hide just enabled — hide immediately
                hidden = true;
                animate_slide(1.0);
            }

            // If dodge_windows enabled, schedule a check (hides only if overlap found)
            if (dodge_windows) {
                schedule_dodge_check();
            }

            // Update Layer Shell anchors and exclusive zone
            if (use_layer_shell) {
                apply_layer_shell_anchors();
                GtkLayerShell.set_exclusive_zone(this, (auto_hide || dodge_hiding) ? 0 : base_height);
            }

            // ProgressMonitor is kept alive across reloads (no settings dependency,
            // and recreating would leak Wnck signal connections)

            // Restore running app state — suppress bounces since this is a reload, not new launches
            bool was_initial = initial_load_done;
            initial_load_done = false;
            update_running_apps();
            initial_load_done = was_initial;

            // Restore notification counts from the monitor (items were recreated above)
            if (notification_monitor != null) {
                foreach (var item in items) {
                    int count = notification_monitor.get_count(item.id);
                    if (count > 0) {
                        item.notification_count = count;
                    }
                }
            }

            // Reposition and resize dock (and blur_bg) to reflect new item count
            if (!use_layer_shell) {
                position_dock();
            }
        }

        // --- Bounce animation ---

        private void on_attention_requested(Wnck.Window window) {
            var app = app_manager.find_by_window(window);
            if (app == null) return;
            trigger_bounce(app.id);
        }

        private void trigger_bounce(string app_id, bool is_launch = false) {
            // Skip launch bounces if disabled in settings
            if (is_launch && !config.get_launch_bounce()) return;

            // For notification/attention bounces, don't bounce if the app is already focused.
            // For launch bounces, always bounce (the app just started — user needs feedback).
            if (!is_launch) {
                var active = wm.get_active_window();
                if (active != null) {
                    var active_app = app_manager.find_by_window(active);
                    if (active_app != null && active_app.id == app_id) return;
                }
            }

            // Per-app cooldown: suppress repeated bounces within 5 seconds
            int64 now = GLib.get_monotonic_time();
            if (bounce_cooldowns.contains(app_id)) {
                int64 last = bounce_cooldowns.get(app_id);
                if (now - last < BOUNCE_COOLDOWN_US) return;
            }
            bounce_cooldowns.set(app_id, now);

            foreach (var item in items) {
                if (item.id == app_id) {
                    item.is_bouncing = true;
                    item.bounce_is_launch = is_launch;
                    item.bounce_start_time = now;
                    start_bounce_tick();

                    // When hiding and the dock is hidden, slide it up so the
                    // user sees the launch bounce, then re-hide after bounce + 1s.
                    if (is_launch && (auto_hide || dodge_hiding) && hidden) {
                        hidden = false;
                        animate_slide(0.0);
                        if (launch_rehide_timeout_id != 0) Source.remove(launch_rehide_timeout_id);
                        launch_rehide_timeout_id = Timeout.add(2000, () => {
                            launch_rehide_timeout_id = 0;
                            if ((auto_hide || dodge_hiding) && !hovering && !hidden) {
                                hidden = true;
                                animate_slide(1.0);
                            }
                            return false;
                        });
                    }

                    return;
                }
            }
        }

        private void clear_bounce_for_focused_app() {
            var active = wm.get_active_window();
            if (active == null) return;
            var app = app_manager.find_by_window(active);
            if (app == null) return;
            foreach (var item in items) {
                if (item.id == app.id && item.is_bouncing) {
                    // Launch bounces must play for a minimum duration so the user
                    // sees the feedback, even if the app takes focus immediately.
                    // Notification bounces clear instantly on focus.
                    if (item.bounce_is_launch) {
                        double elapsed = (GLib.get_monotonic_time() - item.bounce_start_time) / 1000000.0;
                        if (elapsed < 1.5) break;  // let it keep bouncing
                    }
                    item.is_bouncing = false;
                    break;
                }
            }
        }

        private void start_bounce_tick() {
            if (bounce_tick_id != 0) return;
            bounce_tick_id = add_tick_callback((widget, frame_clock) => {
                bool any_bouncing = false;
                int64 now = frame_clock.get_frame_time();
                foreach (var item in items) {
                    if (item.is_bouncing) {
                        double elapsed = (now - item.bounce_start_time) / 1000000.0;
                        if (elapsed > 1.5) {
                            item.is_bouncing = false;
                        } else {
                            any_bouncing = true;
                        }
                    }
                }
                queue_draw();
                if (!any_bouncing) {
                    bounce_tick_id = 0;
                    return false;
                }
                return true;
            });
        }

        // --- Progress bar ---

        private void on_progress_changed(string app_id, double progress, bool visible) {
            foreach (var item in items) {
                if (item.id == app_id) {
                    item.progress_value = progress;
                    item.progress_visible = visible;
                    // Start animation tick for indeterminate (spinning) progress
                    if (visible && progress < 0.0) {
                        start_progress_tick();
                    }
                    schedule_redraw();
                    return;
                }
            }
        }

        private void start_progress_tick() {
            if (progress_tick_id != 0) return;
            progress_tick_id = Timeout.add(16, () => {
                bool any_indeterminate = false;
                foreach (var item in items) {
                    if (item.progress_visible && item.progress_value < 0.0) {
                        any_indeterminate = true;
                        break;
                    }
                }
                queue_draw();
                if (!any_indeterminate) {
                    progress_tick_id = 0;
                    return false;
                }
                return true;
            });
        }

        // --- Recent files ---

        private Gtk.Menu? build_recent_files_menu(DockItem item) {
            var recent_manager = Gtk.RecentManager.get_default();
            var all_items = recent_manager.get_items();

            string? exec_base = null;
            var app = app_manager.get_app(item.id);
            if (app != null && app.exec != null && app.exec != "") {
                exec_base = Path.get_basename(app.exec.split(" ")[0]);
            }

            string? desktop_id = null;
            if (item.desktop_file != null) {
                desktop_id = Path.get_basename(item.desktop_file);
            }

            var matched = new List<Gtk.RecentInfo>();
            foreach (var info in all_items) {
                if (!info.exists()) continue;
                bool matches = false;
                if (exec_base != null && info.has_application(exec_base)) matches = true;
                if (!matches && desktop_id != null && info.has_application(desktop_id)) matches = true;
                if (!matches && info.has_application(item.id)) matches = true;
                if (matches) matched.append(info);
            }

            if (matched.length() == 0) {
                var menu = new Gtk.Menu();
                var empty = new Gtk.MenuItem.with_label("No recent files");
                empty.sensitive = false;
                menu.append(empty);
                return menu;
            }

            matched.sort((a, b) => {
                long at = (long)a.get_modified();
                long bt = (long)b.get_modified();
                if (at > bt) return -1;
                if (at < bt) return 1;
                return 0;
            });

            var menu = new Gtk.Menu();
            int count = 0;
            foreach (var info in matched) {
                if (count >= 10) break;
                string display_name = info.get_display_name();
                string uri = info.get_uri();
                var mi = new Gtk.MenuItem.with_label(display_name);
                mi.activate.connect(() => {
                    try {
                        Gtk.show_uri_on_window(this, uri, Gdk.CURRENT_TIME);
                    } catch (Error e) {
                        warning("Failed to open recent file: %s", e.message);
                    }
                });
                menu.append(mi);
                count++;
            }
            return menu;
        }

        // --- Window preview popup ---

        private void cancel_preview_timer() {
            if (hover_preview_timeout_id != 0) {
                Source.remove(hover_preview_timeout_id);
                hover_preview_timeout_id = 0;
            }
            preview_target_index = -1;
        }

        private void dismiss_preview_popup() {
            cancel_preview_dismiss();
            if (preview_popup != null) {
                preview_popup.destroy();
                preview_popup = null;
            }
        }

        private void schedule_preview_dismiss() {
            if (preview_popup == null) return;
            if (preview_dismiss_timeout_id != 0) return;
            preview_dismiss_timeout_id = Timeout.add(300, () => {
                preview_dismiss_timeout_id = 0;
                dismiss_preview_popup();
                return false;
            });
        }

        private void cancel_preview_dismiss() {
            if (preview_dismiss_timeout_id != 0) {
                Source.remove(preview_dismiss_timeout_id);
                preview_dismiss_timeout_id = 0;
            }
        }

        private Gtk.Window create_popup_window(Gdk.WindowTypeHint hint = Gdk.WindowTypeHint.POPUP_MENU) {
            var popup = new Gtk.Window(Gtk.WindowType.POPUP);
            popup.set_type_hint(hint);
            popup.set_skip_taskbar_hint(true);
            popup.set_skip_pager_hint(true);
            popup.set_decorated(false);
            popup.set_resizable(false);
            var vis = popup.get_screen().get_rgba_visual();
            if (vis != null) popup.set_visual(vis);
            popup.set_app_paintable(true);
            return popup;
        }

        private void draw_popup_background(Cairo.Context cr, Gtk.Widget popup, Theme? theme_ref, double radius) {
            cr.set_operator(Cairo.Operator.SOURCE);
            cr.set_source_rgba(0, 0, 0, 0);
            cr.paint();
            cr.set_operator(Cairo.Operator.OVER);

            int w = popup.get_allocated_width();
            int h = popup.get_allocated_height();

            double r = 0.12, g = 0.12, b = 0.12;
            if (theme_ref != null) {
                r = theme_ref.bg_red; g = theme_ref.bg_green; b = theme_ref.bg_blue;
            }
            draw_rounded_rect(cr, 0, 0, w, h, radius);
            cr.set_source_rgba(r, g, b, 0.92);
            cr.fill_preserve();

            if (theme_ref != null) {
                cr.set_source_rgba(theme_ref.border_red, theme_ref.border_green,
                                   theme_ref.border_blue, theme_ref.border_alpha);
            } else {
                cr.set_source_rgba(1, 1, 1, 0.1);
            }
            cr.set_line_width(1);
            cr.stroke();
        }

        private void compute_popup_position(int index, int popup_w, int popup_h, int gap,
                                              out int out_x, out int out_y) {
            double item_start, item_w;
            get_item_bounds(index, out item_start, out item_w);

            int dock_x, dock_y;
            get_position(out dock_x, out dock_y);

            int dw = get_allocated_width();
            int dh = get_allocated_height();

            if (dock_position == "top") {
                // Popup below dock
                int dock_bg_bottom = dock_y + icon_area_height + 2;
                out_x = dock_x + (int)(item_start + item_w / 2.0) - popup_w / 2;
                out_y = dock_bg_bottom + gap;
            } else if (dock_position == "left") {
                // Popup to right of dock
                int dock_bg_right = dock_x + icon_area_height + 2;
                out_x = dock_bg_right + gap;
                out_y = dock_y + (int)(item_start + item_w / 2.0) - popup_h / 2;
            } else if (dock_position == "right") {
                // Popup to left of dock
                int dock_bg_left = dock_x + dw - icon_area_height - 2;
                out_x = dock_bg_left - popup_w - gap;
                out_y = dock_y + (int)(item_start + item_w / 2.0) - popup_h / 2;
            } else { // bottom
                // Popup above dock
                int dock_bg_top = dock_y + dh - icon_area_height - 2;
                out_x = dock_x + (int)(item_start + item_w / 2.0) - popup_w / 2;
                out_y = dock_bg_top - popup_h - gap;
            }
        }

        private void show_name_tooltip(int index) {
            var item = items.nth_data(index);
            if (item == null) return;

            dismiss_preview_popup();

            preview_popup = create_popup_window(Gdk.WindowTypeHint.TOOLTIP);

            var label = new Gtk.Label(item.name);
            label.margin = 6;
            var css = new Gtk.CssProvider();
            try {
                css.load_from_data(is_light_theme() ?
                    "label { color: #1a1a1a; }" : "label { color: #ffffff; }");
            } catch (Error e) {}
            label.get_style_context().add_provider(css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            preview_popup.add(label);

            var theme_ref = current_theme;
            preview_popup.draw.connect((cr) => {
                draw_popup_background(cr, preview_popup, theme_ref, 6);
                return false;
            });

            preview_popup.show_all();

            int popup_w, popup_h;
            preview_popup.get_size(out popup_w, out popup_h);
            int px, py;
            compute_popup_position(index, popup_w, popup_h, 8, out px, out py);
            preview_popup.move(px, py);

            preview_popup.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK |
                                     Gdk.EventMask.LEAVE_NOTIFY_MASK);
            preview_popup.enter_notify_event.connect((ev) => {
                cancel_preview_dismiss();
                return false;
            });
            preview_popup.leave_notify_event.connect((ev) => {
                if (ev.detail == Gdk.NotifyType.INFERIOR) return false;
                schedule_preview_dismiss();
                return false;
            });
        }

        private void show_preview_popup(int index) {
            var item = items.nth_data(index);
            if (item == null || item.windows.length() <= 1) return;

            dismiss_preview_popup();

            preview_popup = create_popup_window(Gdk.WindowTypeHint.TOOLTIP);

            bool popup_light = is_light_theme();
            var label_css = new Gtk.CssProvider();
            try {
                label_css.load_from_data(popup_light ?
                    "label { color: #1a1a1a; }" : "label { color: #ffffff; }");
            } catch (Error e) {}

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            box.margin = 8;

            foreach (var window in item.windows) {
                var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
                row.margin = 4;

                var icon = new Gtk.Image.from_icon_name(item.icon_name, Gtk.IconSize.MENU);
                row.pack_start(icon, false, false, 0);

                var label = new Gtk.Label(window.get_name());
                label.halign = Gtk.Align.START;
                label.ellipsize = Pango.EllipsizeMode.END;
                label.max_width_chars = 30;
                label.get_style_context().add_provider(label_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
                row.pack_start(label, true, true, 0);

                var close_btn = new Gtk.Button.from_icon_name("window-close-symbolic", Gtk.IconSize.MENU);
                close_btn.relief = Gtk.ReliefStyle.NONE;
                close_btn.clicked.connect(() => {
                    window.close(Gtk.get_current_event_time());
                    dismiss_preview_popup();
                });
                row.pack_end(close_btn, false, false, 0);

                var event_box = new Gtk.EventBox();
                event_box.add(row);
                event_box.button_press_event.connect((ev) => {
                    if (ev.button == 1) {
                        wm.activate_window(window);
                        dismiss_preview_popup();
                    }
                    return true;
                });

                box.pack_start(event_box, false, false, 0);
            }

            var theme_ref = current_theme;
            preview_popup.draw.connect((cr) => {
                draw_popup_background(cr, preview_popup, theme_ref, 8);
                return false;
            });

            preview_popup.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK |
                                     Gdk.EventMask.LEAVE_NOTIFY_MASK);

            preview_popup.add(box);
            preview_popup.show_all();

            int popup_w, popup_h;
            preview_popup.get_size(out popup_w, out popup_h);
            int px, py;
            compute_popup_position(index, popup_w, popup_h, 8, out px, out py);
            preview_popup.move(px, py);

            // Mouse entering popup cancels any pending dismiss
            preview_popup.enter_notify_event.connect((ev) => {
                cancel_preview_dismiss();
                return false;
            });

            // Mouse leaving popup schedules a delayed dismiss
            preview_popup.leave_notify_event.connect((ev) => {
                // Ignore leave events caused by entering child widgets
                if (ev.detail == Gdk.NotifyType.INFERIOR) return false;
                schedule_preview_dismiss();
                return false;
            });
        }

        // --- Media popup (vertical docks) ---

        private Gtk.Window? media_popup = null;
        private uint media_popup_fade_tick = 0;
        private int64 media_popup_fade_start = 0;
        private bool media_popup_fading_out = false;
        private bool media_popup_hover = false;
        private uint media_popup_dismiss_id = 0;
        private const int MEDIA_POPUP_FADE_MS = 180;

        private void dismiss_media_popup() {
            if (media_popup == null) return;
            if (media_popup_fading_out) return;  // already fading
            media_popup_fading_out = true;
            media_popup_fade_start = GLib.get_monotonic_time();
            if (media_popup_fade_tick != 0) return;  // reuse tick
            media_popup_fade_tick = media_popup.add_tick_callback((widget, clock) => {
                int64 elapsed = clock.get_frame_time() - media_popup_fade_start;
                double t = double.min(1.0, elapsed / (MEDIA_POPUP_FADE_MS * 1000.0));
                if (media_popup != null) {
                    ((Gtk.Widget)media_popup).opacity = 1.0 - t;
                }
                if (t >= 1.0) {
                    media_popup_fade_tick = 0;
                    media_popup_fading_out = false;
                    if (media_popup != null) {
                        media_popup.destroy();
                        media_popup = null;
                    }
                    return false;
                }
                return true;
            });
        }

        private void schedule_media_popup_dismiss() {
            if (media_popup == null || media_popup_dismiss_id != 0) return;
            media_popup_dismiss_id = Timeout.add(300, () => {
                media_popup_dismiss_id = 0;
                if (!media_popup_hover) {
                    dismiss_media_popup();
                }
                return false;
            });
        }

        private void cancel_media_popup_dismiss() {
            if (media_popup_dismiss_id != 0) {
                Source.remove(media_popup_dismiss_id);
                media_popup_dismiss_id = 0;
            }
        }

        private void show_media_popup(MediaPlugin mp, int index) {
            // Toggle: if already open, dismiss it
            if (media_popup != null) {
                dismiss_media_popup();
                return;
            }

            media_popup_hover = false;

            media_popup = create_popup_window(Gdk.WindowTypeHint.POPUP_MENU);

            bool popup_light = is_light_theme();

            // CSS for button and label colors
            var css_provider = new Gtk.CssProvider();
            if (popup_light) {
                try {
                    css_provider.load_from_data(
                        "button { color: #1a1a1a; } button:hover { background: rgba(0,0,0,0.08); } " +
                        ".media-title { color: #1a1a1a; } .media-artist { color: #4d4d4d; }");
                } catch (Error e) {}
            } else {
                try {
                    css_provider.load_from_data(
                        "button { color: #ffffff; } button:hover { background: rgba(255,255,255,0.1); } " +
                        ".media-title { color: #ffffff; } .media-artist { color: #b3b3b3; }");
                } catch (Error e) {}
            }

            var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
            hbox.margin = 10;

            // Album art (64x64)
            int art_size = 64;
            var art = mp.get_art(art_size);
            Gtk.Image art_image;
            if (art != null) {
                art_image = new Gtk.Image.from_pixbuf(art);
            } else {
                art_image = new Gtk.Image.from_icon_name("audio-x-generic-symbolic", Gtk.IconSize.DIALOG);
            }
            art_image.set_size_request(art_size, art_size);
            hbox.pack_start(art_image, false, false, 0);

            // Text box (title + artist)
            var text_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            text_box.valign = Gtk.Align.CENTER;

            string title_str = mp.track_title != "" ? mp.track_title : mp.player_name;
            var title_label = new Gtk.Label(null);
            title_label.set_markup("<b>" + GLib.Markup.escape_text(title_str) + "</b>");
            title_label.halign = Gtk.Align.START;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.max_width_chars = 25;
            title_label.get_style_context().add_class("media-title");
            title_label.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            text_box.pack_start(title_label, false, false, 0);

            if (mp.track_artist != "") {
                var artist_label = new Gtk.Label(mp.track_artist);
                artist_label.halign = Gtk.Align.START;
                artist_label.ellipsize = Pango.EllipsizeMode.END;
                artist_label.max_width_chars = 25;
                artist_label.get_style_context().add_class("media-artist");
                artist_label.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
                text_box.pack_start(artist_label, false, false, 0);
            }

            hbox.pack_start(text_box, true, true, 0);

            // Control buttons
            var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            btn_box.valign = Gtk.Align.CENTER;

            var prev_btn = new Gtk.Button.from_icon_name("media-skip-backward-symbolic", Gtk.IconSize.LARGE_TOOLBAR);
            prev_btn.relief = Gtk.ReliefStyle.NONE;
            prev_btn.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            prev_btn.clicked.connect(() => mp.previous());
            btn_box.pack_start(prev_btn, false, false, 0);

            var play_btn = new Gtk.Button.from_icon_name(
                mp.is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic",
                Gtk.IconSize.LARGE_TOOLBAR);
            play_btn.relief = Gtk.ReliefStyle.NONE;
            play_btn.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            play_btn.clicked.connect(() => {
                mp.activate();
                // Update icon after toggle (small delay for state to propagate)
                if (media_play_update_id != 0) Source.remove(media_play_update_id);
                media_play_update_id = Timeout.add(200, () => {
                    media_play_update_id = 0;
                    if (media_popup != null) {
                        var img = new Gtk.Image.from_icon_name(
                            mp.is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic",
                            Gtk.IconSize.LARGE_TOOLBAR);
                        play_btn.set_image(img);
                    }
                    return false;
                });
            });
            btn_box.pack_start(play_btn, false, false, 0);

            var next_btn = new Gtk.Button.from_icon_name("media-skip-forward-symbolic", Gtk.IconSize.LARGE_TOOLBAR);
            next_btn.relief = Gtk.ReliefStyle.NONE;
            next_btn.get_style_context().add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            next_btn.clicked.connect(() => mp.next());
            btn_box.pack_start(next_btn, false, false, 0);

            hbox.pack_start(btn_box, false, false, 0);

            // Themed popup background
            var theme_ref = current_theme;
            media_popup.draw.connect((cr) => {
                draw_popup_background(cr, media_popup, theme_ref, 10);
                return false;
            });

            media_popup.add(hbox);

            // Start fully transparent for fade-in
            ((Gtk.Widget)media_popup).opacity = 0.0;
            media_popup.show_all();

            int popup_w, popup_h;
            media_popup.get_size(out popup_w, out popup_h);
            int px, py;
            compute_popup_position(index, popup_w, popup_h, 8, out px, out py);
            media_popup.move(px, py);

            // Fade in
            media_popup_fading_out = false;
            media_popup_fade_start = GLib.get_monotonic_time();
            media_popup_fade_tick = media_popup.add_tick_callback((widget, clock) => {
                int64 elapsed = clock.get_frame_time() - media_popup_fade_start;
                double t = double.min(1.0, elapsed / (MEDIA_POPUP_FADE_MS * 1000.0));
                if (media_popup != null) {
                    ((Gtk.Widget)media_popup).opacity = t;
                }
                if (t >= 1.0) {
                    media_popup_fade_tick = 0;
                    return false;
                }
                return true;
            });

            // Track mouse enter/leave on popup for dismiss-on-leave
            media_popup.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK |
                                   Gdk.EventMask.LEAVE_NOTIFY_MASK);
            media_popup.enter_notify_event.connect((ev) => {
                media_popup_hover = true;
                cancel_media_popup_dismiss();
                return false;
            });
            media_popup.leave_notify_event.connect((ev) => {
                if (ev.detail == Gdk.NotifyType.INFERIOR) return false;
                media_popup_hover = false;
                schedule_media_popup_dismiss();
                return false;
            });
        }

        // --- Folder popup ---

        private Gtk.Window? folder_popup = null;

        private void show_folder_popup(DockItem folder_item, int index) {
            if (folder_popup != null) {
                folder_popup.destroy();
                folder_popup = null;
            }

            string[] folder_apps = config.get_folder_apps(folder_item.folder_id);

            folder_popup = create_popup_window(Gdk.WindowTypeHint.POPUP_MENU);

            var vbox = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);
            vbox.margin = 12;

            var title_label = new Gtk.Label("<b>" + GLib.Markup.escape_text(folder_item.name) + "</b>");
            title_label.use_markup = true;
            title_label.margin_bottom = 8;
            vbox.pack_start(title_label, false, false, 0);

            int cols = 4;
            var grid = new Gtk.Grid();
            grid.row_spacing = 8;
            grid.column_spacing = 8;
            grid.halign = Gtk.Align.CENTER;

            int col = 0;
            int row_n = 0;
            foreach (var app_id in folder_apps) {
                var app = app_manager.get_app(app_id);
                if (app == null) continue;

                var btn_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 4);

                var icon_img = new Gtk.Image.from_icon_name(app.icon, Gtk.IconSize.DIALOG);
                btn_box.pack_start(icon_img, false, false, 0);

                var name_label = new Gtk.Label(app.name);
                name_label.ellipsize = Pango.EllipsizeMode.END;
                name_label.max_width_chars = 10;
                name_label.set_size_request(64, -1);
                btn_box.pack_start(name_label, false, false, 0);

                var event_box = new Gtk.EventBox();
                event_box.add(btn_box);
                event_box.button_press_event.connect((ev) => {
                    usage_tracker.record_launch(app.id);
                    app.launch();
                    trigger_bounce(folder_item.id, true);
                    if (folder_popup != null) {
                        folder_popup.destroy();
                        folder_popup = null;
                    }
                    return true;
                });

                grid.attach(event_box, col, row_n, 1, 1);
                col++;
                if (col >= cols) { col = 0; row_n++; }
            }

            vbox.pack_start(grid, false, false, 0);

            var theme_ref = current_theme;
            folder_popup.draw.connect((cr) => {
                draw_popup_background(cr, folder_popup, theme_ref, 12);
                return false;
            });

            folder_popup.add(vbox);
            folder_popup.show_all();

            int popup_w, popup_h;
            folder_popup.get_size(out popup_w, out popup_h);
            int px, py;
            compute_popup_position(index, popup_w, popup_h, 4, out px, out py);
            folder_popup.move(px, py);

            folder_popup.focus_out_event.connect(() => {
                if (folder_popup != null) {
                    folder_popup.destroy();
                    folder_popup = null;
                }
                return false;
            });
        }

        private void show_rename_folder_dialog(DockItem folder_item) {
            var dialog = new Gtk.Dialog.with_buttons("Rename Folder", this,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                "_Cancel", Gtk.ResponseType.CANCEL,
                "_Rename", Gtk.ResponseType.OK);
            dialog.set_default_response(Gtk.ResponseType.OK);

            var entry = new Gtk.Entry();
            entry.text = folder_item.name;
            entry.margin = 12;
            entry.activates_default = true;
            dialog.get_content_area().add(entry);
            dialog.show_all();

            if (dialog.run() == Gtk.ResponseType.OK) {
                string new_name = entry.text.strip();
                if (new_name != "") {
                    config.rename_folder(folder_item.folder_id, new_name);
                    folder_item.name = new_name;
                    schedule_redraw();
                }
            }
            dialog.destroy();
        }

        private void show_properties_dialog(DockItem item) {
            var dialog = new Gtk.Dialog.with_buttons("Properties — " + item.name, this,
                Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                "_Close", Gtk.ResponseType.CLOSE);
            dialog.set_default_size(400, -1);

            var content = dialog.get_content_area();
            content.spacing = 8;
            content.margin = 12;

            var app = app_manager.get_app(item.id);
            string? current_custom = config.get_custom_icon(item.id);
            string original_icon = app != null ? app.icon : item.icon_name;

            // App icon (clickable to browse) + name header
            var header_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
            var icon_image = new Gtk.Image.from_icon_name(item.icon_name, Gtk.IconSize.DIALOG);
            var icon_event = new Gtk.EventBox();
            icon_event.add(icon_image);
            icon_event.tooltip_text = "Click to change icon";
            header_box.pack_start(icon_event, false, false, 0);
            var name_label = new Gtk.Label("<b>" + GLib.Markup.escape_text(item.name) + "</b>");
            name_label.use_markup = true;
            name_label.halign = Gtk.Align.START;
            header_box.pack_start(name_label, false, false, 0);
            content.pack_start(header_box, false, false, 0);

            content.pack_start(new Gtk.Separator(Gtk.Orientation.HORIZONTAL), false, false, 4);

            // Properties grid
            var grid = new Gtk.Grid();
            grid.row_spacing = 6;
            grid.column_spacing = 12;
            int row = 0;

            // App ID
            var id_label = new Gtk.Label("App ID:");
            id_label.halign = Gtk.Align.END;
            id_label.get_style_context().add_class("dim-label");
            grid.attach(id_label, 0, row, 1, 1);
            var id_value = new Gtk.Label(item.id);
            id_value.halign = Gtk.Align.START;
            id_value.selectable = true;
            grid.attach(id_value, 1, row, 1, 1);
            row++;

            // Desktop file
            if (item.desktop_file != null && item.desktop_file != "") {
                var df_label = new Gtk.Label("Desktop File:");
                df_label.halign = Gtk.Align.END;
                df_label.get_style_context().add_class("dim-label");
                grid.attach(df_label, 0, row, 1, 1);
                var df_value = new Gtk.Label(item.desktop_file);
                df_value.halign = Gtk.Align.START;
                df_value.selectable = true;
                df_value.ellipsize = Pango.EllipsizeMode.MIDDLE;
                df_value.max_width_chars = 35;
                grid.attach(df_value, 1, row, 1, 1);
                row++;
            }

            // Command
            if (app != null && app.exec != null && app.exec != "") {
                var exec_label = new Gtk.Label("Command:");
                exec_label.halign = Gtk.Align.END;
                exec_label.get_style_context().add_class("dim-label");
                grid.attach(exec_label, 0, row, 1, 1);
                var exec_value = new Gtk.Label(app.exec);
                exec_value.halign = Gtk.Align.START;
                exec_value.selectable = true;
                exec_value.ellipsize = Pango.EllipsizeMode.END;
                exec_value.max_width_chars = 35;
                grid.attach(exec_value, 1, row, 1, 1);
                row++;
            }

            // File metadata: binary location, dates, size
            if (app != null && app.exec != null && app.exec != "") {
                string exec_basename = app.exec.split(" ")[0];
                string? binary_path = Environment.find_program_in_path(exec_basename);
                if (binary_path != null) {
                    // Location
                    var loc_label = new Gtk.Label("Location:");
                    loc_label.halign = Gtk.Align.END;
                    loc_label.get_style_context().add_class("dim-label");
                    grid.attach(loc_label, 0, row, 1, 1);
                    var loc_value = new Gtk.Label(binary_path);
                    loc_value.halign = Gtk.Align.START;
                    loc_value.selectable = true;
                    loc_value.ellipsize = Pango.EllipsizeMode.MIDDLE;
                    loc_value.max_width_chars = 35;
                    grid.attach(loc_value, 1, row, 1, 1);
                    row++;

                    try {
                        var file = File.new_for_path(binary_path);
                        var info = file.query_info(
                            "time::modified,time::access,standard::size",
                            FileQueryInfoFlags.NONE);

                        // Modified
                        var mtime = info.get_modification_date_time();
                        if (mtime != null) {
                            var mod_label = new Gtk.Label("Modified:");
                            mod_label.halign = Gtk.Align.END;
                            mod_label.get_style_context().add_class("dim-label");
                            grid.attach(mod_label, 0, row, 1, 1);
                            var mod_value = new Gtk.Label(mtime.to_local().format("%Y-%m-%d %H:%M:%S"));
                            mod_value.halign = Gtk.Align.START;
                            mod_value.selectable = true;
                            grid.attach(mod_value, 1, row, 1, 1);
                            row++;
                        }

                        // Accessed
                        var atime_val = info.get_attribute_uint64("time::access");
                        if (atime_val > 0) {
                            var atime = new DateTime.from_unix_local((int64)atime_val);
                            var acc_label = new Gtk.Label("Accessed:");
                            acc_label.halign = Gtk.Align.END;
                            acc_label.get_style_context().add_class("dim-label");
                            grid.attach(acc_label, 0, row, 1, 1);
                            var acc_value = new Gtk.Label(atime.format("%Y-%m-%d %H:%M:%S"));
                            acc_value.halign = Gtk.Align.START;
                            acc_value.selectable = true;
                            grid.attach(acc_value, 1, row, 1, 1);
                            row++;
                        }

                        // Size
                        int64 file_size = info.get_size();
                        var size_label = new Gtk.Label("Size:");
                        size_label.halign = Gtk.Align.END;
                        size_label.get_style_context().add_class("dim-label");
                        grid.attach(size_label, 0, row, 1, 1);
                        var size_value = new Gtk.Label(format_file_size(file_size));
                        size_value.halign = Gtk.Align.START;
                        size_value.selectable = true;
                        grid.attach(size_value, 1, row, 1, 1);
                        row++;
                    } catch (Error e) {}
                }
            }

            content.pack_start(grid, false, false, 0);

            // Icon override section
            content.pack_start(new Gtk.Separator(Gtk.Orientation.HORIZONTAL), false, false, 4);

            var icon_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            var icon_label = new Gtk.Label("Icon:");
            icon_label.halign = Gtk.Align.END;
            icon_label.get_style_context().add_class("dim-label");
            icon_box.pack_start(icon_label, false, false, 0);

            var icon_entry = new Gtk.Entry();
            icon_entry.text = item.icon_name;
            icon_entry.hexpand = true;
            icon_box.pack_start(icon_entry, true, true, 0);

            var browse_btn = new Gtk.Button.from_icon_name("document-open-symbolic", Gtk.IconSize.BUTTON);
            browse_btn.tooltip_text = "Browse for icon";
            icon_box.pack_start(browse_btn, false, false, 0);

            var icon_preview = new Gtk.Image.from_icon_name(item.icon_name, Gtk.IconSize.LARGE_TOOLBAR);
            icon_box.pack_start(icon_preview, false, false, 0);

            // Update preview when entry changes
            icon_entry.changed.connect(() => {
                string text = icon_entry.text.strip();
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

                // Preview widget
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

            // Clicking header icon also opens browse dialog
            icon_event.button_press_event.connect((ev) => {
                browse_btn.clicked();
                return true;
            });

            content.pack_start(icon_box, false, false, 0);

            // Apply / Reset buttons
            var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            btn_box.halign = Gtk.Align.END;

            if (current_custom != null) {
                var reset_btn = new Gtk.Button.with_label("Reset Icon");
                reset_btn.clicked.connect(() => {
                    config.clear_custom_icon(item.id);
                    item.icon_name = original_icon;
                    icon_entry.text = original_icon;
                    update_header_icon(icon_image, original_icon);
                    renderer.clear_icon_cache(current_custom);
                    schedule_redraw();
                });
                btn_box.pack_start(reset_btn, false, false, 0);
            }

            var apply_btn = new Gtk.Button.with_label("Apply Icon");
            apply_btn.get_style_context().add_class("suggested-action");
            apply_btn.clicked.connect(() => {
                string new_icon = icon_entry.text.strip();
                if (new_icon != "" && new_icon != original_icon) {
                    config.set_custom_icon(item.id, new_icon);
                    renderer.clear_icon_cache(item.icon_name);
                    item.icon_name = new_icon;
                    update_header_icon(icon_image, new_icon);
                    schedule_redraw();
                } else if (new_icon == original_icon) {
                    config.clear_custom_icon(item.id);
                    item.icon_name = original_icon;
                    renderer.clear_icon_cache(item.icon_name);
                    update_header_icon(icon_image, original_icon);
                    schedule_redraw();
                }
            });
            btn_box.pack_start(apply_btn, false, false, 0);

            content.pack_start(btn_box, false, false, 0);

            dialog.show_all();
            dialog.run();
            dialog.destroy();
        }

        private void update_header_icon(Gtk.Image image, string icon_name) {
            if (icon_name.has_prefix("/") && FileUtils.test(icon_name, FileTest.EXISTS)) {
                try {
                    var pixbuf = new Gdk.Pixbuf.from_file_at_size(icon_name, 48, 48);
                    image.set_from_pixbuf(pixbuf);
                } catch (Error e) {
                    image.set_from_icon_name(icon_name, Gtk.IconSize.DIALOG);
                }
            } else {
                image.set_from_icon_name(icon_name, Gtk.IconSize.DIALOG);
            }
        }

        private string format_file_size(int64 size) {
            if (size < 1024) return "%s B".printf(size.to_string());
            if (size < 1024 * 1024) return "%.1f KB".printf(size / 1024.0);
            if (size < 1024 * 1024 * 1024) return "%.1f MB".printf(size / (1024.0 * 1024.0));
            return "%.1f GB".printf(size / (1024.0 * 1024.0 * 1024.0));
        }
    }
}
