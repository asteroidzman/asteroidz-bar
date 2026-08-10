#include "palette.hpp"

#include "hdrthumb.hpp"

#include <cmath>

#include <QtCore/QFileInfo>
#include <QtCore/QRegularExpression>
#include <QtCore/QUrl>
#include <QtGui/QColor>
#include <QtGui/QImage>

namespace {

// ── colour space ────────────────────────────────────────────────────────────
//
// sRGB <-> OKLab, Björn Ottosson's matrices. OKLab rather than CIELAB because
// its lightness is uniform enough to step through without the blue-shift CIELAB
// shows, and rather than HCT because HCT's tone axis crowds together in the
// shadows -- which is precisely the range a dark theme is built out of.

double srgbToLinear(double c) {
	return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
}

double linearToSrgb(double c) {
	return c <= 0.0031308 ? c * 12.92 : 1.055 * std::pow(c, 1.0 / 2.4) - 0.055;
}

using LabT = Palette::Lab;

LabT rgbToOklab(double r, double g, double b) {
	const auto lr = srgbToLinear(r);
	const auto lg = srgbToLinear(g);
	const auto lb = srgbToLinear(b);

	const auto l = std::cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
	const auto m = std::cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
	const auto s = std::cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);

	return {
	    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
	    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
	    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
	};
}

QColor oklabToColor(const LabT& lab) {
	const auto l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
	const auto m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
	const auto s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b;

	const auto l = l_ * l_ * l_;
	const auto m = m_ * m_ * m_;
	const auto s = s_ * s_ * s_;

	auto r = linearToSrgb(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s);
	auto g = linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s);
	auto b = linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);

	// Clamping is a gamut miss, and the honest cheap fix: a proper gamut map
	// would walk chroma down until the colour fits. Chroma here is already
	// conservative enough that the miss is small, and clipping a channel is
	// visually closer than the hue rotation naive clamping of Lab can cause.
	return QColor::fromRgbF(qBound(0.0, r, 1.0), qBound(0.0, g, 1.0), qBound(0.0, b, 1.0));
}

double chromaOf(const LabT& lab) { return std::hypot(lab.a, lab.b); }

// WCAG relative luminance, for the contrast solver and for contrastBetween().
double luminance(const QColor& c) {
	const auto r = srgbToLinear(c.redF());
	const auto g = srgbToLinear(c.greenF());
	const auto b = srgbToLinear(c.blueF());
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double contrastRatio(const QColor& a, const QColor& b) {
	const auto la = luminance(a);
	const auto lb = luminance(b);
	return (std::max(la, lb) + 0.05) / (std::min(la, lb) + 0.05);
}

// A colour at a given lightness and chroma on the seed's hue.
LabT atTone(const LabT& seed, double lightness, double chromaScale) {
	const auto c = chromaOf(seed);
	if (c < 1e-6) return { lightness, 0, 0 };
	const auto scale = chromaScale * c / c; // keep hue, set chroma below
	Q_UNUSED(scale);
	const auto hueA = seed.a / c;
	const auto hueB = seed.b / c;
	const auto targetC = c * chromaScale;
	return { lightness, hueA * targetC, hueB * targetC };
}

// Solve lightness so `fg` clears `target` contrast against `bg`.
//
// This is the piece Material does not do: it assigns a fixed tone to an "on"
// role and accepts whatever contrast falls out. Here the tone is searched --
// bisection on lightness, away from the background -- so a pale wallpaper
// cannot produce a focused pill with unreadable text on it.
QColor solveForContrast(const LabT& hue, const QColor& bg, double target, bool preferLight) {
	auto lo = preferLight ? 0.5 : 0.0;
	auto hi = preferLight ? 1.0 : 0.5;

	QColor best = oklabToColor({ preferLight ? 1.0 : 0.0, 0, 0 });
	for (int i = 0; i < 24; i++) {
		const auto mid = (lo + hi) / 2.0;
		const auto candidate = oklabToColor(atTone(hue, mid, 0.25));
		const auto ratio = contrastRatio(candidate, bg);

		if (ratio >= target) {
			best = candidate;
			// Pull back toward the background: the LEAST extreme colour that
			// still passes keeps the seed's character instead of collapsing
			// every foreground to white or black.
			if (preferLight) hi = mid;
			else lo = mid;
		} else {
			if (preferLight) lo = mid;
			else hi = mid;
		}
	}
	return best;
}

QString hex(const QColor& c) {
	return QStringLiteral("#%1%2%3")
	    .arg(c.red(), 2, 16, QLatin1Char('0'))
	    .arg(c.green(), 2, 16, QLatin1Char('0'))
	    .arg(c.blue(), 2, 16, QLatin1Char('0'));
}

} // namespace

