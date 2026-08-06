project(
	'asteroidz-bar',
	['c', 'cpp'],
	version: '0.3.2',
	license: 'MIT',
	meson_version: '>=0.59.0',
	default_options: ['cpp_std=c++20'],
)

# The wallpaper.
#
# asteroidzbg is here rather than beside it because a shell that cannot set the
# wallpaper is not a shell -- and because the two are already coupled: the bar
# is what will offer the wallpaper menu, and the palette the bar draws itself
# with is generated FROM the wallpaper by matugen. One project, one package,
# one version.
#
# It is not a program any more. asteroidzbg is built here as a static library
# and linked into the QML plugin below, so the wallpaper goes up on the
# shell's own Wayland connection, in the shell's own process -- there is no
# second binary to launch, supervise or keep in step.
#
# What could not be rewritten in QML, and is the reason this code is still C:
# HDR. asteroidzbg tags its surface through wp_color_manager_v1 with BT.2020
# primaries and the PQ transfer function, and decodes 10-bit AVIF and JPEG XL
# to match (color-management.c, hdr-image.c). Qt exposes none of that.
wallpaper = subproject('asteroidzbg')
asteroidzbg_dep = wallpaper.get_variable('asteroidzbg_dep')

qmldir = get_option('datadir') / 'asteroidz-bar'
# The QML module's own directory, put on the import path by the launcher.
qmlplugindir = get_option('datadir') / 'asteroidz-bar' / 'qml' / 'Asteroidz' / 'Bar'

install_data(
	[
		'shell/shell.qml',
		'shell/qmldir',
		'shell/Bar.qml',
		'shell/Cfg.qml',
		'shell/Ipc.qml',
		'shell/Panel.qml',
		'shell/Pill.qml',
		'shell/Popover.qml',
		'shell/Section.qml',
		'shell/Icon.qml',
		'shell/Compositor.qml',
		'shell/Metrics.qml',
		'shell/Sizes.qml',
		'shell/BatteryService.qml',
		'shell/Wallpaper.qml',
		'shell/Location.qml',
		'shell/BarConfig.qml',
		'shell/NotificationService.qml',
		'shell/NotificationCard.qml',
		'shell/NotificationCentre.qml',
		'shell/AudioPanel.qml',
		'shell/AudioDeviceRow.qml',
		'shell/NotificationPopups.qml',
		'shell/Logo.qml',
		'shell/IdleService.qml',
		'shell/Arrange.qml',
		'shell/FormRow.qml',
		'shell/Picker.qml',
		'shell/Toggle.qml',
		'shell/Slider.qml',
		'shell/Field.qml',
	],
	install_dir: qmldir,
)

install_data(
	[
		'shell/modules/qmldir',
		'shell/modules/Clock.qml',
		'shell/modules/ModuleLoader.qml',
		'shell/modules/Tags.qml',
		'shell/modules/Layout.qml',
		'shell/modules/Title.qml',
		'shell/modules/Metric.qml',
		'shell/modules/Battery.qml',
		'shell/modules/Network.qml',
		'shell/modules/Volume.qml',
		'shell/modules/Idle.qml',
		'shell/modules/Notify.qml',
		'shell/modules/Weather.qml',
		'shell/modules/Media.qml',
		'shell/modules/Spectrum.qml',
		'shell/modules/Tray.qml',
		'shell/modules/Custom.qml',
		'shell/modules/Power.qml',
	],
	install_dir: qmldir / 'modules',
)

# The settings window.
#
# Its own directory because it is its own module: a qmldir is what lets a
# singleton be registered at all, and Schema and Settings are both singletons.
#
# A .qml file missing from this list still works from the source tree and
# vanishes when packaged -- the one failure mode that cannot be caught while
# developing -- so every file in shell/settings/ belongs here.
install_data(
	[
		'shell/settings/qmldir',
		'shell/settings/Settings.qml',
		'shell/settings/Schema.qml',
		'shell/settings/SettingsWindow.qml',
		'shell/settings/OptionRow.qml',
		'shell/settings/ColorField.qml',
		'shell/settings/SmallButton.qml',
		'shell/settings/DisplaysPage.qml',
		'shell/settings/WallpaperPage.qml',
		'shell/settings/ModulesPage.qml',
		'shell/settings/Rules.qml',
		'shell/settings/LayoutsPage.qml',
		'shell/settings/TagCard.qml',
		'shell/settings/RulesPage.qml',
		'shell/settings/BindsPage.qml',
		'shell/settings/RuleCard.qml',
		'shell/settings/BindCard.qml',
		'shell/settings/RuleFieldRow.qml',
		'shell/settings/Matugen.qml',
		'shell/settings/MatugenPage.qml',
		'shell/settings/DiscordPage.qml',
		'shell/settings/NotificationsPage.qml',
	],
	install_dir: qmldir / 'settings',
)

