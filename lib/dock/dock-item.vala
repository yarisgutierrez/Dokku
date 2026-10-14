namespace Dokku {
    public class DockItem : Object {
        public string id { get; set; }
        public string name { get; set; }
        public string icon_name { get; set; }
        public string desktop_file { get; set; }
        public bool pinned { get; set; default = false; }
        public bool running { get; set; default = false; }
        public bool is_launcher { get; set; default = false; }
        public bool is_plugin { get; set; default = false; }
        public bool is_widget { get; set; default = false; }
        public bool is_separator { get; set; default = false; }
        public bool is_media_widget { get; set; default = false; }
        public int notification_count { get; set; default = 0; }
        public bool is_bouncing { get; set; default = false; }
        public bool bounce_is_launch { get; set; default = false; }
        public int64 bounce_start_time { get; set; default = 0; }
        public const double BOUNCE_SECONDS = 1.5;

        // How long the bounce has been going at monotonic time `now`, in seconds
        public double bounce_elapsed(int64 now) {
            return (now - bounce_start_time) / 1000000.0;
        }
        public double progress_value { get; set; default = 0.0; }
        public bool progress_visible { get; set; default = false; }
        public bool is_folder { get; set; default = false; }
        public string folder_id { get; set; default = ""; }
        public string[] folder_apps;
        public double dock_width_factor { get; set; default = 1.0; }
        public Plugin? plugin { get; set; default = null; }
        public List<weak TrackedWindow> windows;

        public DockItem(string id, string name, string icon_name) {
            this.id = id;
            this.name = name;
            this.icon_name = icon_name;
            this.folder_apps = {};
            this.windows = new List<weak TrackedWindow>();
        }

        public DockItem.from_plugin(Plugin plugin) {
            this.id = plugin.id;
            this.name = plugin.name;
            this.icon_name = plugin.icon;
            this.is_plugin = true;
            this.is_separator = (plugin.id == "separator");
            this.plugin = plugin;
            this.pinned = true;
            this.folder_apps = {};
            this.windows = new List<weak TrackedWindow>();

            if (plugin is ScriptPlugin) {
                var sp = plugin as ScriptPlugin;
                this.is_widget = sp.is_widget;
            }
            if (plugin is MediaPlugin) {
                this.is_media_widget = true;
                this.dock_width_factor = 3.8;
            }
        }
    }
}