Palette::Palette(QObject* parent): QObject(parent) {}

void Palette::setSource(const QString& source) {
	if (this->mSource == source) return;
	this->mSource = source;
	emit this->sourceChanged();
	this->regenerate();
}

void Palette::setDark(bool dark) {
	if (this->mDark == dark) return;
	this->mDark = dark;
	emit this->darkChanged();
	this->buildRoles();
}

void Palette::setContrast(double contrast) {
	contrast = qBound(0.0, contrast, 1.0);
	if (qFuzzyCompare(this->mContrast, contrast)) return;
	this->mContrast = contrast;
	emit this->contrastChanged();
	this->buildRoles();
}

void Palette::regenerate() {
	if (this->quantise()) this->buildRoles();
}

// ── quantisation ────────────────────────────────────────────────────────────

bool Palette::quantise() {
	if (this->mSource.isEmpty()) return false;

	auto path = this->mSource;
	if (path.startsWith(QStringLiteral("file://"))) path = QUrl(path).toLocalFile();
	if (!QFileInfo::exists(path)) {
		this->setError(QStringLiteral("no such wallpaper: %1").arg(path));
		return false;
	}
	if (this->mQuantisedSource == path && !this->mClusters.isEmpty()) return true;

	// 128px on the long edge, through the HDR-aware decoder. Quantisation wants
	// the distribution of colour, not detail, and a 4K decode scaled down is
	// both faster and less noisy than sampling the original sparsely -- so the
	// size is asked for up front rather than scaled to afterwards.
	//
	// NOT `QImage image(path)`, which is what this was. Qt reads JPEG XL and
	// AVIF here, and for an HDR file it hands back the file's code values
	// untouched: under PQ those are an encoding of absolute luminance, not
	// colours. Quantising them themes the desktop from the ENCODING --
	// washed-out, mid-grey, with an accent picked out of a picture nobody is
	// looking at, while the wallpaper on screen is a saturated sunset. The
	// same conversion the picker's tiles go through (plugin/tonemap.h) puts
	// the palette back on the pixels a person can actually see.
	QImage image = HdrThumbProvider::thumbnail(path, 128);
	if (image.isNull()) {
		// Said plainly rather than themed from nothing.
		this->setError(QStringLiteral("cannot decode %1").arg(QFileInfo(path).fileName()));
		return false;
	}
	image = image.convertToFormat(QImage::Format_RGB888);

	QList<LabT> points;
	points.reserve(image.width() * image.height());
	for (int y = 0; y < image.height(); y++) {
		const auto* line = image.constScanLine(y);
		for (int x = 0; x < image.width(); x++) {
			const auto* p = line + x * 3;
			points.append(rgbToOklab(p[0] / 255.0, p[1] / 255.0, p[2] / 255.0));
		}
	}
	if (points.isEmpty()) {
		this->setError(QStringLiteral("empty image"));
		return false;
	}

	// k-means in OKLab. Seeded by spreading the initial centres along
	// lightness rather than at random, so the result does not change between
	// runs on the same wallpaper -- a theme that differs each login is worse
	// than a slightly worse theme.
	constexpr int K = 8;
	QList<LabT> centres;
	for (int i = 0; i < K; i++) {
		const auto t = (i + 0.5) / K;
		centres.append(points.at(static_cast<int>(t * (points.size() - 1))));
	}

	QList<int> assign(points.size(), 0);
	for (int iter = 0; iter < 12; iter++) {
		auto moved = false;
		for (int i = 0; i < points.size(); i++) {
			auto bestD = std::numeric_limits<double>::max();
			auto bestK = 0;
			for (int k = 0; k < K; k++) {
				const auto dl = points.at(i).l - centres.at(k).l;
				const auto da = points.at(i).a - centres.at(k).a;
				const auto db = points.at(i).b - centres.at(k).b;
				const auto d = dl * dl + da * da + db * db;
				if (d < bestD) {
					bestD = d;
					bestK = k;
				}
			}
			if (assign.at(i) != bestK) {
				assign[i] = bestK;
				moved = true;
			}
		}

		QList<LabT> sums(K, LabT { 0, 0, 0 });
		QList<int> counts(K, 0);
		for (int i = 0; i < points.size(); i++) {
			auto& s = sums[assign.at(i)];
			s.l += points.at(i).l;
			s.a += points.at(i).a;
			s.b += points.at(i).b;
			counts[assign.at(i)]++;
		}
		for (int k = 0; k < K; k++) {
			if (counts.at(k) == 0) continue;
			centres[k] = { sums.at(k).l / counts.at(k),
			               sums.at(k).a / counts.at(k),
			               sums.at(k).b / counts.at(k) };
		}
		if (!moved) break;
	}

	QList<int> counts(K, 0);
	for (const auto a: assign) counts[a]++;

	this->mClusters.clear();
	for (int k = 0; k < K; k++) {
		if (counts.at(k) == 0) continue;
		Cluster c;
		c.centre = { centres.at(k).l, centres.at(k).a, centres.at(k).b };
		c.weight = static_cast<double>(counts.at(k)) / points.size();
		c.chroma = chromaOf(centres.at(k));
		this->mClusters.append(c);
	}

	// The seed: area WEIGHTED by chroma, not chroma alone.
	//
	// Material scores on colourfulness, which is why one saturated sunset in a
	// teal photograph themes the whole desktop orange. A theme should look like
	// its wallpaper, so prevalence leads -- but a nearly-grey cluster carries no
	// hue worth using, so chroma still has a vote, and near-black and near-white
	// clusters are held back because their hue is unreliable.
	double bestScore = -1;
	for (const auto& c: std::as_const(this->mClusters)) {
		const auto chromaTerm = std::min(c.chroma, 0.15) / 0.15;
		const auto midness = 1.0 - std::abs(c.centre.l - 0.55) / 0.55;
		const auto score = c.weight * (0.35 + 0.65 * chromaTerm) * std::max(0.15, midness);
		if (score > bestScore) {
			bestScore = score;
			this->mSeedLab = c.centre;
		}
	}

	// A wallpaper that really is grey gets a usable accent rather than a grey
	// one: keep its lightness, borrow enough chroma to be visible.
	if (chromaOf(this->mSeedLab) < 0.02) this->mSeedLab.b -= 0.06;

	this->mQuantisedSource = path;
	this->setError({});
	return true;
}

