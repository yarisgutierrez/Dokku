namespace Dokku {
    /**
     * 3-pass box blur that approximates Gaussian blur.
     * Operates in-place on raw pixel data for efficiency.
     */
    public class BlurUtil {

        /**
         * Blur a Gdk.Pixbuf with the given radius using 3 passes of box blur.
         * Returns a new blurred pixbuf (original is not modified).
         */
        public static Gdk.Pixbuf blur_pixbuf(Gdk.Pixbuf src, int radius) {
            if (radius < 1) return src.copy();

            int w = src.get_width();
            int h = src.get_height();
            int rowstride = src.get_rowstride();
            bool has_alpha = src.get_has_alpha();

            // Work on a flat RGBA buffer for simplicity
            int bpp = has_alpha ? 4 : 3;
            int buf_stride = w * 4;  // always use 4-channel internal buffer
            uint8[] buf_a = new uint8[w * h * 4];
            uint8[] buf_b = new uint8[w * h * 4];

            // Copy source into buf_a, expanding to 4 channels if needed
            unowned uint8[] src_data = src.get_pixels();
            for (int y = 0; y < h; y++) {
                int src_row = y * rowstride;
                int dst_row = y * buf_stride;
                for (int x = 0; x < w; x++) {
                    int si = src_row + x * bpp;
                    int di = dst_row + x * 4;
                    buf_a[di]     = src_data[si];
                    buf_a[di + 1] = src_data[si + 1];
                    buf_a[di + 2] = src_data[si + 2];
                    buf_a[di + 3] = has_alpha ? src_data[si + 3] : 255;
                }
            }

            // 3 passes of box blur (horizontal then vertical)
            for (int pass = 0; pass < 3; pass++) {
                box_blur_horizontal(buf_a, buf_b, w, h, buf_stride, radius);
                box_blur_vertical(buf_b, buf_a, w, h, buf_stride, radius);
            }

            // Create result pixbuf
            var result = new Gdk.Pixbuf(Gdk.Colorspace.RGB, true, 8, w, h);
            unowned uint8[] dst_data = result.get_pixels();
            int dst_rowstride = result.get_rowstride();
            for (int y = 0; y < h; y++) {
                int src_row = y * buf_stride;
                int dst_row = y * dst_rowstride;
                for (int x = 0; x < w; x++) {
                    int si = src_row + x * 4;
                    int di = dst_row + x * 4;
                    dst_data[di]     = buf_a[si];
                    dst_data[di + 1] = buf_a[si + 1];
                    dst_data[di + 2] = buf_a[si + 2];
                    dst_data[di + 3] = buf_a[si + 3];
                }
            }
            return result;
        }

        /**
         * Horizontal box blur pass using sliding window accumulator.
         * Reads from src, writes to dst.
         */
        private static void box_blur_horizontal(uint8[] src, uint8[] dst,
                                                 int w, int h, int stride, int radius) {
            double inv = 1.0 / (radius + radius + 1);

            for (int y = 0; y < h; y++) {
                int row = y * stride;

                // Initialize accumulator with left-edge padding
                int64 acc_r = 0, acc_g = 0, acc_b = 0, acc_a = 0;

                // Left padding: extend leftmost pixel
                int left_idx = row;
                acc_r = (int64)src[left_idx]     * (radius + 1);
                acc_g = (int64)src[left_idx + 1] * (radius + 1);
                acc_b = (int64)src[left_idx + 2] * (radius + 1);
                acc_a = (int64)src[left_idx + 3] * (radius + 1);

                // Pre-fill right side of window
                for (int i = 0; i < radius; i++) {
                    int idx = row + int.min(i, w - 1) * 4;
                    acc_r += src[idx];
                    acc_g += src[idx + 1];
                    acc_b += src[idx + 2];
                    acc_a += src[idx + 3];
                }

                // Slide across each pixel
                for (int x = 0; x < w; x++) {
                    // Add incoming pixel (right edge of window)
                    int ri = row + int.min(x + radius, w - 1) * 4;
                    acc_r += src[ri];
                    acc_g += src[ri + 1];
                    acc_b += src[ri + 2];
                    acc_a += src[ri + 3];

                    // Write averaged pixel
                    int di = row + x * 4;
                    dst[di]     = (uint8)(acc_r * inv);
                    dst[di + 1] = (uint8)(acc_g * inv);
                    dst[di + 2] = (uint8)(acc_b * inv);
                    dst[di + 3] = (uint8)(acc_a * inv);

                    // Remove outgoing pixel (left edge of window)
                    int li = row + int.max(x - radius, 0) * 4;
                    acc_r -= src[li];
                    acc_g -= src[li + 1];
                    acc_b -= src[li + 2];
                    acc_a -= src[li + 3];
                }
            }
        }

        /**
         * Vertical box blur pass using sliding window accumulator.
         * Reads from src, writes to dst.
         */
        private static void box_blur_vertical(uint8[] src, uint8[] dst,
                                               int w, int h, int stride, int radius) {
            double inv = 1.0 / (radius + radius + 1);

            for (int x = 0; x < w; x++) {
                int col = x * 4;

                // Initialize accumulator with top-edge padding
                int top_idx = col;
                int64 acc_r = (int64)src[top_idx]     * (radius + 1);
                int64 acc_g = (int64)src[top_idx + 1] * (radius + 1);
                int64 acc_b = (int64)src[top_idx + 2] * (radius + 1);
                int64 acc_a = (int64)src[top_idx + 3] * (radius + 1);

                // Pre-fill bottom side of window
                for (int i = 0; i < radius; i++) {
                    int idx = int.min(i, h - 1) * stride + col;
                    acc_r += src[idx];
                    acc_g += src[idx + 1];
                    acc_b += src[idx + 2];
                    acc_a += src[idx + 3];
                }

                // Slide down each pixel
                for (int y = 0; y < h; y++) {
                    // Add incoming pixel (bottom edge of window)
                    int bi = int.min(y + radius, h - 1) * stride + col;
                    acc_r += src[bi];
                    acc_g += src[bi + 1];
                    acc_b += src[bi + 2];
                    acc_a += src[bi + 3];

                    // Write averaged pixel
                    int di = y * stride + col;
                    dst[di]     = (uint8)(acc_r * inv);
                    dst[di + 1] = (uint8)(acc_g * inv);
                    dst[di + 2] = (uint8)(acc_b * inv);
                    dst[di + 3] = (uint8)(acc_a * inv);

                    // Remove outgoing pixel (top edge of window)
                    int ti = int.max(y - radius, 0) * stride + col;
                    acc_r -= src[ti];
                    acc_g -= src[ti + 1];
                    acc_b -= src[ti + 2];
                    acc_a -= src[ti + 3];
                }
            }
        }

        /**
         * Generate a noise texture as a Cairo.ImageSurface (A8 format).
         * Used for subtle grain overlay on the frosted glass effect.
         */
        public static Cairo.ImageSurface generate_noise_texture(int w, int h, double intensity) {
            var surface = new Cairo.ImageSurface(Cairo.Format.A8, w, h);
            unowned uint8[] data = surface.get_data();
            int stride = surface.get_stride();

            // Simple PRNG for deterministic noise
            uint32 seed = 12345;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    seed = seed * 1103515245 + 12345;
                    uint8 noise = (uint8)(((seed >> 16) & 0xFF) * intensity);
                    data[y * stride + x] = noise;
                }
            }
            surface.mark_dirty();
            return surface;
        }
    }
}
