project(
	'asteroidzbg',
	'c',
	version: '1.2.2',
	license: 'MIT',
	meson_version: '>=0.59.0',
	default_options: [
		'c_std=c11',
		'warning_level=2',
		'werror=true',
	],
)

cc = meson.get_compiler('c')

add_project_arguments('-D_POSIX_C_SOURCE=200809L', language: 'c')

add_project_arguments(cc.get_supported_arguments([
	'-Wno-unused-parameter',
	'-Wno-unused-result',
	'-Wundef',
	'-Wvla',
]), language: 'c')

is_freebsd = host_machine.system().startswith('freebsd')
if is_freebsd
	add_project_arguments('-D_C11_SOURCE', language: 'c')
endif

rt = cc.find_library('rt')

wayland_client = dependency('wayland-client')
wayland_protos = dependency('wayland-protocols', version: '>=1.41')
wayland_scanner = dependency('wayland-scanner', version: '>=1.14.91', native: true)
cairo = dependency('cairo')
gdk_pixbuf = dependency('gdk-pixbuf-2.0', required: get_option('gdk-pixbuf'))
libavif = dependency('libavif', version: '>=0.11', required: get_option('avif'))
libjxl = dependency('libjxl', version: '>=0.8', required: get_option('jxl'))

git = find_program('git', required: false, native: true)

version = '"@0@"'.format(meson.project_version())
if git.found()
	git_commit = run_command([git, '--git-dir=.git', 'rev-parse', '--short', 'HEAD'], check: false)
	git_branch = run_command([git, '--git-dir=.git', 'rev-parse', '--abbrev-ref', 'HEAD'], check: false)
	if git_commit.returncode() == 0 and git_branch.returncode() == 0
		version = '"@0@-@1@ (" __DATE__ ", branch \'@2@\')"'.format(
			meson.project_version(),
			git_commit.stdout().strip(),
			git_branch.stdout().strip(),
		)
	endif
endif

add_project_arguments([
	'-DASTEROIDZBG_VERSION=@0@'.format(version),
	'-DHAVE_GDK_PIXBUF=@0@'.format(gdk_pixbuf.found().to_int()),
	'-DHAVE_LIBAVIF=@0@'.format(libavif.found().to_int()),
	'-DHAVE_LIBJXL=@0@'.format(libjxl.found().to_int()),
], language: 'c')

wl_protocol_dir = wayland_protos.get_variable('pkgdatadir')

wayland_scanner_prog = find_program(wayland_scanner.get_variable('wayland_scanner'), native: true)

wayland_scanner_code = generator(
	wayland_scanner_prog,
	output: '@BASENAME@-protocol.c',
	arguments: ['private-code', '@INPUT@', '@OUTPUT@'],
)

wayland_scanner_client = generator(
	wayland_scanner_prog,
	output: '@BASENAME@-client-protocol.h',
	arguments: ['client-header', '@INPUT@', '@OUTPUT@'],
)

protos_src = []

client_protocols = [
	# xdg-shell is not spoken here at all, but the layer-shell protocol below
	# mentions xdg_popup in get_popup, so its generated code carries an
	# extern reference to xdg_popup_interface. Leaving it out still links --
	# and then fails at dlopen with `undefined symbol: xdg_popup_interface`,
	# which is a long way from the cause.
	wl_protocol_dir / 'stable/xdg-shell/xdg-shell.xml',
	wl_protocol_dir / 'stable/viewporter/viewporter.xml',
	wl_protocol_dir / 'staging/fractional-scale/fractional-scale-v1.xml',
	wl_protocol_dir / 'staging/color-management/color-management-v1.xml',
	'wlr-layer-shell-unstable-v1.xml',
]


foreach filename : client_protocols
	protos_src += wayland_scanner_code.process(filename)
	protos_src += wayland_scanner_client.process(filename)
endforeach

# A static library, not a program.
#
# asteroidzbg used to be its own process with its own connection and its own
# event loop; the shell now draws the wallpaper itself, on the display Qt
# already has (see include/backdrop.h). What is left here is everything that
# made this a fork of swaybg in the first place -- the HDR decoders, the
# colour-management tagging, the 10-bit buffers -- with the process removed.
#
# Static because there is exactly one consumer and it ships in the same
# package: a shared library would be a versioned ABI between two halves of one
# program.
libasteroidzbg = static_library(
	'asteroidzbg',
	[
		'backdrop.c',
		'background-image.c',
		'cairo.c',
		'color-management.c',
		'hdr-image.c',
		'log.c',
		'pool-buffer.c',
		protos_src,
	],
	include_directories: 'include',
	dependencies: [
		cairo,
		rt,
		gdk_pixbuf,
		libavif,
		libjxl,
		wayland_client,
	],
	pic: true,
	install: false,
)

asteroidzbg_dep = declare_dependency(
	link_with: libasteroidzbg,
	include_directories: include_directories('include'),
	dependencies: [cairo, wayland_client],
)