// ── roles ───────────────────────────────────────────────────────────────────

void Palette::buildRoles() {
	if (this->mClusters.isEmpty()) return;

	const auto& seed = this->mSeedLab;
	const auto dark = this->mDark;

	// Contrast targets.
	//
	// 11 for body text, not the 4.5 of WCAG AA. AA is a FLOOR for "legible at
	// all", and a first version that aimed at it produced a theme measurably
	// worse than the matugen it replaced: matugen's fixed tones happen to land
	// around 14 on a dark surface, so solving for exactly 4.5 traded a readable
	// desktop for a technically-compliant one. The solver's value was never
	// that its number is lower -- it is that the number is GUARANTEED, on any
	// wallpaper, instead of being wherever a fixed tone happens to fall.
	//
	// The slider spans comfortable to stark rather than illegible to adequate.
	const auto textTarget = 11.0 + 6.0 * this->mContrast;
	const auto dimTarget = 4.5 + 2.5 * this->mContrast;
	// Text ON an accent gets its own, lower target, and not as a compromise:
	// an accent is a small filled chip, not a page of body text. Holding it to
	// the body figure asks for a ratio the accent cannot reach -- 11:1 against
	// this wallpaper's primary is arithmetically impossible, the solver pins to
	// pure black, and the label loses every trace of the hue it sits on.
	const auto accentTextTarget = 4.5 + 2.5 * this->mContrast;

	// Surfaces: near the seed's hue but heavily desaturated, so the desktop
	// carries the wallpaper's cast without competing with it.
	const auto surfaceL = dark ? 0.16 : 0.96;
	const auto surface = oklabToColor(atTone(seed, surfaceL, 0.06));
	const auto surfaceLow = oklabToColor(atTone(seed, dark ? 0.13 : 0.99, 0.05));
	const auto surfaceHigh = oklabToColor(atTone(seed, dark ? 0.22 : 0.92, 0.08));
	const auto surfaceHighest = oklabToColor(atTone(seed, dark ? 0.26 : 0.88, 0.09));

	// The accent, at a lightness that reads on this background rather than at
	// a fixed tone.
	const auto primaryL = dark ? 0.72 : 0.48;
	auto primary = oklabToColor(atTone(seed, primaryL, 0.85));
	// If the accent itself does not separate from the surface, walk it toward
	// the opposite end until it does. A teal accent on a teal surface is the
	// commonest way a generated theme becomes unusable.
	if (contrastRatio(primary, surface) < dimTarget)
		primary = solveForContrast(seed, surface, dimTarget, dark);

	// Tertiary: a hue rotation, for the border gradient's second stop. Taken
	// from a DIFFERENT cluster when the wallpaper offers one far enough away in
	// hue, and only synthesised when it does not -- a second real colour from
	// the image beats a computed one every time.
	LabT tertiaryLab = seed;
	auto bestHueDist = 0.0;
	const auto seedC = std::max(chromaOf(seed), 1e-6);
	for (const auto& c: std::as_const(this->mClusters)) {
		if (c.chroma < 0.04) continue;
		const auto dot = (seed.a * c.centre.a + seed.b * c.centre.b) / (seedC * c.chroma);
		const auto dist = 1.0 - qBound(-1.0, dot, 1.0); // 0 same hue, 2 opposite
		if (dist > bestHueDist) {
			bestHueDist = dist;
			tertiaryLab = c.centre;
		}
	}
	if (bestHueDist < 0.35) {
		// No second hue worth having: rotate 60 degrees in the a/b plane.
		const auto ang = std::atan2(seed.b, seed.a) + M_PI / 3.0;
		tertiaryLab = { seed.l, std::cos(ang) * seedC, std::sin(ang) * seedC };
	}
	const auto tertiary = oklabToColor(atTone(tertiaryLab, dark ? 0.70 : 0.50, 0.75));

	// Error is deliberately NOT derived from the wallpaper. Red means error
	// regardless of what the picture is made of, and a themed error colour is
	// a warning you have taught yourself to ignore.
	const LabT redLab = rgbToOklab(0.86, 0.20, 0.22);
	const auto errorCol = oklabToColor(atTone(redLab, dark ? 0.66 : 0.48, 1.0));

	const auto onSurface = solveForContrast(seed, surface, textTarget, dark);
	const auto onSurfaceVariant = solveForContrast(seed, surface, dimTarget, dark);
	const auto onPrimary = solveForContrast(seed, primary, accentTextTarget, !dark);
	const auto onTertiary = solveForContrast(tertiaryLab, tertiary, accentTextTarget, !dark);
	const auto onError = solveForContrast(redLab, errorCol, accentTextTarget, false);
	const auto outline = solveForContrast(seed, surface, 1.6 + this->mContrast, dark);

	this->mRoles = QVariantMap {
	    {QStringLiteral("primary"), hex(primary)},
	    {QStringLiteral("on_primary"), hex(onPrimary)},
	    {QStringLiteral("primary_container"),
	     hex(oklabToColor(atTone(seed, dark ? 0.32 : 0.86, 0.45)))},
	    {QStringLiteral("on_primary_container"), hex(onSurface)},
	    {QStringLiteral("secondary"), hex(oklabToColor(atTone(seed, dark ? 0.66 : 0.52, 0.35)))},
	    {QStringLiteral("on_secondary"), hex(onPrimary)},
	    {QStringLiteral("tertiary"), hex(tertiary)},
	    {QStringLiteral("on_tertiary"), hex(onTertiary)},
	    {QStringLiteral("error"), hex(errorCol)},
	    {QStringLiteral("on_error"), hex(onError)},
	    {QStringLiteral("surface"), hex(surface)},
	    {QStringLiteral("surface_container_low"), hex(surfaceLow)},
	    {QStringLiteral("surface_container"), hex(surface)},
	    {QStringLiteral("surface_container_high"), hex(surfaceHigh)},
	    {QStringLiteral("surface_container_highest"), hex(surfaceHighest)},
	    {QStringLiteral("on_surface"), hex(onSurface)},
	    {QStringLiteral("on_surface_variant"), hex(onSurfaceVariant)},
	    {QStringLiteral("outline"), hex(outline)},

	    // The rest of Material's role set. Not aspiration: these are the names
	    // the templates on this machine actually reference, and a role a
	    // template asks for and does not get is left as a literal {{...}} in a
	    // config file -- which still looks like a config file, so the breakage
	    // is silent until something reads it.
	    {QStringLiteral("background"), hex(surface)},
	    {QStringLiteral("on_background"), hex(onSurface)},
	    {QStringLiteral("surface_dim"), hex(oklabToColor(atTone(seed, dark ? 0.12 : 0.88, 0.06)))},
	    {QStringLiteral("surface_bright"), hex(oklabToColor(atTone(seed, dark ? 0.30 : 1.00, 0.07)))},
	    {QStringLiteral("surface_container_lowest"),
	     hex(oklabToColor(atTone(seed, dark ? 0.10 : 1.00, 0.04)))},
	    // Inverse is the other scheme's surface, which is what makes a snackbar
	    // read as "not part of the page".
	    {QStringLiteral("inverse_surface"), hex(oklabToColor(atTone(seed, dark ? 0.90 : 0.20, 0.05)))},
	    {QStringLiteral("inverse_on_surface"),
	     hex(oklabToColor(atTone(seed, dark ? 0.18 : 0.94, 0.05)))},
	    {QStringLiteral("outline_variant"),
	     hex(oklabToColor(atTone(seed, dark ? 0.32 : 0.80, 0.10)))},
	    // Scrim and shadow are black in every Material scheme, light or dark:
	    // they are the absence of the surface, not a tint of it.
	    {QStringLiteral("scrim"), QStringLiteral("#000000")},
	    {QStringLiteral("shadow"), QStringLiteral("#000000")},
	    {QStringLiteral("source_color"), hex(oklabToColor(seed))},
	    {QStringLiteral("secondary_container"),
	     hex(oklabToColor(atTone(seed, dark ? 0.30 : 0.88, 0.25)))},
	    {QStringLiteral("on_secondary_container"), hex(onSurface)},
	    {QStringLiteral("tertiary_container"),
	     hex(oklabToColor(atTone(tertiaryLab, dark ? 0.30 : 0.88, 0.30)))},
	    // The "fixed" family does not flip with the scheme -- that is the whole
	    // point of it -- so these are the light-scheme tones either way.
	    {QStringLiteral("primary_fixed"), hex(oklabToColor(atTone(seed, 0.86, 0.35)))},
	    {QStringLiteral("primary_fixed_dim"), hex(oklabToColor(atTone(seed, 0.76, 0.50)))},
	    {QStringLiteral("secondary_fixed_dim"), hex(oklabToColor(atTone(seed, 0.76, 0.28)))},
	    {QStringLiteral("tertiary_fixed_dim"), hex(oklabToColor(atTone(tertiaryLab, 0.76, 0.40)))},
	};

	this->mSeed = hex(oklabToColor(seed));
	emit this->rolesChanged();
}

