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
        // The separator's line is this long; it also gets the usual spacing around it
        private const int SEPARATOR_LINE = 18;

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

        private ProgressMonitor progress_monitor;
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

        public DockWindow(Gtk.Application app, AppManager app_manager, ConfigManager config,
                          UsageTracker usage_tracker, PluginManager plugin_manager,
                          ThemeManager theme_manager, ProgressMonitor progress_monitor) {
            Object(application: app);

            use_layer_shell = GtkLayerShell.is_supported();

            if (use_layer_shell) {
                GtkLayerShell.init_for_window(this);
                GtkLayerShell.set_layer(this, GtkLayerShell.Layer.TOP);
                GtkLayerShell.set_namespace(this, "dokku");
                // Anchors set after dock_position is loaded (below)
            }

            // Always set these: DOCK type hint tells the WM and compositor
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
            this.plugin_manager = plugin_manager;
            this.theme_manager = theme_manager;
            items = new List<DockItem>();
            bounce_cooldowns = new HashTable<string, int64?>(str_hash, str_equal);

            blur_enabled = blur_wanted();

            load_theme();
            rebuild_items();

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
                       Gdk.EventMask.BUTTON_RELEASE_MASK |
                       Gdk.EventMask.SCROLL_MASK |
                       Gdk.EventMask.SMOOTH_SCROLL_MASK);

            // Enable drag-and-drop for .desktop files (no HIGHLIGHT: we draw our own indicator)
            Gtk.drag_dest_set(this, 0, DROP_TARGETS, Gdk.DragAction.COPY);
            drag_data_received.connect(on_drag_data_received);
            drag_drop.connect(on_drag_drop);
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

            this.progress_monitor = progress_monitor;
            progress_monitor.progress_changed.connect(on_progress_changed);

            draw.connect(on_draw);
            motion_notify_event.connect(on_motion);
            leave_notify_event.connect(on_leave);
            enter_notify_event.connect(on_enter);
            button_press_event.connect(on_button_press);
            key_press_event.connect(on_key_press);
            button_release_event.connect(on_button_release);
            scroll_event.connect(on_scroll);

            this.destroy.connect(() => {
                // Pointer grab
                if (is_reordering) {
                    PopupHelper.ungrab(this);
                    is_reordering = false;
                }
                drag_float.destroy();

                // Timeouts
                if (dodge_check_timeout_id != 0) { Source.remove(dodge_check_timeout_id); dodge_check_timeout_id = 0; }
                cancel_hide_timers();

                // The monitors outlive this dock
                progress_monitor.progress_changed.disconnect(on_progress_changed);
                set_notification_monitor(null);

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

            dodge_windows = config.get_dodge_windows() && Capabilities.current.supports(Feature.DODGE_WINDOWS);
            apply_monitor_settings();
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
            // This monitor may have settings of its own (another edge, another icon size)
            string key = MonitorKey.for_monitor(Gdk.Display.get_default(), monitor);
            if (key != monitor_key
                || config.get_position_for(key) != dock_position
                || config.get_icon_size_for(key) != renderer.icon_size
                || config.get_auto_hide_for(key) != auto_hide) {
                reload_settings();
            }
        }

        // The name of the monitor this dock is on, for the settings kept per monitor
        private string monitor_key = "";

        // Position, icon size and auto-hide: the monitor's own setting where it has one,
        // otherwise the one for all monitors
        private void apply_monitor_settings() {
            monitor_key = MonitorKey.for_monitor(Gdk.Display.get_default(), get_dock_monitor());
            dock_position = config.get_position_for(monitor_key);
            is_vertical = (dock_position == "left" || dock_position == "right");
            renderer.icon_size = config.get_icon_size_for(monitor_key);
            auto_hide = config.get_auto_hide_for(monitor_key);
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
            return UiUtil.primary_monitor();
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
#if HAVE_LAYER_SHELL_FORCE_COMMIT
            GtkLayerShell.try_force_commit(this);
#else
            // gtk-layer-shell before 0.9 cannot force a commit; a redraw makes GTK send one
            queue_draw();
#endif
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

            // Media widget: inserted right after separator
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
                var sp = up as ScriptPlugin;
                if (sp == null || !sp.is_widget) continue;
                if (wire_once(sp)) sp.updated.connect(() => on_widget_plugin_updated(sp));
                if (!config.get_plugin_enabled(up.id, sp.enabled_by_default)) continue;
                if (!sp.visible_in_dock) continue;
                var widget_item = new DockItem.from_plugin(sp);
                widget_item.name = sp.tooltip;
                items.append(widget_item);
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
                        trash.trash_finished.connect((ok, count) => {
                            if (ok) return;
                            int trash_index = 0;
                            foreach (var item in items) {
                                if (item.plugin == trash) {
                                    preview.flash(trash_index, "Couldn't move to the Trash", 2200);
                                    break;
                                }
                                trash_index++;
                            }
                        });
                        trash.changed.connect(() => {
                            renderer.clear_icon_cache("user-trash");
                            renderer.clear_icon_cache("user-trash-full");
                            schedule_redraw();
                        });
                    }
                }
            }
        }

        private uint widget_reload_id = 0;

        // A widget plugin has new text. Its tooltip follows, and a widget that appeared or
        // went away (a battery widget when a battery is plugged in) changes what the dock holds.
        private void on_widget_plugin_updated(ScriptPlugin sp) {
            bool shown = false;
            int index = 0;
            foreach (var item in items) {
                if (item.plugin == sp) {
                    shown = true;
                    item.name = sp.tooltip;
                    // A tooltip already open over the widget follows its new text
                    preview.update_tooltip_text(index, sp.tooltip);
                }
                index++;
            }
            bool wanted = config.get_plugin_enabled(sp.id, sp.enabled_by_default) && sp.visible_in_dock;
            if (wanted != shown && widget_reload_id == 0) {
                widget_reload_id = Idle.add(() => {
                    widget_reload_id = 0;
                    reload_settings();
                    return Source.REMOVE;
                });
            }
            schedule_redraw();
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
                bool magnifies = !(item.is_media_widget || item.is_launcher);
                total += (int) item_length(item, magnifies ? renderer.magnification : 1.0);
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

        private void set_hidden(bool hide) {
            hidden = hide;
            animate_slide(hide ? 1.0 : 0.0);
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
                dock_slide_offset = slide_from + (slide_to - slide_from) * UiUtil.ease_out_cubic(t);
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

            if (dock_position == "left" || dock_position == "right") {
                rect.width = capsule;
                rect.height = dock_length;
                rect.x = dock_position == "left" ? geo.x + dock_margin_bottom
                                                 : geo.x + geo.width - rect.width - dock_margin_bottom;
                rect.y = geo.y + (geo.height - rect.height) / 2;
            } else {  // top or bottom
                rect.width = dock_length;
                rect.height = capsule;
                rect.x = geo.x + (geo.width - rect.width) / 2;
                rect.y = dock_position == "top" ? geo.y + dock_margin_bottom
                                                : geo.y + geo.height - rect.height - dock_margin_bottom;
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

                // Skip minimized windows: not visible on screen
                if (window.is_minimized) continue;

                // Skip Dokku's own windows
                if (window.is_dokku_window()) continue;

                // Check if window is on the same monitor
                if (!window.is_on_monitor(mon_geo)) continue;

                // Maximized or fullscreen window on this monitor -> dodge. This is all
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
                set_hidden(true);
            } else if (!should_hide && hidden && !auto_hide) {
                set_hidden(false);
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

        private const double INDICATOR_FADE_MS = 250;
        private uint indicator_tick_id = 0;
        private int64 indicator_last_us = 0;

        private static double approach(double value, double target, double step) {
            if (value < target) return double.min(target, value + step);
            return double.max(target, value - step);
        }

        // Eases every item's indicator dots toward what they should show now: the running
        // dots when it has windows, the amber dot when it lives on in the background. Runs
        // on the frame clock and stops once everything has arrived.
        private void start_indicator_fade() {
            if (indicator_tick_id != 0) return;
            indicator_last_us = 0;
            indicator_tick_id = add_tick_callback((widget, frame_clock) => {
                int64 now = frame_clock.get_frame_time();
                double step = indicator_last_us == 0 ? 0.0
                    : (now - indicator_last_us) / 1000.0 / INDICATOR_FADE_MS;
                indicator_last_us = now;
                bool moving = false;
                foreach (var item in items) {
                    if (item.is_plugin || item.is_launcher) continue;
                    double dots_target = item.running ? 1.0 : 0.0;
                    double bg_target = (item.background && !item.running) ? 1.0 : 0.0;
                    item.dot_fade = approach(item.dot_fade, dots_target, step);
                    item.bg_fade = approach(item.bg_fade, bg_target, step);
                    if (item.dot_fade != dots_target || item.bg_fade != bg_target) moving = true;
                }
                queue_draw();
                if (!moving) indicator_tick_id = 0;
                return moving;
            });
        }

        private const uint BACKGROUND_CHECK_MS = 200;
        private uint background_poll_id = 0;

        // An app has had no window for a moment: if its process is still alive and has a tray
        // icon, the dock keeps showing it (amber dot) until it exits
        private async void check_background(string id) {
            foreach (var item in items) {
                if (item.id != id || item.running || item.quitting || item.is_plugin || item.is_launcher) continue;
                int[] alive = live_pids(item.pids);
                if (alive.length == 0) alive = AppQuit.find_pids(item, new List<weak TrackedWindow>());
                if (alive.length == 0) return;
                // A daemon with no tray icon is not shown: only tray apps are worth a dot
                bool tray = yield TrayIcons.owned_by(alive);
                if (!tray || item.running || item.quitting || item.background) return;
                item.pids = alive;
                item.background = true;
                start_indicator_fade();
                if (background_poll_id == 0)
                    background_poll_id = Timeout.add(500, poll_background);
                schedule_redraw();
                return;
            }
        }

        private int[] live_pids(int[] pids) {
            int[] alive = {};
            foreach (var pid in pids) if (AppQuit.is_alive(pid)) alive += pid;
            return alive;
        }

        // Ends the background state of apps whose process has gone; stops once none are left
        private bool poll_background() {
            bool any = false;
            bool changed = false;
            var gone = new List<DockItem>();
            foreach (var item in items) {
                if (!item.background) continue;
                item.pids = live_pids(item.pids);
                if (item.pids.length > 0) { any = true; continue; }
                item.background = false;
                changed = true;
                if (!item.pinned) gone.append(item);
            }
            foreach (var item in gone) items.remove(item);
            if (changed) { position_dock(); start_indicator_fade(); schedule_redraw(); }
            if (!any) background_poll_id = 0;
            return any;
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
            // Hold the background state through this update: it ends when a window comes
            // back or the process is gone, never merely because there is no window

            foreach (var window in windows) {
                var app = app_manager.find_by_window(window);
                if (app == null) continue;

                bool found = false;
                foreach (var item in items) {
                    if (item.is_launcher || item.is_plugin) continue;
                    if (item.id == app.id) {
                        item.running = true;
                        item.background = false;
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

            // Remember each running app's processes; an app that just lost its last window
            // is checked shortly for one that stays alive in the background
            foreach (var item in items) {
                if (item.is_plugin || item.is_launcher) continue;
                if (item.running) {
                    item.dots = int.min((int) item.windows.length(), 3);
                    int[] found = {};
                    foreach (var window in item.windows) {
                        int pid = window.get_pid();
                        if (pid > 1 && !(pid in found)) found += pid;
                    }
                    if (found.length > 0) item.pids = found;
                } else if (was_running.contains(item.id)) {
                    string id = item.id;
                    Timeout.add(BACKGROUND_CHECK_MS, () => { check_background.begin(id); return false; });
                }
            }

            var to_remove = new List<DockItem>();
            foreach (var item in items) {
                if (!item.pinned && !item.running && !item.background && !item.is_plugin && !item.is_launcher)
                    to_remove.append(item);
            }
            foreach (var item in to_remove) items.remove(item);

            // Bounce any app that just became running (newly launched)
            // Skip on initial load: these apps were already running before the dock started
            if (initial_load_done) {
                foreach (var item in items) {
                    if (item.running && !was_running.contains(item.id)) {
                        trigger_bounce(item.id, true);
                    }
                }
            } else {
                initial_load_done = true;
                // Apps already running when the dock starts show their dots at once
                foreach (var item in items) {
                    item.dot_fade = item.running ? 1.0 : 0.0;
                    item.bg_fade = 0.0;
                }
                // Pinned apps already running hidden in the tray when the dock starts
                foreach (var item in items) {
                    if (item.running || item.is_plugin || item.is_launcher || !item.pinned) continue;
                    string id = item.id;
                    Timeout.add(BACKGROUND_CHECK_MS, () => { check_background.begin(id); return false; });
                }
            }

            position_dock();
            start_indicator_fade();
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
            UiUtil.clear(cr);

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

            // Sync blur background to the current dock_dim: this makes the
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
                    window.input_shape_combine_region((Cairo.Region) null, 0, 0);  // null: the whole window takes input
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
            double mouse_pos = along(mouse_x, mouse_y);

            // Calculate base dimension and positions for scale calculation
            double base_dim = 0;
            foreach (var item in items) base_dim += item_length(item);

            double pos = (container_size - base_dim) / 2.0;
            int i = 0;
            foreach (var item in items) {
                double item_len = item_length(item);
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
                if (active_gap >= 0 && i == active_gap && (!is_reordering || i != drag_index))
                    actual_width += gap_width;
                actual_width += item_length(item, scales[i]);
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

            // Outer shadow: soft dark glow behind the dock for depth
            if (radius > 0) {
                double shadow_alpha = light ? 0.10 : 0.20;
                DockRenderer.draw_rounded_rect(cr, x - 1, y + 1, w + 2, h + 1, radius + 2);
                cr.set_source_rgba(0, 0, 0, shadow_alpha * dock_opacity);
                cr.fill();
            }

            // --- Background fill ---
            DockRenderer.draw_rounded_rect(cr, x, y, w, h, radius);
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
                DockRenderer.draw_rounded_rect(cr, x + inset, y + inset, w - bw, h - bw, radius - inset);
                if (light) {
                    cr.set_source_rgba(1, 1, 1, 0.55 * dock_opacity);
                } else {
                    cr.set_source_rgba(1, 1, 1, 0.18 * dock_opacity);
                }
                cr.set_line_width(bw);
                cr.stroke();

                // Top edge glint
                cr.save();
                DockRenderer.draw_rounded_rect(cr, x, y, w, h, radius);
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
                DockRenderer.draw_rounded_rect(cr, x, y, w, h, 0);
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
            foreach (var item in items) total += item_length(item);
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
            double mouse_coord = along(mouse_x, mouse_y);
            // Compute once outside the loop: this value is invariant per frame
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

                double item_len = item_length(item, scales[i]);
                if (is_reordering && i == drag_index) {
                    pos += item_len;
                    i++;
                    continue;
                }

                double sz = renderer.icon_size * scales[i];
                // Centred on the item itself: the spacing is trailing room after it
                double main_pos = pos + (item_len - renderer.spacing) / 2.0;

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
            renderer.set_indicator_color(cr, 0.55);
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
            double main_coord = along(event.x, event.y);
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
                    // Back on dock: destroy popup and resume normal reorder
                    drag_float.destroy();
                    reorder_insert_index = get_insert_index(main_coord);
                }
            }

            update_hover_popups();
            schedule_redraw();
            return true;
        }

        // The now-playing popup on the media widget, a window preview on an app with
        // several windows, a name tooltip on anything else
        private void update_hover_popups() {
            DockItem? item = null;
            if (hovered_index >= 0 && !is_reordering && !folder_popup.is_open) {
                item = items.nth_data(hovered_index);
            }
            if (item == null) {
                preview.cancel_timer();
                media_popup.cancel_request();
                media_popup.schedule_dismiss();
                return;
            }

            if (item.is_media_widget && item.plugin is MediaPlugin) {
                // The popup opens once the pointer rests on the widget
                preview.cancel_timer();
                preview.dismiss();
                media_popup.request(item.plugin as MediaPlugin, hovered_index);
                return;
            }
            media_popup.cancel_request();
            media_popup.schedule_dismiss();

            if (item.is_separator || item.is_media_widget) {
                preview.cancel_timer();
                preview.dismiss();
            } else if (preview.target_index != hovered_index) {
                bool windows = item.running && item.windows.length() > 1;
                preview.cancel_timer();
                preview.dismiss();
                preview.request(hovered_index, windows ? 400 : 300, windows);
            } else {
                preview.cancel_dismiss();
            }
        }

        private bool on_enter(Gdk.EventCrossing event) {
            hovering = true;
            cancel_hide_timers();
            media_popup.cancel_dismiss();
            if ((auto_hide || dodge_hiding) && hidden) set_hidden(false);
            schedule_redraw();
            return true;
        }

        private bool on_leave(Gdk.EventCrossing event) {
            // During a pointer-grabbed reorder the cursor leaves the window
            // geometry but we keep getting events: don't reset anything.
            if (is_reordering) {
                return true;
            }

            pointer_left();
            schedule_redraw();
            return true;
        }

        // The pointer is no longer over the dock: stop hovering, close hover popups and,
        // if the dock hides itself, start the countdown to hide
        private void pointer_left() {
            hovering = false;
            mouse_x = -1;
            mouse_y = -1;
            hovered_index = -1;

            preview.cancel_timer();
            preview.schedule_dismiss();
            media_popup.cancel_request();
            media_popup.schedule_dismiss();

            if ((auto_hide || dodge_hiding) && !hidden) {
                hide_timeout_id = Timeout.add(config.get_hide_delay(), () => {
                    hide_timeout_id = 0;
                    set_hidden(true);
                    return false;
                });
            }
        }

        private void cancel_hide_timers() {
            if (hide_timeout_id != 0) { Source.remove(hide_timeout_id); hide_timeout_id = 0; }
            if (launch_rehide_timeout_id != 0) { Source.remove(launch_rehide_timeout_id); launch_rehide_timeout_id = 0; }
        }

        // What the drag in progress carries, found while it is still over the dock
        private Gdk.DragContext? peek_context = null;
        private bool peek_ready = false;
        private bool peek_has_files = false;
        private bool peek_any = false;
        private bool dropping = false;
        // App the pointer is over while dragging files, or -1
        private int drop_open_index = -1;

        private static bool is_desktop_uri(string uri) {
            return uri.has_suffix(".desktop");
        }

        // An item that stands for an application a file can be opened with
        private bool can_open_files_with(DockItem item) {
            if (item.is_launcher || item.is_folder || item.is_separator || item.is_plugin) return false;
            var app = app_manager.get_app(item.id);
            return app != null && app.can_open_files();
        }

        private bool on_drag_drop(Gdk.DragContext context, int x, int y, uint time) {
            // Ask for the data again; the answer arrives in on_drag_data_received
            dropping = true;
            Gtk.drag_get_data(this, context, Gdk.Atom.intern("text/uri-list", false), time);
            return true;
        }

        private void clear_file_drop_state() {
            peek_context = null;
            peek_ready = false;
            peek_has_files = false;
            peek_any = false;
            if (drop_open_index >= 0) {
                drop_open_index = -1;
                hovering = false;
                mouse_x = -1;
                mouse_y = -1;
                hovered_index = -1;
                schedule_redraw();
            }
        }

        private void on_drag_data_received(Gdk.DragContext context, int x, int y,
                                           Gtk.SelectionData data, uint info, uint time) {
            var uris = data.get_uris();

            if (!dropping) {
                // The look at the drag that on_drag_motion asked for
                peek_has_files = false;
                peek_any = uris.length > 0;
                foreach (var uri in uris) {
                    if (!is_desktop_uri(uri)) { peek_has_files = true; break; }
                }
                peek_ready = true;
                return;
            }
            dropping = false;

            // Anything dropped on the Trash goes into it
            int over_drop = get_item_at(along(x, y));
            var over_drop_item = over_drop >= 0 ? items.nth_data(over_drop) : null;
            if (over_drop_item != null && over_drop_item.plugin is TrashPlugin && uris.length > 0) {
                var trash_plugin = (TrashPlugin) over_drop_item.plugin;
                int sent = trash_plugin.trash_uris(uris);
                if (sent == 0) preview.flash(over_drop, "That can't be moved to the Trash", 1800);
                finish_drop(context, sent > 0, time);
                return;
            }

            // Files dropped on an app open in it
            var files = new List<string>();
            foreach (var uri in uris) {
                if (!is_desktop_uri(uri)) files.append(uri);
            }
            if (files.length() > 0) {
                int target = get_item_at(along(x, y));
                var target_item = target >= 0 ? items.nth_data(target) : null;
                bool opened = false;
                if (target_item != null && can_open_files_with(target_item)) {
                    var app = app_manager.get_app(target_item.id);
                    opened = app.open_files(files);
                    if (opened) {
                        usage_tracker.record_launch(target_item.id);
                        trigger_bounce(target_item.id, true);
                    }
                }
                finish_drop(context, opened, time);
                return;
            }

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
            save_pinned_apps();
            finish_drop(context, true, time);
        }

        private void finish_drop(Gdk.DragContext context, bool success, uint time) {
            clear_file_drop_state();
            drop_insert_index = -1;
            position_dock();
            schedule_redraw();
            Gtk.drag_finish(context, success, false, time);
        }

        // Close the gap opened for a dragged launcher entry
        private void close_drop_gap() {
            if (drop_insert_index < 0) return;
            drop_insert_index = -1;
            position_dock();
        }

        // Treat the pointer as hovering item `index` (drag-over magnifies the target)
        private void hover_for_drop(int index, int x, int y) {
            drop_open_index = index;
            hovering = true;
            mouse_x = x;
            mouse_y = y;
            hovered_index = index;
        }

        private bool on_drag_motion(Gdk.DragContext context, int x, int y, uint time) {
            if (peek_context != context) {
                peek_context = context;
                peek_ready = false;
                peek_has_files = false;
                Gtk.drag_get_data(this, context, Gdk.Atom.intern("text/uri-list", false), time);
            }

            // The Trash takes anything: it is the target, whatever is being dragged
            if (peek_ready && peek_any) {
                int hover = get_item_at(along(x, y));
                var hover_item = hover >= 0 ? items.nth_data(hover) : null;
                if (hover_item != null && hover_item.plugin is TrashPlugin) {
                    close_drop_gap();
                    Gdk.drag_status(context, Gdk.DragAction.COPY, time);
                    hover_for_drop(hover, x, y);
                    schedule_redraw();
                    return true;
                }
            }

            // Files, not .desktop entries: the icon under the pointer is the target
            if (peek_ready && peek_has_files) {
                close_drop_gap();
                int over = get_item_at(along(x, y));
                var over_item = over >= 0 ? items.nth_data(over) : null;
                if (over_item != null && can_open_files_with(over_item)) {
                    Gdk.drag_status(context, Gdk.DragAction.COPY, time);
                    hover_for_drop(over, x, y);  // the hover magnification marks the target
                } else {
                    Gdk.drag_status(context, 0, time);
                    if (drop_open_index >= 0) {
                        drop_open_index = -1;
                        mouse_x = -1;
                        mouse_y = -1;
                        hovered_index = -1;
                    }
                }
                schedule_redraw();
                return true;
            }
            // Nothing known yet: don't open a gap until we know what is being dragged
            if (!peek_ready) {
                Gdk.drag_status(context, Gdk.DragAction.COPY, time);
                return true;
            }

            Gdk.drag_status(context, Gdk.DragAction.COPY, time);
            int new_index = get_insert_index(along(x, y));
            if (new_index != drop_insert_index) {
                drop_insert_index = new_index;
                position_dock();
                schedule_redraw();
            }
            return true;
        }

        private void on_drag_leave(Gdk.DragContext context, uint time) {
            clear_file_drop_state();
            if (drop_insert_index >= 0) {
                close_drop_gap();
                schedule_redraw();
            }
        }

        // The slot a dragged icon would drop into: between the launcher and the separator,
        // before the first item whose middle is past the pointer
        private int get_insert_index(double x) {
            int sep_idx = find_separator_index();
            int max_insert = sep_idx >= 0 ? sep_idx : (int) items.length();
            const int MIN_INSERT = 1;  // after the launcher

            // While a file is dragged over the dock a gap is open at drop_insert_index
            bool gap_open = drop_insert_index >= 0;
            double gap_width = renderer.spacing * 2;
            double pos = rest_origin(gap_open ? gap_width : 0);
            int i = 0;
            foreach (var item in items) {
                // Cursor within existing gap -> keep current index (prevents jitter)
                if (gap_open && i == drop_insert_index) {
                    if (x < pos + gap_width) return i;
                    pos += gap_width;
                }
                double w = item_length(item);
                if (i >= MIN_INSERT && i <= max_insert && x < pos + w / 2.0) return i;
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

        // Item a middle-button press started on, or -1
        private int middle_index = -1;
        // Scroll steps collected toward one window switch, and when the last switch happened
        private double scroll_accum = 0;
        private int64 last_scroll_step_us = 0;
        private const int64 SCROLL_STEP_GAP_US = 150000;

        private bool on_button_press(Gdk.EventButton event) {
            if (is_reordering) return true;  // Ignore during active drag
            double main_coord = along(event.x, event.y);

            // A click on the dock closes an open folder popup, and hides any tooltip
            folder_closed_by_press = folder_popup.open_index;
            folder_popup.dismiss();
            preview.cancel_timer();
            preview.dismiss();
            if (event.button == 1) {
                drag_start_x = main_coord;
                drag_index = get_item_at(main_coord);
            } else if (event.button == 2) {
                middle_index = get_item_at(main_coord);
            } else if (event.button == 3) {
                show_context_menu(event);
            }
            return true;
        }

        // Middle click: play or pause on the media widget, a new window on an app
        private void middle_activate_item(int index) {
            var item = items.nth_data(index);
            if (item == null) return;
            if (item.is_media_widget && item.plugin is MediaPlugin) {
                ((MediaPlugin) item.plugin).activate();
                return;
            }
            if (item.is_launcher || item.is_folder || item.is_separator || item.is_plugin) return;
            launch_new_window(item);
        }

        private void launch_new_window(DockItem item) {
            var app = app_manager.get_app(item.id);
            if (app == null) return;
            usage_tracker.record_launch(item.id);
            app.launch();
            trigger_bounce(item.id, true);
            watch_for_tray_start(item.id);
        }

        // An app that starts straight into the tray never opens a window, so the window list
        // cannot say it is running. Look for it a few times while it starts up.
        private void watch_for_tray_start(string id) {
            uint[] delays = { 1000, 2500, 5000 };
            foreach (var delay in delays) {
                Timeout.add(delay, () => { check_background.begin(id); return false; });
            }
        }

        // The scroll wheel: volume on the media widget, window switching on an app
        // Timestamp of the last scroll event acted on. A mouse wheel notch can arrive twice
        // with one timestamp, as a discrete step and as a smooth one (it does on Wayland),
        // and it must count once.
        private uint32 last_scroll_time = 0;

        private bool on_scroll(Gdk.EventScroll event) {
            if (event.time != 0 && event.time == last_scroll_time) return true;
            last_scroll_time = event.time;
            if (is_reordering) return true;
            double main_coord = along(event.x, event.y);
            int index = get_item_at(main_coord);
            if (index < 0) return false;
            var item = items.nth_data(index);
            if (item == null) return false;

            // Steps down (positive) or up (negative)
            double steps = 0;
            bool smooth = false;
            switch (event.direction) {
                case Gdk.ScrollDirection.UP: case Gdk.ScrollDirection.LEFT: steps = -1; break;
                case Gdk.ScrollDirection.DOWN: case Gdk.ScrollDirection.RIGHT: steps = 1; break;
                case Gdk.ScrollDirection.SMOOTH:
                    steps = event.delta_y != 0 ? event.delta_y : event.delta_x;
                    smooth = true;
                    break;
                default: return false;
            }
            if (steps == 0) return true;

            if (item.is_media_widget && item.plugin is MediaPlugin) {
                // Scrolling up raises the volume
                double v = ((MediaPlugin) item.plugin).change_volume(-steps * (smooth ? 0.03 : 0.05));
                if (v >= 0) preview.flash(index, "Volume %d%%".printf((int) Math.round(v * 100)));
                return true;
            }

            // A widget plugin with scroll commands, such as a volume control
            var script_plugin = item.plugin as ScriptPlugin;
            if (script_plugin != null && script_plugin.has_scroll) {
                script_plugin.scroll(steps < 0);
                return true;
            }

            if (item.is_launcher || item.is_folder || item.is_separator || item.is_plugin) return false;
            if (!item.running || item.windows.length() < 2) return false;

            scroll_accum += steps;
            if (Math.fabs(scroll_accum) < 1.0) return true;
            int64 now = GLib.get_monotonic_time();
            int dir = scroll_accum > 0 ? 1 : -1;
            scroll_accum = 0;
            if (now - last_scroll_step_us < SCROLL_STEP_GAP_US) return true;
            last_scroll_step_us = now;
            cycle_windows(item, index, dir);
            return true;
        }

        // Brings the next (dir 1) or previous (dir -1) window of an app to the front
        private void cycle_windows(DockItem item, int index, int dir) {
            int count = (int) item.windows.length();
            var active = wm.get_active_window();
            int current = -1;
            for (int i = 0; i < count; i++) {
                if (item.windows.nth_data(i) == active) { current = i; break; }
            }
            int next = current < 0 ? (dir > 0 ? 0 : count - 1) : ((current + dir) % count + count) % count;
            var window = item.windows.nth_data(next);
            if (window == null) return;
            wm.activate_window(window);
            preview.flash(index, TextUtil.sanitize(window.title), 900);
        }

        // Whether the app's window is the one with focus
        private bool is_app_active(DockItem item) {
            return active_app_id() == item.id;
        }

        // The id of the app that owns the focused window, or null
        private string? active_app_id() {
            var active = wm.get_active_window();
            if (active == null) return null;
            var app = app_manager.find_by_window(active);
            return app != null ? app.id : null;
        }

        private bool on_button_release(Gdk.EventButton event) {
            // Always ungrab the pointer if we grabbed it
            if (is_reordering) PopupHelper.ungrab(this);

            double main_coord = along(event.x, event.y);
            if (event.button == 2 && middle_index >= 0) {
                if (get_item_at(main_coord) == middle_index) middle_activate_item(middle_index);
                middle_index = -1;
            }
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
                pointer_left();
            }

            schedule_redraw();
            return true;
        }

        private double effective_width_factor(DockItem item) {
            if (is_vertical && item.is_media_widget) return 1.0;
            return item.dock_width_factor;
        }

        // How much of the dock's axis `item` takes up, spacing included, with its icon
        // magnified by `scale`. A separator is a line and doesn't scale.
        private double item_length(DockItem item, double scale = 1.0) {
            if (item.is_separator) return SEPARATOR_LINE + renderer.spacing;
            return renderer.icon_size * effective_width_factor(item) * scale + renderer.spacing;
        }

        // The pointer coordinate that runs along the dock
        private double along(double x, double y) {
            return is_vertical ? y : x;
        }

        // Where the first item starts along the axis when nothing is magnified, with
        // `extra` of room (an open drop gap) added to the content
        private double rest_origin(double extra = 0) {
            double total = extra;
            foreach (var item in items) total += item_length(item);
            int axis = is_vertical ? get_allocated_height() : get_allocated_width();
            return (axis - total) / 2.0;
        }

        private int get_item_at(double click_x) {
            double pos = rest_origin();
            int i = 0;
            foreach (var item in items) {
                double w = item_length(item);
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
                    media_popup.toggle(mp, index);
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
                    media_popup.toggle(mp, index);  // the art or the text
                }
                return;
            }
            if (item.is_plugin && item.plugin != null) { item.plugin.activate(); return; }
            if (item.running && item.windows.length() > 1) { show_window_list(item); return; }
            if (item.running && item.windows.length() > 0) {
                var window = item.windows.nth_data(0);
                if (config.get_minimize_on_click() && !window.is_minimized && is_app_active(item)) {
                    window.minimize();
                } else {
                    wm.activate_window(window);
                }
            } else {
                launch_new_window(item);
            }
        }

        private void get_item_bounds(int target_index, out double start_x, out double item_width) {
            double pos = rest_origin();
            int i = 0;
            start_x = pos;
            item_width = 0;
            foreach (var item in items) {
                double w = item_length(item);
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
            int index = get_item_at(along(event.x, event.y));
            if (index < 0) return;
            var item = items.nth_data(index);
            if (item == null) return;

            if (item.is_plugin && item.plugin != null && item.plugin.has_menu) {
                var m = item.plugin.get_menu();
                if (m != null) { m.popup_at_pointer(event); return; }
            }

            // Kept in a field: a menu nothing else refers to is destroyed while it is open
            context_menu = new Gtk.Menu();
            if (item.is_folder) {
                MenuUtil.add_item(context_menu, "Rename Folder...", () => show_rename_folder_dialog(item));
                MenuUtil.add_item(context_menu, "Delete Folder", () => {
                    config.delete_folder(item.folder_id);
                    items.remove(item);
                    save_pinned_apps();
                    position_dock();
                    schedule_redraw();
                });
                MenuUtil.add_separator(context_menu);
                MenuUtil.add_item(context_menu, "Dock Settings...", () => settings_requested());
            } else if (item.is_launcher) {
                // Dock Settings lives only on the Applications button
                MenuUtil.add_item(context_menu, "Dock Settings...", () => settings_requested());
            } else {
                build_app_menu(context_menu, item, (event.state & Gdk.ModifierType.SHIFT_MASK) != 0);
            }
            MenuUtil.popup(context_menu, event);
        }

        private void build_app_menu(Gtk.Menu menu, DockItem item, bool shift_held) {
            if (item.running) {
                MenuUtil.add_item(menu, "New Window", () => launch_new_window(item));
            }

            bool has_desktop_file = item.desktop_file != null && item.desktop_file != "";
            if (has_desktop_file) {
                var recent_submenu = RecentFilesMenu.build(item, app_manager, this);
                if (recent_submenu != null) {
                    var recent_mi = new Gtk.MenuItem.with_label("Recent Files");
                    recent_mi.submenu = recent_submenu;
                    menu.append(recent_mi);
                }
            }
            if (item.running || has_desktop_file) MenuUtil.add_separator(menu);

            var options = new Gtk.Menu();
            if (item.pinned) {
                MenuUtil.add_item(options, "Unpin from Dock", () => {
                    if (item.running) item.pinned = false; else items.remove(item);
                    save_pinned_apps();
                    schedule_redraw();
                });
            } else {
                MenuUtil.add_item(options, "Pin to Dock", () => {
                    item.pinned = true;
                    save_pinned_apps();
                    schedule_redraw();
                });
            }
            MenuUtil.add_item(options, "Properties...", () => properties_dialog.show(item));
            var options_mi = new Gtk.MenuItem.with_label("Options");
            options_mi.submenu = options;
            menu.append(options_mi);

            if (!item.running && !item.background) return;
            MenuUtil.add_separator(menu);
            if (item.running && item.windows.length() > 0) {
                MenuUtil.add_item(menu, "Hide", () => {
                    foreach (var window in item.windows) {
                        if (!window.is_minimized) window.minimize();
                    }
                });
                // Closes the windows only: an app with a tray icon keeps running
                MenuUtil.add_item(menu, "Close Window", () => {
                    var snapshot = new List<weak TrackedWindow>();
                    foreach (var window in item.windows) snapshot.append(window);
                    foreach (var window in snapshot) window.close();
                });
            }
            MenuUtil.add_item(menu, "Quit", () => AppQuit.quit.begin(item));

            // Force Close only shows when Shift is held as the menu opens. It ends the app's
            // processes outright, found from the window PID or, where there is none (Wayland,
            // or an app with no window), by name.
            if (shift_held) {
                MenuUtil.add_item(menu, "Force Close", () => {
                    foreach (var pid in AppQuit.find_pids(item, item.windows)) {
                        Posix.kill(pid, Posix.Signal.KILL);
                    }
                });
            }
        }

        // The badge counter is shared by every dock; null when badges are off
        public void set_notification_monitor(NotificationMonitor? monitor) {
            if (monitor == notification_monitor) return;
            if (notification_monitor != null) {
                notification_monitor.notification_received.disconnect(on_notification);
            }
            notification_monitor = monitor;
            if (monitor == null) return;
            monitor.notification_received.connect(on_notification);
            foreach (var item in items) item.notification_count = monitor.get_count(item.id);
            schedule_redraw();
        }

        private void on_notification(string app_id) {
            if (notification_monitor == null) return;
            var item = find_item(app_id);
            if (item == null) return;
            item.notification_count = notification_monitor.get_count(app_id);
            schedule_redraw();
            // Also trigger bounce for the notification
            trigger_bounce(app_id);
        }

        private DockItem? find_item(string id) {
            foreach (var item in items) {
                if (item.id == id) return item;
            }
            return null;
        }

        private void clear_badge_for_focused_app() {
            if (notification_monitor == null) return;
            string? active_id = active_app_id();
            if (active_id == null) return;
            notification_monitor.clear(active_id);
            var item = find_item(active_id);
            if (item == null) return;
            item.notification_count = 0;
            schedule_redraw();
        }

        // Compositor blur needs both the setting and a session that supports it
        private bool blur_wanted() {
            return config.get_blur_enabled() && Capabilities.current.supports(Feature.COMPOSITOR_BLUR);
        }

        // The launcher button, then the pinned apps, then the plugins
        private void rebuild_items() {
            items = new List<DockItem>();
            var launcher_item = new DockItem("dokku-launcher", "Applications", "view-app-grid-symbolic");
            launcher_item.pinned = true;
            launcher_item.is_launcher = true;
            items.append(launcher_item);
            load_pinned_apps();
            load_plugins();
        }

        public void reload_settings() {
            config.reload();
            var media_plugin = plugin_manager.get_plugin("media-player") as MediaPlugin;
            if (media_plugin != null) {
                media_plugin.set_blocked_players(config.get_media_blocked_players());
            }
            apply_monitor_settings();
            renderer.magnification = config.get_magnification();
            dodge_windows = config.get_dodge_windows() && Capabilities.current.supports(Feature.DODGE_WINDOWS);
            rounded_corners = config.get_rounded_corners();
            dock_opacity = config.get_dock_opacity();

            blur_enabled = blur_wanted();
            update_compositor_hints();
            ensure_blur_bg();
            // Re-apply bounding shape in case rounded_corners changed
            blur_backdrop.apply_shape();

            update_dock_dimensions();
            load_theme();

            rebuild_items();

            // If dodge_windows was disabled, clear dodge state
            if (!dodge_windows && dodge_hiding) {
                dodge_hiding = false;
            }

            if (!auto_hide && !dodge_hiding && hidden) {
                // Nothing requires hiding: show dock
                hidden = false;
                dock_slide_offset = 0.0;
            } else if (auto_hide && !hovering && !hidden) {
                // Auto-hide just enabled: hide immediately
                set_hidden(true);
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

            // Restore running app state: suppress bounces since this is a reload, not new launches
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
            // For launch bounces, always bounce (the app just started: user needs feedback).
            if (!is_launch && active_app_id() == app_id) return;

            // Per-app cooldown: suppress repeated bounces within 5 seconds
            int64 now = GLib.get_monotonic_time();
            if (bounce_cooldowns.contains(app_id)) {
                int64 last = bounce_cooldowns.get(app_id);
                if (now - last < BOUNCE_COOLDOWN_US) return;
            }
            bounce_cooldowns.set(app_id, now);

            var item = find_item(app_id);
            if (item == null) return;
            item.is_bouncing = true;
            item.bounce_is_launch = is_launch;
            item.bounce_start_time = now;
            start_bounce_tick();

            // When hiding and the dock is hidden, slide it up so the
            // user sees the launch bounce, then re-hide after bounce + 1s.
            if (is_launch && (auto_hide || dodge_hiding) && hidden) {
                set_hidden(false);
                if (launch_rehide_timeout_id != 0) Source.remove(launch_rehide_timeout_id);
                launch_rehide_timeout_id = Timeout.add(2000, () => {
                    launch_rehide_timeout_id = 0;
                    if ((auto_hide || dodge_hiding) && !hovering && !hidden) set_hidden(true);
                    return false;
                });
            }
        }

        private void clear_bounce_for_focused_app() {
            string? active_id = active_app_id();
            if (active_id == null) return;
            var item = find_item(active_id);
            if (item == null || !item.is_bouncing) return;
            // Launch bounces must play for a minimum duration so the user
            // sees the feedback, even if the app takes focus immediately.
            // Notification bounces clear instantly on focus.
            if (item.bounce_is_launch && item.bounce_elapsed(GLib.get_monotonic_time()) < DockItem.BOUNCE_SECONDS) return;
            item.is_bouncing = false;
        }

        private void start_bounce_tick() {
            if (bounce_tick_id != 0) return;
            bounce_tick_id = add_tick_callback((widget, frame_clock) => {
                bool any_bouncing = false;
                int64 now = frame_clock.get_frame_time();
                foreach (var item in items) {
                    if (!item.is_bouncing) continue;
                    if (item.bounce_elapsed(now) > DockItem.BOUNCE_SECONDS) {
                        item.is_bouncing = false;
                    } else {
                        any_bouncing = true;
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
            var item = find_item(app_id);
            if (item == null) return;
            item.progress_value = progress;
            item.progress_visible = visible;
            // Start animation tick for indeterminate (spinning) progress
            if (visible && progress < 0.0) start_progress_tick();
            schedule_redraw();
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
            string? new_name = Dialogs.ask_text(this, "Rename Folder", "_Rename", folder_item.name);
            if (new_name == null) return;
            config.rename_folder(folder_item.folder_id, new_name);
            folder_item.name = new_name;
            schedule_redraw();
        }
    }
}
