project(
	'asteroidz-bar',
	['c', 'cpp'],
	version: '0.1.0',
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
		'shell/Wallpaper.qml',
		'shell/Arrange.qml',
		'shell/FormRow.qml',
		'shell/Picker.qml',
		'shell/Toggle.qml',
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
		'shell/modules/Network.qml',
		'shell/modules/Volume.qml',
		'shell/modules/Idle.qml',
		'shell/modules/Notify.qml',
		'shell/modules/Weather.qml',
		'shell/modules/Media.qml',
		'shell/modules/Spectrum.qml',
		'shell/modules/Tray.qml',
		'shell/modules/Display.qml',
		'shell/modules/Custom.qml',
	],
	install_dir: qmldir / 'modules',
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

plugin_moc = qt6.preprocess(
	moc_headers: ['plugin/wallpaper.hpp', 'plugin/paths.hpp'],
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
		plugin_moc,
	],
	dependencies: [qt6_dep, asteroidzbg_dep],
	install: true,
	install_dir: qmlplugindir,
	# A QML plugin is dlopened by name from its qmldir; the lib prefix is
	# part of that name (`plugin asteroidzbarplugin` finds
	# libasteroidzbarplugin.so), so the default naming is what is wanted here.
	name_prefix: 'lib',
)

install_data('plugin/qmldir', install_dir: qmlplugindir)

# The plugins.
#
# They move here with the module that runs them: the protocol is the shell's
# now, and a plugin shipped by the compositor would be a package that installs
# scripts only another package can use.
install_data(
	[
		'plugins/asteroidz-bar-nordvpn',
		'plugins/asteroidz-bar-discord',
		'plugins/asteroidz-bar-medication',
	],
	install_dir: get_option('bindir'),
	install_mode: 'rwxr-xr-x',
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
