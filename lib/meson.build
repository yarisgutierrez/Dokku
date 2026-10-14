subdir('hotkeys')

version_vala = configure_file(
  input: 'core/version.vala.in',
  output: 'version.vala',
  configuration: configuration_data({'VERSION': meson.project_version()}),
)

libdokku_sources = files(
  'core/file-utils.vala',
  'core/text-utils.vala',
  'core/icon-loader.vala',
  'core/menu-util.vala',
  'core/ui-util.vala',
  'core/icon-picker.vala',
  'core/dialogs.vala',
  'core/capabilities.vala',
  'core/application.vala',
  'core/dbus-service.vala',
  'dock/dock-window.vala',
  'dock/dock-item.vala',
  'dock/properties-dialog.vala',
  'dock/recent-files-menu.vala',
  'dock/popup-host.vala',
  'dock/popup-helper.vala',
  'dock/preview-popup.vala',
  'dock/media-popup.vala',
  'dock/folder-popup.vala',
  'dock/drag-float-popup.vala',
  'dock/compositor-hints.vala',
  'dock/monitor-key.vala',
  'dock/blur-backdrop.vala',
  'dock/dock-renderer.vala',
  'dock/tracked-window.vala',
  'dock/window-manager.vala',
  'dock/app-quit.vala',
  'dock/app-manager.vala',
  'dock/menu-categories.vala',
  'dock/config-manager.vala',
  'dock/notification-monitor.vala',
  'dock/progress-monitor.vala',
  'launcher/quick-results.vala',
  'launcher/launcher-window.vala',
  'launcher/usage-tracker.vala',
  'settings/settings-window.vala',
  'plugins/plugin.vala',
  'plugins/plugin-manager.vala',
  'plugins/script-plugin.vala',
  'plugins/trash-plugin.vala',
  'plugins/media-player-picker.vala',
  'plugins/media-plugin.vala',
  'plugins/show-desktop-plugin.vala',
  'plugins/separator-plugin.vala',
  'themes/theme.vala',
  'themes/theme-manager.vala',
)

if wayland_client_dep.found() and wayland_scanner.found()
  toplevel_protocol = 'wlr-foreign-toplevel-management-unstable-v1'
  protocol_xml = files('../data/protocols/' + toplevel_protocol + '.xml')
  protocol_header = custom_target('toplevel-protocol-header',
    input: protocol_xml,
    output: toplevel_protocol + '-client-protocol.h',
    command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
  )
  protocol_code = custom_target('toplevel-protocol-code',
    input: protocol_xml,
    output: toplevel_protocol + '-protocol.c',
    command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
  )
  xdg_output = 'xdg-output-unstable-v1'
  xdg_output_xml = files('../data/protocols/' + xdg_output + '.xml')
  xdg_output_header = custom_target('xdg-output-header',
    input: xdg_output_xml,
    output: xdg_output + '-client-protocol.h',
    command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
  )
  xdg_output_code = custom_target('xdg-output-code',
    input: xdg_output_xml,
    output: xdg_output + '-protocol.c',
    command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
  )
  libdokku_sources += files('wayland/toplevel-tracker.c')
  libdokku_sources += [protocol_header, protocol_code, xdg_output_header, xdg_output_code]
  libdokku_sources += files('wayland/wayland-windows.vala')
endif

libdokku_sources += hotkeys_sources
libdokku_sources += version_vala

libdokku = static_library('dokku',
  libdokku_sources,
  dependencies: dependencies,
  install: false,
)

libdokku_dep = declare_dependency(
  link_with: libdokku,
  dependencies: dependencies,
)
