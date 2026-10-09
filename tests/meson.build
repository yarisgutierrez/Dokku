unit_tests = executable('dokku-tests',
  'main.vala',
  'support.vala',
  'test-text-utils.vala',
  'test-capabilities.vala',
  'test-theme.vala',
  'test-app-info.vala',
  'test-file-utils.vala',
  'test-config.vala',
  dependencies: libdokku_dep,
  include_directories: include_directories('../lib'),
  install: false,
)

# ConfigManager writes under $HOME, so the tests run with a throwaway one.
test_env = environment()
test_env.set('HOME', meson.current_build_dir() / 'dokku-test-home')

test('unit', unit_tests, env: test_env)
