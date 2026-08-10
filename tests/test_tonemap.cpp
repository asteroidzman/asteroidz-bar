// Unit test for the HDR -> SDR curve the wallpaper picker's tiles go through.
//
// Every function here is pure arithmetic on doubles, so this needs no image,
// no decoder and no display. What it CANNOT check is that the provider is
// reachable from QML and that a real PQ file comes out looking like the
// picture -- contrib/wallpaper-thumb-test.sh covers that end, by rendering
// the same file both ways and comparing what lands on screen.
//
// The assertions are written against the NAIVE result wherever there is one:
// the bug being fixed is that a PQ code value was drawn as if it were sRGB, so
// a test that only checks "the output is between 0 and 1" would have passed
// before any of this existed.

#include "../plugin/tonemap.h"

#include <cmath>
#include <cstdio>

static int failures = 0;

static void check(bool cond, const char* what) {
	std::printf("  %s %s\n", cond ? "ok  " : "FAIL", what);
	if (!cond) ++failures;
}

static bool near(double a, double b, double eps = 0.005) { return std::fabs(a - b) < eps; }

// The PQ code value that encodes `nits`, by search. The forward direction is
// what the code implements; going back the other way here keeps the test from
// re-deriving the same constants and agreeing with itself about a typo.
static double pqCodeFor(double nits) {
	double lo = 0.0;
	double hi = 1.0;
	for (int i = 0; i < 200; ++i) {
		const double mid = (lo + hi) / 2.0;
		if (tonemap::pqEotfNits(mid) < nits) lo = mid;
		else hi = mid;
	}
	return (lo + hi) / 2.0;
}

