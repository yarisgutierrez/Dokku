int main(string[] args) {
    Test.init(ref args);

    // ConfigManager writes under $HOME/.config/dokku. Refuse to run unless HOME has
    // been pointed at a throwaway directory (meson does this), so a stray invocation
    // can never touch a real configuration.
    string home = Environment.get_home_dir();
    if (!home.contains("dokku-test-home")) {
        stderr.printf("Refusing to run: HOME=%s is not a test home.\n" +
                      "Run the tests with `meson test -C build`.\n", home);
        return 1;
    }

    Dokku.Tests.TextUtilTests.register();
    Dokku.Tests.CapabilitiesTests.register();
    Dokku.Tests.ThemeTests.register();
    Dokku.Tests.AppInfoTests.register();
    Dokku.Tests.FileUtilTests.register();
    Dokku.Tests.ConfigTests.register();

    return Test.run();
}
