subdir('hotkeys')

libdokku_sources = files(
  'core/file-utils.vala',
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
  'dock/blur-backdrop.vala',
  'dock/dock-renderer.vala',
  'dock/window-manager.vala',
  'dock/app-manager.vala',
  'dock/config-manager.vala',
  'dock/notification-monitor.vala',
  'dock/progress-monitor.vala',
  'launcher/launcher-window.vala',
  'launcher/usage-tracker.vala',
  'settings/settings-window.vala',
  'plugins/plugin.vala',
  'plugins/plugin-manager.vala',
  'plugins/script-plugin.vala',
  'plugins/trash-plugin.vala',
  'plugins/media-plugin.vala',
  'plugins/show-desktop-plugin.vala',
  'plugins/separator-plugin.vala',
  'themes/theme.vala',
  'themes/theme-manager.vala',
)

libdokku_sources += hotkeys_sources

libdokku = static_library('dokku',
  libdokku_sources,
  dependencies: dependencies,
  install: false,
)

libdokku_dep = declare_dependency(
  link_with: libdokku,
  dependencies: dependencies,
)
