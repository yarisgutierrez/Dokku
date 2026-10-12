namespace Dokku {
    public class DockWindow : Gtk.Window, PopupHost {
        private WindowManager wm;
        private DockRenderer renderer;
        private PropertiesDialog properties_dialog;
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
        private DragFloatPopup drag_float = new DragFloatPopup();

        private ProgressMonitor? progress_monitor;
        private uint progress_tick_id = 0;
        private UsageTracker usage_tracker;

        private MediaPopup media_popup;
        private FolderPopup folder_popup;
        private PreviewPopup preview;

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
        private BlurBackdrop blur_backdrop;

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
            properties_dialog = new PropertiesDialog(this, app_manager, config, renderer);
            properties_dialog.changed.connect(schedule_redraw);
            renderer.app_manager = app_manager;
            this.config = config;
            plugin_manager = new PluginManager(config);
            theme_manager = new ThemeManager();
            items = new List<DockItem>();
            bounce_cooldowns = new HashTable<string, int64?>(str_hash, str_equal);

            // Compositor blur hint
            blur_enabled = config.get_blur_enabled() && Capabilities.current.supports(Feature.COMPOSITOR_BLUR);

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

            add_events(Gdk.EventMask.KEY_PRESS_MASK |
                       Gdk.EventMask.POINTER_MOTION_MASK |
                       Gdk.EventMask.LEAVE_NOTIFY_MASK |
                       Gdk.EventMask.ENTER_NOTIFY_MASK |
                       Gdk.EventMask.BUTTON_PRESS_MASK |
                       Gdk.EventMask.BUTTON_RELEASE_MASK);

            // Enable drag-and-drop for .desktop files (no HIGHLIGHT — we draw our own indicator)
            Gtk.drag_dest_set(this, Gtk.DestDefaults.DROP, DROP_TARGETS, Gdk.DragAction.COPY);
            drag_data_received.connect(on_drag_data_received);
            drag_motion.connect(on_drag_motion);
            drag_leave.connect(on_drag_leave);

            if (!use_layer_shell) {
                realize.connect(position_dock);
            }

            // On X11: set override_redirect so the WM doesn't manage the dock.
            // This is required for proper ARGB transparency under XFwm4 and
            // other non-picom compositors. Picom still sees the window via
            // class_g matching and our custom X11 atoms.
            // On Wayland (layer shell), this is not needed.
            realize.connect(() => {
                input_shape_known = false;
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

            preview = new PreviewPopup(this, wm);
            media_popup = new MediaPopup(this);
            blur_backdrop = new BlurBackdrop(this, () => {
                double theme_radius = current_theme != null ? current_theme.corner_radius : 16;
                return rounded_corners ? theme_radius : 0;
            });
            blur_backdrop.created.connect(apply_dock_position);
            folder_popup = new FolderPopup(this, app_manager, config, usage_tracker);
            folder_popup.launched.connect((folder_item) => trigger_bounce(folder_item.id, true));
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
            key_press_event.connect(on_key_press);
            button_release_event.connect(on_button_release);

            this.destroy.connect(() => {
                // Pointer grab
                if (is_reordering) {
                    var seat = get_display().get_default_seat();
                    seat.ungrab();
                    is_reordering = false;
                }
                drag_float.destroy();

                // Timeouts
                if (dodge_check_timeout_id != 0) { Source.remove(dodge_check_timeout_id); dodge_check_timeout_id = 0; }
                if (hide_timeout_id != 0) { Source.remove(hide_timeout_id); hide_timeout_id = 0; }
                if (launch_rehide_timeout_id != 0) { Source.remove(launch_rehide_timeout_id); launch_rehide_timeout_id = 0; }

                // Tick callbacks are auto-removed on widget destroy, but null IDs
                slide_tick_id = 0;
                bounce_tick_id = 0;
                progress_tick_id = 0;

                // Popups
                media_popup.shutdown();
                folder_popup.shutdown();
                preview.shutdown();
                blur_backdrop.shutdown();
            });

            auto_hide = config.get_auto_hide();
            dodge_windows = config.get_dodge_windows() && Capabilities.current.supports(Feature.DODGE_WINDOWS);
            dock_position = config.get_position();
            is_vertical = (dock_position == "left" || dock_position == "right");
            renderer.icon_size = config.get_icon_size();
            renderer.magnification = config.get_magnification();
            rounded_corners = config.get_rounded_corners();
            dock_opacity = config.get_dock_opacity();
            update_dock_dimensions();

            // Size the window only now that base_height is known. Layer-shell takes
            // the surface size from this; with base_height still 0 the compositor was
            // given a 1px-tall dock. (X11 corrects it on realize via position_dock.)
            if (is_vertical)
                set_default_size(base_height, calculate_dock_length());
            else
                set_default_size(calculate_dock_length(), base_height);

            if (use_layer_shell) {
                size_layer_shell_surface();
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

        // The compositor takes a layer surface's size from the window. A GTK3 window
        // that has no child widget and is sized only with set_default_size()/resize()
        // is mapped but never drawn under gtk-layer-shell (the dock paints straight
        // onto its window), so ask for the size explicitly.
        private void size_layer_shell_surface() {
            int length = calculate_dock_length();
            int w = is_vertical ? base_height : length;
            int h = is_vertical ? length : base_height;
            set_size_request(w, h);
            resize(w, h);
        }

        // A layer surface's keyboard mode only reaches the compositor on the surface's
        // next commit, which would otherwise wait for the dock to redraw. Force one.
        private void set_layer_shell_keyboard_mode(GtkLayerShell.KeyboardMode mode) {
            GtkLayerShell.set_keyboard_mode(this, mode);
            GtkLayerShell.try_force_commit(this);
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

        // Plugins live as long as the dock, but load_plugins() runs on every reload. Connect
        // each plugin's signals only the first time, or every reload would add another
        // handler and each media change would run once per reload.
        private HashTable<Object, bool> wired_plugins = new HashTable<Object, bool>(direct_hash, direct_equal);

        private bool wire_once(Object plugin) {
            if (wired_plugins.contains(plugin)) return false;
            wired_plugins.set(plugin, true);
            return true;
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
                    if (wire_once(media)) {
                        media.changed.connect(() => {
                            update_media_widget(media);
                            schedule_redraw();
                        });
                    }
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
                    if (wire_once(sp)) sp.updated.connect(() => schedule_redraw());
                }
            }

            if (config.get_plugin_enabled("show-desktop")
                && Capabilities.current.supports(Feature.WINDOW_TRACKING)) {
                var p = plugin_manager.get_plugin("show-desktop");
                if (p != null) items.append(new DockItem.from_plugin(p));
            }
            if (config.get_plugin_enabled("trash")) {
                var trash = plugin_manager.get_plugin("trash") as TrashPlugin;
                if (trash != null) {
                    items.append(new DockItem.from_plugin(trash));
                    if (wire_once(trash)) {
                        trash.changed.connect(() => {
                            renderer.clear_icon_cache("user-trash");
                            renderer.clear_icon_cache("user-trash-full");
                            schedule_redraw();
                        });
                    }
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
            // Always reserve room for the gap that opens while dropping or
            // reordering. Without it a dock sized exactly to its content
            // (magnification 1.0) is clipped by the window edge, losing its
            // rounded corners and border.
            total += renderer.spacing * 2;
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
                size_layer_shell_surface();
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
                if (!window.is_application_window) continue;

                // Skip minimized windows — not visible on screen
                if (window.is_minimized) continue;

                // Skip Dokku's own windows
                if (window.is_dokku_window()) continue;

                // Check if window is on the same monitor
                if (!window.is_on_monitor(mon_geo)) continue;

                // Maximized or fullscreen window on this monitor → dodge. This is all
                // Wayland can tell us: it doesn't report where a window is.
                if (window.is_maximized || window.is_fullscreen) {
                    set_dodge_hiding(true);
                    return;
                }

                // Check rectangle intersection with dock
                Gdk.Rectangle wrect;
                if (window.get_geometry(out wrect) &&
                    wrect.x < dock_rect.x + dock_rect.width &&
                    wrect.x + wrect.width > dock_rect.x &&
                    wrect.y < dock_rect.y + dock_rect.height &&
                    wrect.y + wrect.height > dock_rect.y) {
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
                    item.windows = new List<weak TrackedWindow>();
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
            if (blur_backdrop.is_active) {
                int dx, dy;
                get_position(out dx, out dy);
                sync_blur_bg(dx, dy, width, height, dock_dim);
            }

            draw_dock_background(cr, dock_dim);
            draw_items_with_layout(cr, width, height, layout_scales, dock_dim);

            update_input_shape(dock_dim);

            return false;
        }

        // What update_input_shape() last sent to the server, so identical frames
        // (animations, media updates) don't allocate a region and make an X request.
        private bool input_shape_known = false;
        private bool input_shape_cleared = false;
        private Cairo.RectangleInt input_shape_rect;

        private void update_input_shape(double dock_dim) {
            var window = get_window();
            if (window == null) return;

            if (auto_hide || dodge_hiding) {
                if (!input_shape_known || !input_shape_cleared) {
                    window.input_shape_combine_region(null, 0, 0);
                    input_shape_known = true;
                    input_shape_cleared = true;
                }
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

            if (input_shape_known && !input_shape_cleared
                && rect.x == input_shape_rect.x && rect.y == input_shape_rect.y
                && rect.width == input_shape_rect.width && rect.height == input_shape_rect.height) {
                return;
            }
            input_shape_rect = rect;
            input_shape_known = true;
            input_shape_cleared = false;
            window.input_shape_combine_region(new Cairo.Region.rectangle(rect), 0, 0);
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
            // Blur is handled by the separate backdrop window (not the main dock).
            // Always remove _DOKKU_BLUR from the main dock so picom never blurs
            // behind it (which would cause a rectangle artifact over the full
            // window area including the magnification zone).
            CompositorHints.apply(gdk_window, false);
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

        // Frosted glass: a separate transparent window behind the capsule gets
        // the compositor blur (see BlurBackdrop).
        private void ensure_blur_bg() {
            blur_backdrop.set_enabled(blur_enabled && !use_layer_shell);
            // Clear any leftover bounding shape from the main window
            var gdk_window = get_window();
            if (gdk_window != null) {
                gdk_window.shape_combine_region(null, 0, 0);
            }
        }

        // dock_dim < 0 uses the rest length (reposition/resize); on_draw passes
        // the live value so the blur follows magnification.
        private void sync_blur_bg(int dock_x, int dock_y, int dock_w, int dock_h,
                                   double dock_dim = -1) {
            if (!blur_backdrop.is_active) return;
            if (dock_dim < 0) dock_dim = calculate_rest_dock_length();
            blur_backdrop.sync(dock_x, dock_y, dock_w, dock_h, dock_dim,
                               dock_position, icon_area_height);
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

        // 0..1: how far the dragged icon is past the remove threshold
        private double drag_remove_progress() {
            double away = compute_away_distance(drag_mouse_cross);
            return ((away - REMOVE_THRESHOLD) / REMOVE_THRESHOLD).clamp(0, 1);
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
                        if (!drag_float.show(drag_item, renderer.icon_size, is_light_theme(),
                                             use_layer_shell, drag_remove_progress)) {
                            drag_removing = false;
                        }
                    }
                    if (drag_float.is_active) {
                        drag_float.move_to(event.x_root, event.y_root);
                    }
                } else {
                    // Back on dock — destroy popup and resume normal reorder
                    drag_float.destroy();
                    reorder_insert_index = get_reorder_target_index(main_coord);
                }
            }

            // Hover popup: multi-window apps get preview, others get name tooltip
            if (hovered_index >= 0 && !is_reordering && !folder_popup.is_open) {
                var hovered_item = items.nth_data(hovered_index);
                if (hovered_item != null && hovered_item.running && hovered_item.windows.length() > 1) {
                    // Multi-window: window preview popup after 400ms
                    if (preview.target_index != hovered_index) {
                        preview.cancel_timer();
                        preview.dismiss();
                        preview.request(hovered_index, 400, true);
                    } else {
                        preview.cancel_dismiss();
                    }
                } else if (hovered_item != null && !hovered_item.is_separator
                           && !hovered_item.is_media_widget) {
                    // Single/zero-window or non-running: name tooltip after 300ms
                    if (preview.target_index != hovered_index) {
                        preview.cancel_timer();
                        preview.dismiss();
                        preview.request(hovered_index, 300, false);
                    } else {
                        preview.cancel_dismiss();
                    }
                } else {
                    preview.cancel_timer();
                    preview.dismiss();
                }
            } else {
                preview.cancel_timer();
            }

            schedule_redraw();
            return true;
        }

        private bool on_enter(Gdk.EventCrossing event) {
            hovering = true;
            if (hide_timeout_id != 0) { Source.remove(hide_timeout_id); hide_timeout_id = 0; }
            if (launch_rehide_timeout_id != 0) { Source.remove(launch_rehide_timeout_id); launch_rehide_timeout_id = 0; }
            media_popup.cancel_dismiss();
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

            preview.cancel_timer();
            preview.schedule_dismiss();
            media_popup.schedule_dismiss();

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

        // Index of the folder whose popup this click just closed, so releasing on the
        // same folder doesn't immediately reopen it (clicking a folder again closes it).
        private int folder_closed_by_press = -1;

        // Escape closes an open folder popup. (While a popup holds keyboard focus the
        // compositor may deliver the key to the dock rather than to the popup.)
        private bool on_key_press(Gdk.EventKey event) {
            if (event.keyval == Gdk.Key.Escape && folder_popup.is_open) {
                folder_popup.dismiss();
                return true;
            }
            return false;
        }

        private bool on_button_press(Gdk.EventButton event) {
            if (is_reordering) return true;  // Ignore during active drag
            double main_coord = is_vertical ? event.y : event.x;

            // A click on the dock closes an open folder popup, and hides any tooltip
            folder_closed_by_press = folder_popup.open_index;
            folder_popup.dismiss();
            preview.cancel_timer();
            preview.dismiss();
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
                        drag_float.poof();
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
            if (!drag_float.is_poofing) {
                drag_float.destroy();
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
                preview.cancel_timer();
                preview.schedule_dismiss();
                media_popup.schedule_dismiss();
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
            if (item.is_folder) {
                if (folder_closed_by_press == index) {
                    folder_closed_by_press = -1;  // this click closed it; don't reopen
                } else {
                    folder_popup.show(item, index);
                }
                return;
            }
            if (item.is_media_widget && item.plugin is MediaPlugin) {
                var mp = item.plugin as MediaPlugin;
                if (is_vertical) {
                    media_popup.show(mp, index);
                    return;
                }
                double item_start, item_w;
                get_item_bounds(index, out item_start, out item_w);
                // Compute button positions matching the renderer layout
                double widget_w = renderer.icon_size * item.dock_width_factor;
                double pad = 6;
                int ctrl_sz = 20;
                double skip_x = item_start + widget_w - pad - ctrl_sz;
                if (click_x >= skip_x && click_x <= skip_x + ctrl_sz) {
                    mp.next();
                } else {
                    mp.activate();  // play/pause button, or anywhere else on the widget
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
                var mi = new Gtk.MenuItem.with_label(window.title);
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

            // Dock Settings lives only on the Applications button
            if (item.is_launcher) {
                var st = new Gtk.MenuItem.with_label("Dock Settings...");
                st.activate.connect(() => settings_requested());
                context_menu.append(st);
                context_menu.show_all();
                context_menu.popup_at_pointer(event);
                return;
            }

            if (item.running) {
                var nw = new Gtk.MenuItem.with_label("New Window");
                nw.activate.connect(() => { var a = app_manager.get_app(item.id); if (a != null) { usage_tracker.record_launch(item.id); a.launch(); trigger_bounce(item.id, true); } });
                context_menu.append(nw);
            }

            // Recent files submenu
            if (item.desktop_file != null && item.desktop_file != "") {
                var recent_submenu = RecentFilesMenu.build(item, app_manager, this);
                if (recent_submenu != null) {
                    var recent_mi = new Gtk.MenuItem.with_label("Recent Files");
                    recent_mi.submenu = recent_submenu;
                    context_menu.append(recent_mi);
                }
            }

            if (item.running || (item.desktop_file != null && item.desktop_file != "")) {
                context_menu.append(new Gtk.SeparatorMenuItem());
            }

            var options = new Gtk.Menu();
            if (item.pinned) {
                var unpin = new Gtk.MenuItem.with_label("Unpin from Dock");
                unpin.activate.connect(() => {
                    if (item.running) item.pinned = false; else items.remove(item);
                    save_pinned_apps(); schedule_redraw();
                });
                options.append(unpin);
            } else {
                var pin = new Gtk.MenuItem.with_label("Pin to Dock");
                pin.activate.connect(() => { item.pinned = true; save_pinned_apps(); schedule_redraw(); });
                options.append(pin);
            }
            var props = new Gtk.MenuItem.with_label("Properties...");
            props.activate.connect(() => properties_dialog.show(item));
            options.append(props);
            var options_mi = new Gtk.MenuItem.with_label("Options");
            options_mi.submenu = options;
            context_menu.append(options_mi);

            if (item.running && item.windows.length() > 0) {
                context_menu.append(new Gtk.SeparatorMenuItem());
                var hide = new Gtk.MenuItem.with_label("Hide");
                hide.activate.connect(() => {
                    foreach (var window in item.windows) {
                        if (!window.is_minimized) window.minimize();
                    }
                });
                context_menu.append(hide);

                var quit = new Gtk.MenuItem.with_label("Quit");
                quit.activate.connect(() => AppQuit.quit.begin(item.id, item.windows));
                context_menu.append(quit);

                // Force Close only shows when Shift is held as the menu opens. Wayland doesn't
                // tell us another window's PID, so there it has nothing to kill.
                if ((event.state & Gdk.ModifierType.SHIFT_MASK) != 0 &&
                    item.windows.nth_data(0).get_pid() > 0) {
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
            }

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
            dodge_windows = config.get_dodge_windows() && Capabilities.current.supports(Feature.DODGE_WINDOWS);
            rounded_corners = config.get_rounded_corners();
            dock_opacity = config.get_dock_opacity();

            // Compositor blur hint
            blur_enabled = config.get_blur_enabled() && Capabilities.current.supports(Feature.COMPOSITOR_BLUR);
            update_compositor_hints();
            ensure_blur_bg();
            // Re-apply bounding shape in case rounded_corners changed
            blur_backdrop.apply_shape();

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

            // Reposition and resize dock (and the blur backdrop) to reflect new item count.
            // On layer-shell this resizes the surface; the compositor does the positioning.
            position_dock();
        }

        // --- Bounce animation ---

        private void on_attention_requested(TrackedWindow window) {
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
            // Frame-synced like the other animations (a 16ms timer could draw twice per
            // frame or miss one), and removed automatically if the dock is destroyed.
            progress_tick_id = add_tick_callback((widget, frame_clock) => {
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

        // --- Window preview popup ---

        // --- PopupHost ---

        public DockItem? popup_item(int index) {
            return items.nth_data(index);
        }

        public Theme? popup_theme() {
            return current_theme;
        }

        public bool popup_is_light() {
            return is_light_theme();
        }

        public Gtk.Window? popup_parent() {
            return Capabilities.current.session == SessionType.WAYLAND ? this : null;
        }

        public void show_popup(Gtk.Window popup, int index, int gap, bool modal = false) {
            if (Capabilities.current.session != SessionType.WAYLAND) {
                // X11: absolute screen coordinates, which need the popup's size
                popup.show_all();
                int popup_w, popup_h;
                popup.get_size(out popup_w, out popup_h);
                int px, py;
                compute_popup_position(index, popup_w, popup_h, gap, out px, out py);
                popup.move(px, py);
                if (modal) PopupHelper.grab(popup, false);
                return;
            }

            // Wayland: ask the compositor to place the popup against an anchor
            // rectangle on the dock itself (coordinates are relative to the dock window)
            double item_start, item_w;
            get_item_bounds(index, out item_start, out item_w);
            int dw = get_allocated_width();
            int dh = get_allocated_height();
            int cap = icon_area_height + 2;  // the capsule's thickness
            Gdk.Rectangle rect;
            Gdk.Gravity rect_anchor, popup_anchor;
            int dx = 0, dy = 0;
            if (dock_position == "top") {
                rect = { (int)item_start, 0, (int)item_w, cap };
                rect_anchor = Gdk.Gravity.SOUTH; popup_anchor = Gdk.Gravity.NORTH; dy = gap;
            } else if (dock_position == "left") {
                rect = { 0, (int)item_start, cap, (int)item_w };
                rect_anchor = Gdk.Gravity.EAST; popup_anchor = Gdk.Gravity.WEST; dx = gap;
            } else if (dock_position == "right") {
                rect = { dw - cap, (int)item_start, cap, (int)item_w };
                rect_anchor = Gdk.Gravity.WEST; popup_anchor = Gdk.Gravity.EAST; dx = -gap;
            } else { // bottom
                rect = { (int)item_start, dh - cap, (int)item_w, cap };
                rect_anchor = Gdk.Gravity.NORTH; popup_anchor = Gdk.Gravity.SOUTH; dy = -gap;
            }

            // The window must exist before it can be positioned, and be placed before it is shown
            popup.realize();
            var gdk_popup = popup.get_window();
            if (gdk_popup != null) {
                gdk_popup.move_to_rect(rect, rect_anchor, popup_anchor,
                    Gdk.AnchorHints.FLIP | Gdk.AnchorHints.SLIDE, dx, dy);
            }
            // The dock asks for no keyboard input, so the compositor would never send
            // Escape to a popup of it. Take keyboard focus while a modal popup is open
            // (like a menu does) and give it back when the popup goes away.
            if (modal && use_layer_shell) {
                set_layer_shell_keyboard_mode(GtkLayerShell.KeyboardMode.EXCLUSIVE);
                popup.destroy.connect(() => {
                    set_layer_shell_keyboard_mode(GtkLayerShell.KeyboardMode.NONE);
                });
            }

            // A Wayland popup grab has to be requested before the popup is mapped
            if (!(modal && PopupHelper.grab(popup, true))) {
                popup.show_all();
            }
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
    }
}
