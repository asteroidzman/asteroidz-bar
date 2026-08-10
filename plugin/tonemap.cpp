#include "tonemap.h"

#include <cmath>

namespace tonemap {

double clamp01(double x) {
	if (x < 0.0) return 0.0;
	if (x > 1.0) return 1.0;
	return x;
}

double pqEotfNits(double e) {
	// ST 2084 constants, as ratios rather than decimals: they are exact in the
	// standard and a transcribed decimal is a silent few-percent error.
	constexpr double m1 = 2610.0 / 16384.0;
	constexpr double m2 = 2523.0 / 4096.0 * 128.0;
	constexpr double c1 = 3424.0 / 4096.0;
	constexpr double c2 = 2413.0 / 4096.0 * 32.0;
	constexpr double c3 = 2392.0 / 4096.0 * 32.0;

	if (e <= 0.0) return 0.0;
	if (e > 1.0) e = 1.0;

	const double p = std::pow(e, 1.0 / m2);
	double num = p - c1;
	if (num < 0.0) num = 0.0;
	const double den = c2 - c3 * p;
	// den is positive for every e in 0..1 (c2 - c3 == 0.1640625 at e == 1), so
	// this guard is for a caller that passed something else.
	if (den <= 0.0) return 10000.0;
	return 10000.0 * std::pow(num / den, 1.0 / m1);
}

double hlgInverseOetf(double e) {
	constexpr double a = 0.17883277;
	constexpr double b = 1.0 - 4.0 * a;
	// 0.5 - a*ln(4a). Written out rather than computed from a: ln(4a) is
	// NEGATIVE (4a is 0.715), and the first version of this line multiplied by
	// the magnitude with the sign dropped, which put c at 0.32 instead of
	// 0.56. The curve still looked plausible -- monotonic, 0 at 0 -- and only
	// its top end was wrong, so nothing but an assertion on the endpoint could
	// have caught it.
	constexpr double c = 0.55991073;

	if (e <= 0.0) return 0.0;
	if (e > 1.0) e = 1.0;
	if (e <= 0.5) return e * e / 3.0;
	return (std::exp((e - c) / a) + b) / 12.0;
}

double hlgOotfScale(double rScene, double gScene, double bScene, double peakNits) {
	// BT.2020 luma coefficients: the OOTF is defined on scene luminance, and
	// applying it per channel instead would shift hue on anything saturated.
	const double ys = 0.2627 * rScene + 0.6780 * gScene + 0.0593 * bScene;
	if (ys <= 0.0) return 0.0;

	// System gamma for the nominal peak, BT.2100: 1.2 at 1000 cd/m², drifting
	// with the display's brightness. Below 1000 the formula would pull it
	// under 1.2; clamped there because a thumbnail is not a mastering monitor
	// and the alternative is an inverted curve for a low-peak file.
	double gamma = 1.2;
	if (peakNits > 1000.0) gamma += 0.42 * std::log10(peakNits / 1000.0);

	return peakNits * std::pow(ys, gamma - 1.0);
}

void bt2020ToSrgb(double& r, double& g, double& b) {
	const double nr = 1.6604910 * r - 0.5876411 * g - 0.0728499 * b;
	const double ng = -0.1245505 * r + 1.1328999 * g - 0.0083494 * b;
	const double nb = -0.0181508 * r - 0.1005789 * g + 1.1187297 * b;
	r = nr;
	g = ng;
	b = nb;
}

double reinhard(double x, double lw) {
	if (x <= 0.0) return 0.0;
	// A picture whose brightest pixel is at or below diffuse white needs no
	// compression at all -- and dividing by an lw under 1 would BOOST it, so a
	// dim HDR file would come out brighter than the same scene in SDR.
	if (lw <= 1.0) return clamp01(x);
	return x * (1.0 + x / (lw * lw)) / (1.0 + x);
}

double srgbOetf(double x) {
	x = clamp01(x);
	if (x <= 0.0031308) return 12.92 * x;
	// Clamped on the way out as well as in: 1.055 * pow(1, 1/2.4) - 0.055 is
	// 1.0000000000000002 in doubles, and the caller scales this by 255 into a
	// byte. Harmless there, and not harmless for anything that assumes the
	// range it was promised.
	return clamp01(1.055 * std::pow(x, 1.0 / 2.4) - 0.055);
}

} // namespace tonemap
