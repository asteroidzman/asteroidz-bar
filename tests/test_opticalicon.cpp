// Unit test for the tray's optical-weight normalisation.
//
// The two functions here are the whole of the correction, and both are pure:
// coverage() reads pixels and returns a number, scaleFor() turns that number
// into a factor. Neither needs a compositor, a tray, or a running bar, and
// testing them there would be testing Qt's image pipeline instead.
//
// What this cannot check is that the provider is REACHABLE from QML -- the
// failure that actually happened. contrib/tray-test.sh covers that end, by
// treating "Invalid image provider" as an error.

#include "../plugin/opticalicon.hpp"

#include <QtGui/QImage>
#include <QtGui/QGuiApplication>

#include <cstdio>
#include <cmath>

static int failures = 0;

static void check(bool cond, const char* what) {
	std::printf("  %s %s\n", cond ? "ok  " : "FAIL", what);
	if (!cond) ++failures;
}

static bool near(double a, double b) { return std::fabs(a - b) < 0.005; }

// A `side`-square with an opaque `ink`-square centred in it.
static QImage square(int side, int ink, int alpha = 255) {
	QImage im(side, side, QImage::Format_ARGB32);
	im.fill(Qt::transparent);
	const int o = (side - ink) / 2;
	for (int y = o; y < o + ink; ++y)
		for (int x = o; x < o + ink; ++x) im.setPixel(x, y, qRgba(255, 255, 255, alpha));
	return im;
}

int main(int argc, char** argv) {
	int fake = 1;
	QGuiApplication app(fake, argv);
	(void)argc;

	check(near(OpticalIconProvider::coverage(square(64, 64)), 1.0),
	      "a fully covered square measures 1.0");
	check(near(OpticalIconProvider::coverage(square(64, 32)), 0.25),
	      "half the side is a quarter of the area");
	check(OpticalIconProvider::coverage(QImage()) == 0.0, "a null image measures 0");

	// Faint pixels are antialiasing, a shadow or a glow, and carry no weight.
	check(near(OpticalIconProvider::coverage(square(64, 64, 40)), 0.0),
	      "alpha below the ink threshold does not count");

	// A wide logo is measured against the SQUARE it will sit in, not its own
	// bitmap -- otherwise it scores as dense as a square one and gets shrunk
	// for being wide.
	{
		QImage wide(64, 32, QImage::Format_ARGB32);
		wide.fill(QColor(255, 255, 255, 255));
		check(near(OpticalIconProvider::coverage(wide), 0.5),
		      "a 2:1 image is measured against its longer side");
	}

	// Shrink only, and only above the target.
	check(near(OpticalIconProvider::scaleFor(0.4), 1.0), "sparse artwork is left alone");
	check(near(OpticalIconProvider::scaleFor(OpticalIconProvider::kTargetCoverage), 1.0),
	      "artwork exactly at the target is left alone");
	check(OpticalIconProvider::scaleFor(0.9) < 1.0, "dense artwork is scaled down");
	check(near(OpticalIconProvider::scaleFor(0.8),
	           std::sqrt(OpticalIconProvider::kTargetCoverage / 0.8)),
	      "the factor equalises area, not extent");
	check(near(OpticalIconProvider::scaleFor(1.0), OpticalIconProvider::kMinScale),
	      "a solid square clamps at the floor rather than collapsing");
	check(near(OpticalIconProvider::scaleFor(0.0), 1.0), "empty artwork is left alone");

	// The regression that made this feature a silent no-op: a target above
	// everything real means nothing is ever corrected.
	check(OpticalIconProvider::kTargetCoverage < 0.72,
	      "the target sits below the density real tray artwork measures");

	std::printf("\n%s\n", failures == 0 ? "all passed" : "FAILURES");
	return failures == 0 ? 0 : 1;
}
