int main(string[] args) {
    // Apps launched from the dock inherit our working directory, and a file manager
    // started with no path opens it. Don't let that be wherever Dokku was started from.
    Environment.set_current_dir(Environment.get_home_dir());

    var app = new Dokku.Application();
    return app.run(args);
}
