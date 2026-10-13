namespace Dokku {
    // A small arithmetic evaluator for the launcher's search box. It is a parser for a
    // fixed grammar, so what is typed is never executed:
    //
    //   expr   := term (('+' | '-') term)*
    //   term   := unary (('*' | '/' | '%') unary)*
    //   unary  := ('-' | '+') unary | power
    //   power  := atom ('^' unary)?          (-2^2 is -4, 2^-1 is 0.5)
    //   atom   := number | name | name '(' expr ')' | '(' expr ')'
    //
    // Text only counts as a calculation when it has an operator or a function, so a
    // lone number, or an app name like "7zip", is left to the app search.
    public class QuickMath : Object {
        private const int MAX_DEPTH = 40;

        private string text;
        private int pos = 0;
        private int depth = 0;
        private bool failed = false;
        private bool used_operation = false;

        private QuickMath(string text) {
            this.text = text;
        }

        public static bool evaluate(string input, out double result) {
            result = 0;
            if (input.length > 200) return false;
            // Tidy the usual typing variants, and drop spaces
            string s = input.replace("×", "*").replace("÷", "/").replace("−", "-")
                            .replace(" ", "").replace("\t", "");
            if (s == "") return false;

            var parser = new QuickMath(s);
            double value = parser.parse_expr();
            if (parser.failed || parser.pos != s.length) return false;
            if (!parser.used_operation) return false;
            if (value != value || value.abs() == double.INFINITY) return false;
            result = value;
            return true;
        }

        // The value as it should read in a result row: up to 10 significant digits,
        // no trailing zeros, and always a point (never the locale's comma).
        public static string format(double value) {
            if (value == 0) return "0";   // also folds -0
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            return value.format(buf, "%.10g").dup();
        }

        private char peek() {
            return pos < text.length ? text[pos] : '\0';
        }

        private double parse_expr() {
            double left = parse_term();
            while (!failed && (peek() == '+' || peek() == '-')) {
                char op = peek();
                pos++;
                double right = parse_term();
                used_operation = true;
                left = op == '+' ? left + right : left - right;
            }
            return left;
        }

        private double parse_term() {
            double left = parse_unary();
            while (!failed && (peek() == '*' || peek() == '/' || peek() == '%')) {
                char op = peek();
                pos++;
                double right = parse_unary();
                used_operation = true;
                if (op == '*') {
                    left = left * right;
                } else if (right == 0) {
                    failed = true;
                    return 0;
                } else if (op == '/') {
                    left = left / right;
                } else {
                    left = left % right;
                }
            }
            return left;
        }

        private double parse_unary() {
            if (++depth > MAX_DEPTH) { failed = true; return 0; }
            double value;
            if (peek() == '-') {
                pos++;
                value = -parse_unary();
                used_operation = true;
            } else if (peek() == '+') {
                pos++;
                value = parse_unary();
                used_operation = true;
            } else {
                value = parse_power();
            }
            depth--;
            return value;
        }

        private double parse_power() {
            double base_value = parse_atom();
            if (!failed && peek() == '^') {
                pos++;
                double exponent = parse_unary();
                used_operation = true;
                return Math.pow(base_value, exponent);
            }
            return base_value;
        }

        private double parse_atom() {
            if (failed) return 0;
            char c = peek();

            if (c == '(') {
                if (++depth > MAX_DEPTH) { failed = true; return 0; }
                pos++;
                double value = parse_expr();
                depth--;
                if (failed || peek() != ')') { failed = true; return 0; }
                pos++;
                return value;
            }

            if ((c >= '0' && c <= '9') || c == '.') return parse_number();

            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
                int start = pos;
                while (pos < text.length && ((text[pos] >= 'a' && text[pos] <= 'z') ||
                                             (text[pos] >= 'A' && text[pos] <= 'Z'))) {
                    pos++;
                }
                string name = text.substring(start, pos - start).down();
                if (peek() == '(') {
                    if (++depth > MAX_DEPTH) { failed = true; return 0; }
                    pos++;
                    double arg = parse_expr();
                    depth--;
                    if (failed || peek() != ')') { failed = true; return 0; }
                    pos++;
                    used_operation = true;
                    return apply_function(name, arg);
                }
                if (name == "pi") return Math.PI;
                if (name == "e") return Math.E;
                failed = true;
                return 0;
            }

            failed = true;
            return 0;
        }

        private double parse_number() {
            int start = pos;
            bool seen_point = false;
            bool seen_digit = false;
            while (pos < text.length) {
                char c = text[pos];
                if (c >= '0' && c <= '9') {
                    seen_digit = true;
                } else if (c == '.' && !seen_point) {
                    seen_point = true;
                } else {
                    break;
                }
                pos++;
            }
            if (!seen_digit) { failed = true; return 0; }
            return double.parse(text.substring(start, pos - start));
        }

        private double apply_function(string name, double x) {
            switch (name) {
                case "sqrt":
                    if (x < 0) { failed = true; return 0; }
                    return Math.sqrt(x);
                case "abs": return x.abs();
                case "floor": return Math.floor(x);
                case "ceil": return Math.ceil(x);
                case "round": return Math.round(x);
                case "sin": return Math.sin(x);
                case "cos": return Math.cos(x);
                case "tan": return Math.tan(x);
                case "exp": return Math.exp(x);
                case "ln":
                    if (x <= 0) { failed = true; return 0; }
                    return Math.log(x);
                case "log":
                    if (x <= 0) { failed = true; return 0; }
                    return Math.log10(x);
                default:
                    failed = true;
                    return 0;
            }
        }
    }

    public class QuickResults : Object {
        public const string DEFAULT_WEB_SEARCH = "https://duckduckgo.com/?q=%s";

        // The address a web search opens, or null when the template is empty or has
        // no %s to put the words in. Only http and https templates are accepted.
        public static string? web_search_uri(string template, string query) {
            string t = template.strip();
            string q = query.strip();
            if (t == "" || q == "" || !t.contains("%s")) return null;
            if (!t.has_prefix("https://") && !t.has_prefix("http://")) return null;
            return t.replace("%s", Uri.escape_string(q, null, false));
        }

        // Whether a recent file's name matches what was typed (every word, any order)
        public static bool name_matches(string display_name, string query) {
            string name = display_name.down();
            foreach (var word in query.down().split(" ")) {
                if (word != "" && !name.contains(word)) return false;
            }
            return query.strip() != "";
        }
    }
}