bool Palette::renderTemplate(const QString& templatePath, const QString& outPath) {
	if (this->mRoles.isEmpty()) {
		this->setError(QStringLiteral("no palette to render"));
		return false;
	}

	auto inPath = templatePath;
	if (inPath.startsWith(QStringLiteral("file://"))) inPath = QUrl(inPath).toLocalFile();
	auto dest = outPath;
	if (dest.startsWith(QStringLiteral("file://"))) dest = QUrl(dest).toLocalFile();

	QFile in(inPath);
	if (!in.open(QIODevice::ReadOnly | QIODevice::Text)) {
		this->setError(QStringLiteral("cannot read template %1").arg(inPath));
		return false;
	}
	auto text = QString::fromUtf8(in.readAll());
	in.close();

	// <* for name, value in colors *> ... <* endfor *>
	//
	// Expanded BEFORE the placeholders below, by emitting the body once per
	// role with {{name}} and {{value...}} already substituted. Two of the
	// templates on this machine use it to write out every colour, and without
	// it those files would keep their loop markers and lose every colour in
	// them -- worse than not rendering at all, because the result still looks
	// like a config file.
	static const QRegularExpression loopRe(
	    QStringLiteral("<\\*\\s*for\\s+(\\w+)\\s*,\\s*(\\w+)\\s+in\\s+colors\\s*\\*>(.*?)<\\*\\s*endfor\\s*\\*>"),
	    QRegularExpression::DotMatchesEverythingOption
	);
	while (true) {
		const auto m = loopRe.match(text);
		if (!m.hasMatch()) break;

		const auto nameVar = m.captured(1);
		const auto valueVar = m.captured(2);
		const auto body = m.captured(3);

		QString expanded;
		auto keys = this->mRoles.keys();
		keys.sort(); // stable output, so a diff of the file means a real change
		for (const auto& role: std::as_const(keys)) {
			auto piece = body;
			piece.replace(QStringLiteral("{{") + nameVar + QStringLiteral("}}"), role);
			// value.default.hex / .hex_stripped, the only forms in use
			piece.replace(
			    QStringLiteral("{{") + valueVar + QStringLiteral(".default.hex_stripped}}"),
			    this->mRoles.value(role).toString().mid(1)
			);
			piece.replace(
			    QStringLiteral("{{") + valueVar + QStringLiteral(".default.hex}}"),
			    this->mRoles.value(role).toString()
			);
			expanded += piece;
		}
		text.replace(m.capturedStart(), m.capturedLength(), expanded);
	}

	// {{ colors.<role>.<variant>.<field> [| filter]... }}
	static const QRegularExpression re(QStringLiteral("\\{\\{([^}]*)\\}\\}"));
	QString out;
	qsizetype at = 0;
	auto it = re.globalMatch(text);
	while (it.hasNext()) {
		const auto m = it.next();
		out += text.mid(at, m.capturedStart() - at);
		at = m.capturedEnd();

		const auto expr = m.captured(1).trimmed();
		const auto parts = expr.split(QLatin1Char('|'));
		const auto path = parts.at(0).trimmed().split(QLatin1Char('.'));

		// colors.<role>.<variant>.<field>
		if (path.size() < 2 || path.at(0) != QStringLiteral("colors")) {
			out += m.captured(0); // not ours: leave it visible
			continue;
		}
		const auto role = path.at(1);
		if (!this->mRoles.contains(role)) {
			out += m.captured(0);
			continue;
		}

		auto colour = QColor(this->mRoles.value(role).toString());
		auto stripped = path.size() >= 4 && path.at(3) == QStringLiteral("hex_stripped");
		const auto wantsRgba = path.size() >= 4 && path.at(3) == QStringLiteral("rgba");
		auto alpha = 1.0;

		for (qsizetype i = 1; i < parts.size(); i++) {
			const auto filter = parts.at(i).trimmed();
			if (filter == QStringLiteral("grayscale")) {
				// Luminance-preserving, not a channel average: the template
				// uses this to make a border recede without shifting how
				// light it looks.
				//
				// Back through the transfer function before it becomes a byte.
				// luminance() is LINEAR light, and writing it straight out as
				// an sRGB value crushes everything dark: #1b1a1e came out
				// #030303, so the border and the bar background rendered a
				// near-black that matched nothing in the palette.
				const auto y = qRound(255.0 * linearToSrgb(luminance(colour)));
				colour = QColor(y, y, y);
			} else if (filter.startsWith(QStringLiteral("format:"))) {
				stripped = filter.contains(QStringLiteral("hex_stripped"));
			} else if (filter.startsWith(QStringLiteral("set_alpha:"))) {
				alpha = filter.section(QLatin1Char(':'), 1).trimmed().toDouble();
			}
			// to_color is a no-op here: the value already IS a colour.
		}

		if (wantsRgba) {
			out += QStringLiteral("rgba(%1, %2, %3, %4)")
			           .arg(colour.red())
			           .arg(colour.green())
			           .arg(colour.blue())
			           .arg(alpha, 0, 'g', 3);
			continue;
		}
		const auto h = hex(colour);
		out += stripped ? h.mid(1) : h;
	}
	out += text.mid(at);

	// Written through a temporary and renamed, so a reload that lands mid-write
	// cannot read half a file.
	QFile tmp(dest + QStringLiteral(".new"));
	if (!tmp.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
		this->setError(QStringLiteral("cannot write %1").arg(dest));
		return false;
	}
	tmp.write(out.toUtf8());
	tmp.close();

	QFile::remove(dest);
	if (!tmp.rename(dest)) {
		this->setError(QStringLiteral("cannot replace %1").arg(dest));
		return false;
	}

	this->setError({});
	return true;
}

double Palette::contrastBetween(const QString& a, const QString& b) const {
	const auto ca = QColor(this->mRoles.value(a).toString());
	const auto cb = QColor(this->mRoles.value(b).toString());
	if (!ca.isValid() || !cb.isValid()) return 0;
	return contrastRatio(ca, cb);
}

void Palette::setError(const QString& error) {
	if (this->mError == error) return;
	this->mError = error;
	emit this->errorChanged();
}
