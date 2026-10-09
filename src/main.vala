int main(string[] args) {
    stderr.printf("Dokku starting...\n");
    var app = new Dokku.Application();
    stderr.printf("Application created, running...\n");
    int ret = app.run(args);
    stderr.printf("Application exited with code %d\n", ret);
    return ret;
}
