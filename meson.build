project(
	'asteroidz-bar',
	'c',
	version: '0.1.0',
	license: 'MIT',
	meson_version: '>=0.59.0',
)

# The wallpaper.
#
# asteroidzbg is here rather than beside it because a shell that cannot set the
# wallpaper is not a shell -- and because the two are already coupled: the bar
# is what will offer the wallpaper menu, and the palette the bar draws itself
# with is generated FROM the wallpaper by matugen. One project, one package,
# one version.
#
# It stays a C binary and is not reimplemented in QML, for one reason: HDR.
# asteroidzbg tags its surface through wp_color_manager_v1 with BT.2020
# primaries and the PQ transfer function, and decodes 10-bit sources to match
# (color-management.c, hdr-image.c). Qt gives QML no way to do that, so
# "porting" it would mean quietly dropping HDR wallpapers on an HDR desktop.
wallpaper = subproject('asteroidzbg')

qmldir = get_option('datadir') / 'asteroidz-bar'

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
conf.set('BINDIR', get_option('prefix') / get_option('bindir'))

configure_file(
	input: 'bin/asteroidz-bar',
	output: 'asteroidz-bar',
	configuration: conf,
	format: 'cmake@',
	install: true,
	install_dir: get_option('bindir'),
	install_mode: 'rwxr-xr-x',
)
