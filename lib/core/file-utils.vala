namespace Dokku {
    public delegate void ExitFunc(bool ok);

    public class FileUtil {
        // Run a command line (no shell involved) and leave it to run on its own
        public static bool run_detached(string command_line) {
            try {
                string[] argv;
                Shell.parse_argv(command_line, out argv);
                Process.spawn_async(null, argv, null, SpawnFlags.SEARCH_PATH, null, null);
                return true;
            } catch (Error e) {
                warning("Failed to run %s: %s", command_line, e.message);
                return false;
            }
        }

        // Run a command and call `done` on the main loop once it exits (ok: exit status 0)
        public static void run_watched(string[] argv, owned ExitFunc done) throws Error {
            Pid pid;
            Process.spawn_async(null, argv, null,
                SpawnFlags.SEARCH_PATH | SpawnFlags.DO_NOT_REAP_CHILD, null, out pid);
            ChildWatch.add(pid, (child, status) => {
                Process.close_pid(child);
                bool ok = false;
                try { ok = Process.check_wait_status(status); } catch (Error e) {}
                done(ok);
            });
        }

        // Extract a zip to dest_dir/<basename>, validate paths, return dest path.
        // Returns false and cleans up on failure.
        public static bool install_zip(string zip_path, string dest_dir, out string dest_path) {
            var name = Path.get_basename(zip_path).replace(".zip", "");
            dest_path = Path.build_filename(dest_dir, name);
            DirUtils.create_with_parents(dest_path, 0755);

            try {
                string[] argv = {"unzip", "-o", zip_path, "-d", dest_path};
                int exit_status;
                string std_err;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH,
                                   null, null, out std_err, out exit_status);
                if (exit_status != 0) {
                    warning("unzip failed (status %d): %s", exit_status, std_err);
                    try { recursive_delete(dest_path); } catch (Error e) {}
                    return false;
                }
            } catch (Error e) {
                warning("Failed to run unzip: %s", e.message);
                try { recursive_delete(dest_path); } catch (Error e2) {}
                return false;
            }

            if (!validate_extracted_paths(dest_path)) {
                warning("Zip install rejected: path traversal detected");
                try { recursive_delete(dest_path); } catch (Error e) {}
                return false;
            }
            return true;
        }

        public static void recursive_delete(string path) throws Error {
            var file = File.new_for_path(path);
            var file_type = file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);

            if (file_type == FileType.SYMBOLIC_LINK) {
                FileUtils.remove(path);
                return;
            }

            if (file_type == FileType.DIRECTORY) {
                var enumerator = file.enumerate_children(
                    FileAttribute.STANDARD_NAME, FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
                FileInfo? info;
                while ((info = enumerator.next_file(null)) != null) {
                    recursive_delete(Path.build_filename(path, info.get_name()));
                }
                DirUtils.remove(path);
            } else {
                FileUtils.remove(path);
            }
        }

        public static bool validate_extracted_paths(string dest) {
            try {
                var dest_real = Posix.realpath(dest);
                if (dest_real == null) return false;
                var dir_file = File.new_for_path(dest);
                return validate_dir_recursive(dir_file, dest_real);
            } catch (Error e) {
                return false;
            }
        }

        private static bool validate_dir_recursive(File dir, string allowed_prefix) throws Error {
            var enumerator = dir.enumerate_children(
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
            FileInfo? info;
            while ((info = enumerator.next_file(null)) != null) {
                // Reject symlinks outright: they could point outside the prefix
                if (info.get_file_type() == FileType.SYMBOLIC_LINK) {
                    return false;
                }
                var child = dir.get_child(info.get_name());
                // Validate path lexically (no realpath, which follows symlinks)
                string child_path = child.get_path();
                if (child_path == null || !child_path.has_prefix(allowed_prefix + "/")) {
                    return false;
                }
                // Reject path components that escape via ".."
                if (info.get_name().contains("..")) {
                    return false;
                }
                if (info.get_file_type() == FileType.DIRECTORY) {
                    if (!validate_dir_recursive(child, allowed_prefix)) return false;
                }
            }
            return true;
        }
    }
}
