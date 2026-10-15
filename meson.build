project('dokku', 'vala', 'c',
  version: '0.3.0',
  meson_version: '>= 0.53.0',
  # A dock stays resident, so build it small by default: -Os costs no measurable speed
  # here (the drawing time is in GTK and Cairo) and trims about a fifth off the binary,
  # and installing strips the symbols. `--buildtype=debug -Dstrip=false` for development.
  default_options: ['buildtype=minsize', 'strip=true'],
)

cc = meson.get_compiler('c')

# Security hardening flags
add_project_arguments('-fstack-protector-strong', '-D_FORTIFY_SOURCE=2', language: 'c')
add_project_link_arguments('-Wl,-z,relro', '-Wl,-z,now', language: 'c')

atspi_dep = dependency('atspi-2', required: false)

# Window tracking on Wayland needs wayland-scanner at build time (libwayland-bin).
# Without it Dokku still builds, and just can't see windows on Wayland.
wayland_client_dep = dependency('wayland-client', required: false)
wayland_scanner = find_program('wayland-scanner', required: false)

layer_shell_dep = dependency('gtk-layer-shell-0')

# gtk_layer_try_force_commit () arrived in gtk-layer-shell 0.9 (Ubuntu 24.04 has 0.8)
if layer_shell_dep.version().version_compare('>= 0.9.0')
  add_project_arguments('-D', 'HAVE_LAYER_SHELL_FORCE_COMMIT', language: 'vala')
endif

dependencies = [
  dependency('gtk+-3.0'),
  dependency('glib-2.0'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('libwnck-3.0'),
  layer_shell_dep,
  dependency('keybinder-3.0', version: '>= 0.3.0'),
  dependency('x11'),
  cc.find_library('m', required: true),
]

if wayland_client_dep.found() and wayland_scanner.found()
  dependencies += wayland_client_dep
  add_project_arguments('-D', 'HAVE_WAYLAND_TRACKER', language: 'vala')
  add_project_arguments('--pkg', 'dokku-toplevel', language: 'vala')
endif

if atspi_dep.found()
  dependencies += atspi_dep
  add_project_arguments('-D', 'HAVE_ATSPI', language: 'vala')
endif

add_project_arguments('-DWNCK_I_KNOW_THIS_IS_UNSTABLE', '-D_DEFAULT_SOURCE', language: 'c')
add_project_arguments('--vapidir', meson.current_source_dir() / 'vapi', language: 'vala')
add_project_arguments('--pkg', 'posix', language: 'vala')
add_project_arguments('--pkg', 'x11', language: 'vala')
add_project_arguments('--pkg', 'gdk-x11-3.0', language: 'vala')

subdir('lib')
subdir('src')
# Unit tests are developer-only and are not shipped in the repository
if import('fs').exists('tests/meson.build')
  subdir('tests')
endif

install_data('data/dokku.desktop',
  install_dir: join_paths(get_option('datadir'), 'applications')
)

install_data('data/dokku-autostart.desktop',
  install_dir: join_paths(get_option('sysconfdir'), 'xdg/autostart')
)

# Plugins that ship with Dokku: widgets for the clock, battery and volume, off until enabled
install_subdir('data/plugins',
  install_dir: join_paths(get_option('datadir'), 'dokku')
)

install_data('data/icons/dokku.svg',
  install_dir: join_paths(get_option('datadir'), 'icons/hicolor/scalable/apps')
)

man_page = configure_file(
  input: 'data/dokku.1.in',
  output: 'dokku.1',
  configuration: configuration_data({
    'VERSION': meson.project_version(),
    'DATE': 'October 2026',
  }),
)
install_man(man_page)