# ── the QML plugin ───────────────────────────────────────────────────────────
#
# `import Asteroidz.Bar` -- the two things QML cannot do: draw an HDR
# wallpaper (Backdrop) and ask whether a file exists (Paths).
#
# It is loaded through an import path the launcher sets, NOT installed into
# Qt's own qml directory. Writing into /usr/lib/qt6/qml would tie this package
# to a Qt version in a way that breaks silently on the next Qt rebuild, and
# would put a module nothing else can use where every Qt application looks.
qt6 = import('qt6')
qt6_dep = dependency('qt6', modules: ['Core', 'Gui', 'Qml'])
# Asked for by name here as well as through asteroidzbg: Paths::imageExtensions
# reports what the decoder can read, so the plugin includes its header directly
# rather than relying on a transitive dependency it does not declare.
gdkpixbuf_dep = dependency('gdk-pixbuf-2.0')

# Apple dynamic wallpapers: several images in one HEIC with a schedule saying
# which of them belongs to the time of day. libheif rather than gdk-pixbuf,
# because gdk-pixbuf only ever hands back the PRIMARY image -- which is exactly
# why such a file looks like an ordinary still.
heif_dep = dependency('libheif')
png_dep = dependency('libpng')

# Their own library, so gdk-pixbuf's include paths never reach the C++ side:
# with them on the same target Qt's `#define signals Q_SIGNALS` fails to
# compile.
imageformats_lib = static_library(
	'azbarimageformats',
	['plugin/imageformats.c', 'plugin/dynwall.c'],
	dependencies: [gdkpixbuf_dep, heif_dep, png_dep],
	pic: true,
)

plugin_moc = qt6.preprocess(
	moc_headers: ['plugin/wallpaper.hpp', 'plugin/paths.hpp', 'plugin/windowicon.hpp'],
	# plugin.cpp declares its class in the .cpp and ends with
	# `#include "plugin.moc"`, which is the form moc expects for a type that
	# has no header of its own.
	moc_sources: ['plugin/plugin.cpp'],
	dependencies: qt6_dep,
)

shared_module(
	'asteroidzbarplugin',
	[
		'plugin/plugin.cpp',
		'plugin/wallpaper.cpp',
		'plugin/paths.cpp',
		'plugin/windowicon.cpp',
		plugin_moc,
	],
	dependencies: [qt6_dep, asteroidzbg_dep],
	link_with: imageformats_lib,
	install: true,
	install_dir: qmlplugindir,
	# A QML plugin is dlopened by name from its qmldir; the lib prefix is
	# part of that name (`plugin asteroidzbarplugin` finds
	# libasteroidzbarplugin.so), so the default naming is what is wanted here.
	name_prefix: 'lib',
)

install_data('plugin/qmldir', install_dir: qmlplugindir)

# The matugen template.
#
# Shipped rather than left to live only in somebody's ~/.config, which is where it
# was: the palette the whole desktop is themed from existed on exactly one machine
# and no installation produced it.
#
# Installed to /usr/share, NOT copied into ~/.config at install time. A package
# that wrote into a home directory would overwrite a template the user had tuned,
# and would do it on every upgrade. The Palette page seeds the user copy from this
# one the first time it is opened and the file is absent, which is the only moment
# where doing so cannot destroy anything.
install_data(
	['matugen/asteroidz-colors.kdl', 'matugen/README.md'],
	install_dir: get_option('datadir') / 'asteroidz-bar' / 'matugen',
)


# The plugins.
#
# They move here with the module that runs them: the protocol is the shell's
# now, and a plugin shipped by the compositor would be a package that installs
# scripts only another package can use.
install_data(
	[
		'plugins/asteroidz-bar-nordvpn',
		'plugins/asteroidz-bar-discord',
		'plugins/asteroidz-bar-reminders',
	],
	install_dir: get_option('bindir'),
	install_mode: 'rwxr-xr-x',
)

# Not a launcher -- an identity.
#
# asteroidz-bar-discord registers a global shortcut through the portal, and
# xdg-desktop-portal refuses GlobalShortcuts to a caller with no app id ("An app
# id is required"). The id it claims must resolve to a .desktop glib can load,
# whose Exec binary EXISTS -- glib returns NULL for a dangling one and the portal
# then answers "App info not found", so push-to-talk never binds and nothing else
# looks wrong. Installed beside the bridge so the two cannot drift apart.
install_data(
	'plugins/org.asteroidzman.DiscordPTT.desktop',
	install_dir: get_option('datadir') / 'applications',
)

# The launcher exists to pin Qt's DPI handling to the compositor's; see the
# script itself. The installed copy needs to know where the QML landed.
conf = configuration_data()
conf.set('SHELLDIR', get_option('prefix') / qmldir)

configure_file(
	input: 'bin/asteroidz-bar',
	output: 'asteroidz-bar',
	configuration: conf,
	format: 'cmake@',
	install: true,
	install_dir: get_option('bindir'),
	install_mode: 'rwxr-xr-x',
)
