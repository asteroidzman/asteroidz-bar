# Maintainer: ralf <ralf.wierzbicki@gmail.com>
pkgname=asteroidz-bar
pkgver=0.1.0.r15.g5e1aff6
pkgrel=1
pkgdesc='The asteroidz shell: status bar and HDR10 wallpaper, out of the compositor'
arch=('x86_64')
url='https://github.com/asteroidzman/asteroidz-bar'
license=('MIT')
depends=(
  'quickshell'        # the shell runtime (quickshell-git provides it)
  'qt6-base'
  'qt6-declarative'
  'qt6-5compat'       # ColorOverlay: the icon tint is a mask, not a blend
  # The wallpaper's, which the QML plugin links statically -- there is no
  # separate wallpaper program any more, so these are this package's own.
  'cairo' 'wayland' 'gdk-pixbuf2' 'libjxl' 'libavif'
)
makedepends=('meson' 'ninja' 'wayland-protocols' 'git')
optdepends=(
  'asteroidz: the compositor this draws the bar for'
  'cava: the media visualiser'
  'swaync: the notification bell'
  'pipewire: the volume module'
  'grim: contrib/parity.sh and contrib/tray-test.sh'
)
# Built from the local checkout: this has no remote yet. Swap for
#   source=("git+$url.git#tag=$pkgver")
# the day it does -- nothing else here changes.
#
# $startdir is the directory holding this PKGBUILD, i.e. the repo itself, so
# what gets packaged is what is COMMITTED there. Building the working tree
# directly would quietly package uncommitted edits, and "which version is
# installed" then stops having an answer.
source=("git+file://$startdir")
sha256sums=('SKIP')

pkgver() {
  cd "$srcdir/$pkgname"
  # 0.1.0.r12.gab34cd1 -- the tag, commits since, and the commit itself, so an
  # installed build can always be traced back to a revision.
  #
  # An `if`, not `git describe ... | sed ... || fallback`: in a pipeline the
  # exit status is sed's, so the fallback never runs and an untagged repo
  # produces an EMPTY pkgver, which makepkg rejects outright.
  local desc
  if desc="$(git describe --long --tags 2>/dev/null)" && [ -n "$desc" ]; then
    printf '%s' "$desc" | sed 's/\([^-]*-g\)/r\1/;s/-/./g'
  else
    printf '0.1.0.r%s.g%s' \
      "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
  fi
}

build() {
  arch-meson "$pkgname" build
  meson compile -C build
}

package() {
  meson install -C build --destdir "$pkgdir"
  install -Dm644 "$srcdir/$pkgname/LICENSE" \
    "$pkgdir/usr/share/licenses/$pkgname/LICENSE" 2>/dev/null || true
  # swaybg's licence, which asteroidzbg is a fork of
  install -Dm644 "$srcdir/$pkgname/subprojects/asteroidzbg/LICENSE" \
    "$pkgdir/usr/share/licenses/$pkgname/LICENSE.asteroidzbg"
}
