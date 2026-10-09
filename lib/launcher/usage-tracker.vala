namespace Dokku {
    public class UsageTracker : Object {
        private ConfigManager config;
        private uint save_timeout_id = 0;
        private const uint SAVE_DELAY_MS = 5000;

        public UsageTracker(ConfigManager config) {
            this.config = config;
        }

        public void record_launch(string app_id) {
            config.increment_usage(app_id);
            schedule_save();
        }

        public int get_count(string app_id) {
            return config.get_usage_count(app_id);
        }

        private void schedule_save() {
            if (save_timeout_id != 0) return;
            save_timeout_id = Timeout.add(SAVE_DELAY_MS, () => {
                save_timeout_id = 0;
                config.save();
                return false;
            });
        }

        public void flush() {
            if (save_timeout_id != 0) {
                Source.remove(save_timeout_id);
                save_timeout_id = 0;
                config.save();
            }
        }
    }
}