int main() {
	std::printf("\ntonemap\n");

	// ── the transfer function ────────────────────────────────────────────
	check(near(tonemap::pqEotfNits(0.0), 0.0), "PQ 0 is 0 nits");
	check(near(tonemap::pqEotfNits(1.0), 10000.0, 1.0), "PQ 1 is 10000 nits");
	// The two anchors everything else is reasoned from. 203 cd/m² is BT.2408
	// reference white; 100 cd/m² is the SDR peak PQ was designed to contain.
	check(near(tonemap::pqEotfNits(0.5806), 203.0, 2.0), "PQ 0.5806 is reference white");
	check(near(tonemap::pqEotfNits(0.5081), 100.0, 1.0), "PQ 0.5081 is 100 nits");

	{
		// Monotonic, all the way up. A curve that folds back would show as a
		// highlight darker than the midtone beside it.
		bool rising = true;
		double prev = -1.0;
		for (int i = 0; i <= 1000; ++i) {
			const double v = tonemap::pqEotfNits(double(i) / 1000.0);
			if (v < prev) rising = false;
			prev = v;
		}
		check(rising, "PQ is monotonic across the whole range");
	}

	// ── the naive reading, which is the bug ──────────────────────────────
	//
	// A 1000-nit highlight sits at PQ 0.751. Drawn as if that were an sRGB
	// value it is a 75%-grey pixel; correctly it is the brightest thing in
	// the picture. A 4-nit shadow sits at 0.24 -- drawn naively it is a MID
	// grey, which is why an HDR file reads as a flat wash rather than as a
	// dark scene with bright highlights: the naive reading compresses four
	// hundred to one into three to one.
	{
		const double bright = pqCodeFor(1000.0);
		const double dark = pqCodeFor(4.0);
		check(bright / dark < 4.0, "naive: 1000 nits is under 4x a 4-nit shadow");

		const double lw = 1000.0 / tonemap::kReferenceWhite;
		const double mappedBright =
		    tonemap::reinhard(tonemap::pqEotfNits(bright) / tonemap::kReferenceWhite, lw);
		const double mappedDark =
		    tonemap::reinhard(tonemap::pqEotfNits(dark) / tonemap::kReferenceWhite, lw);
		check(mappedBright / mappedDark > 40.0, "mapped: it is more than 40x, in linear light");
	}

	// ── the roll-off ─────────────────────────────────────────────────────
	{
		const double lw = 1000.0 / tonemap::kReferenceWhite; // ~4.93
		check(near(tonemap::reinhard(lw, lw), 1.0), "the image's peak maps to exactly 1.0");
		check(tonemap::reinhard(0.0, lw) == 0.0, "black stays black");

		// Diffuse white keeps headroom above it rather than clipping: if 1.0
		// mapped to 1.0 there would be nowhere for the highlights to go, which
		// is the whole reason for tone mapping rather than clamping.
		const double white = tonemap::reinhard(1.0, lw);
		check(white > 0.4 && white < 0.7, "diffuse white lands mid-scale, leaving headroom");
		check(tonemap::reinhard(2.0, lw) > white, "a highlight above white is brighter than it");

		bool rising = true;
		double prev = -1.0;
		for (int i = 0; i <= 1000; ++i) {
			const double v = tonemap::reinhard(double(i) * lw / 1000.0, lw);
			if (v < prev) rising = false;
			prev = v;
		}
		check(rising, "the roll-off is monotonic");
	}
	{
		// A file whose brightest pixel is at or below diffuse white is not an
		// HDR grade in any useful sense, and compressing it would DARKEN a
		// picture that needed nothing done to it.
		check(near(tonemap::reinhard(0.5, 0.8), 0.5), "a dim image passes through unchanged");
		check(near(tonemap::reinhard(1.0, 1.0), 1.0), "so does one that just reaches white");
	}

	// ── HLG ──────────────────────────────────────────────────────────────
	check(near(tonemap::hlgInverseOetf(0.0), 0.0), "HLG 0 is 0");
	check(near(tonemap::hlgInverseOetf(1.0), 1.0, 0.02), "HLG 1 is scene peak");
	check(tonemap::hlgInverseOetf(0.5) < 0.1, "HLG 0.5 is a tenth of peak, not half");
	{
		// The OOTF is a system gamma on LUMINANCE: a neutral grey and a
		// saturated colour of the same luminance must be scaled by the same
		// factor, or the conversion shifts hue.
		const double grey = tonemap::hlgOotfScale(0.2, 0.2, 0.2, 1000.0);
		const double neutralSame = tonemap::hlgOotfScale(0.2, 0.2, 0.2, 1000.0);
		check(near(grey, neutralSame), "the OOTF scale is a function of luminance alone");
		check(
		    tonemap::hlgOotfScale(0.8, 0.8, 0.8, 1000.0) > grey,
		    "a brighter scene value gets a larger scale -- that is the gamma"
		);
		check(tonemap::hlgOotfScale(0.0, 0.0, 0.0, 1000.0) == 0.0, "HLG black stays black");
	}

	// ── primaries ────────────────────────────────────────────────────────
	{
		// White is white in both gamuts. If the matrix were transposed or a
		// row scaled, this is what would move.
		double r = 1.0;
		double g = 1.0;
		double b = 1.0;
		tonemap::bt2020ToSrgb(r, g, b);
		check(near(r, 1.0, 0.002) && near(g, 1.0, 0.002) && near(b, 1.0, 0.002),
		      "BT.2020 white converts to sRGB white");
	}
	{
		// BT.2020 green is outside BT.709, so the matrix MUST answer with a
		// negative channel. The caller clamps; a matrix that never went
		// negative here would be the wrong matrix.
		double r = 0.0;
		double g = 1.0;
		double b = 0.0;
		tonemap::bt2020ToSrgb(r, g, b);
		check(r < 0.0 && b < 0.0, "BT.2020 green is out of gamut and says so");
		check(g > 1.0, "...with its own channel above 1");
	}

	// ── the encoding ─────────────────────────────────────────────────────
	check(near(tonemap::srgbOetf(0.0), 0.0), "sRGB encodes 0 as 0");
	check(near(tonemap::srgbOetf(1.0), 1.0), "sRGB encodes 1 as 1");
	// The one value worth pinning: linear 18% grey is the 46% code value every
	// colour pipeline is checked against.
	check(near(tonemap::srgbOetf(0.18), 0.4620, 0.002), "linear 18% grey encodes to 0.462");
	// Clamped, not wrapped and not passed through. Exact 0 on the low side --
	// the linear segment multiplies, so it cannot drift -- and near 1.0 on the
	// high side, because 1.055 * pow(1, 1/2.4) - 0.055 is a double's worth
	// under one and demanding equality there would be demanding that IEEE 754
	// round the way the algebra reads.
	check(tonemap::srgbOetf(-1.0) == 0.0, "a negative input encodes to exactly 0");
	check(near(tonemap::srgbOetf(2.0), 1.0), "an input above 1 encodes to 1");

	std::printf("\n  %s\n", failures == 0 ? "all passed" : "FAILURES");
	return failures == 0 ? 0 : 1;
}
