namespace Dokku.Tests {
    public class TextUtilTests : GLib.Object {
        // Every character is 10 units wide, so widths are easy to reason about.
        private static double ten_per_char(string s) {
            return s.char_count() * 10.0;
        }

        public static void register() {
            Test.add_func("/text/sanitize/null-and-empty", sanitize_null_and_empty);
            Test.add_func("/text/sanitize/valid-utf8-unchanged", sanitize_valid);
            Test.add_func("/text/sanitize/invalid-utf8-replaced", sanitize_invalid);
            Test.add_func("/text/truncate/fits-unchanged", truncate_fits);
            Test.add_func("/text/truncate/removes-whole-characters", truncate_multibyte);
            Test.add_func("/text/truncate/keeps-at-least-one-char", truncate_keeps_one);
            Test.add_func("/text/truncate/always-valid-utf8", truncate_always_valid);
            Test.add_func("/text/truncate/invalid-input", truncate_invalid_input);
        }

        private static void sanitize_null_and_empty() {
            assert_cmpstr(TextUtil.sanitize(null), CompareOperator.EQ, "");
            assert_cmpstr(TextUtil.sanitize(""), CompareOperator.EQ, "");
        }

        private static void sanitize_valid() {
            assert_cmpstr(TextUtil.sanitize("Firefox"), CompareOperator.EQ, "Firefox");
            assert_cmpstr(TextUtil.sanitize("日本語 😀"), CompareOperator.EQ, "日本語 😀");
        }

        private static void sanitize_invalid() {
            assert_cmpstr(TextUtil.sanitize("bad \xff\xfe bytes"), CompareOperator.EQ, "?");
        }

        private static void truncate_fits() {
            assert_cmpstr(TextUtil.truncate("hello", 50, ten_per_char), CompareOperator.EQ, "hello");
            assert_cmpstr(TextUtil.truncate("hello", 1000, ten_per_char), CompareOperator.EQ, "hello");
        }

        // The original bug: cutting by byte split multi-byte characters and
        // pushed Cairo into an unrecoverable error state.
        private static void truncate_multibyte() {
            string result = TextUtil.truncate("日本語テキスト", 45, ten_per_char);
            assert_true(result.validate());
            assert_cmpstr(result, CompareOperator.EQ, "日...");

            result = TextUtil.truncate("héllo wörld", 80, ten_per_char);
            assert_true(result.validate());
            assert_cmpstr(result, CompareOperator.EQ, "héllo...");
        }

        private static void truncate_keeps_one() {
            // Even when nothing fits, one whole character is kept.
            string result = TextUtil.truncate("😀😀😀😀😀", 35, ten_per_char);
            assert_true(result.validate());
            assert_cmpstr(result, CompareOperator.EQ, "😀...");
        }

        private static void truncate_always_valid() {
            string text = "aé日😀bé日😀 mixed text ünïcode";
            for (int width = 0; width <= 300; width += 5) {
                string result = TextUtil.truncate(text, width, ten_per_char);
                assert_true(result.validate());
            }
        }

        private static void truncate_invalid_input() {
            assert_cmpstr(TextUtil.truncate("\xff\xfe", 100, ten_per_char), CompareOperator.EQ, "?");
            assert_cmpstr(TextUtil.truncate("", 100, ten_per_char), CompareOperator.EQ, "");
        }
    }
}
