#include "hdrthumb.hpp"

#include "tonemap.h"

#include <QtCore/QUrl>
#include <QtGui/QImageReader>

extern "C" {
#include "hdr-image.h"
}

#include <cstdint>
#include <vector>

namespace {

// The decoded HDR surface, reduced to a working buffer of linear BT.709 floats
// no larger than it needs to be.
struct LinearImage {
	int width = 0;
	int height = 0;
	std::vector<float> rgb; // width * height * 3
	double peak = 0.0;      // brightest channel, relative to reference white
};

// One 10-bit RGB30 word -> linear BT.709, relative to reference white.
//
// Both transfer functions end in the same place, which is why this returns
// through the same three references: absolute luminance divided by 203.
void decodePixel(
    uint32_t word,
    enum hdr_transfer tf,
    enum hdr_primaries prim,
    double& r,
    double& g,
    double& b
) {
	constexpr double kMax10 = 1023.0;
	const double er = double((word >> 20) & 0x3FF) / kMax10;
	const double eg = double((word >> 10) & 0x3FF) / kMax10;
	const double eb = double(word & 0x3FF) / kMax10;

	if (tf == HDR_TF_HLG) {
		// The nominal peak an HLG grade is authored for. HLG carries no
		// absolute luminance -- that is the format's whole design -- so a
		// number has to be chosen, and 1000 is the one BT.2100's own system
		// gamma is specified at.
		constexpr double kHlgPeak = 1000.0;
		const double sr = tonemap::hlgInverseOetf(er);
		const double sg = tonemap::hlgInverseOetf(eg);
		const double sb = tonemap::hlgInverseOetf(eb);
		const double scale = tonemap::hlgOotfScale(sr, sg, sb, kHlgPeak);
		r = sr * scale;
		g = sg * scale;
		b = sb * scale;
	} else {
		r = tonemap::pqEotfNits(er);
		g = tonemap::pqEotfNits(eg);
		b = tonemap::pqEotfNits(eb);
	}

	r /= tonemap::kReferenceWhite;
	g /= tonemap::kReferenceWhite;
	b /= tonemap::kReferenceWhite;

	if (prim == HDR_PRIM_BT2020) tonemap::bt2020ToSrgb(r, g, b);

	// Clamped here, before anything measures a peak or rolls one off. A
	// BT.2020 colour outside BT.709 comes out of the matrix negative, and a
	// negative channel neither has a meaningful roll-off nor belongs in the
	// image's peak.
	if (r < 0.0) r = 0.0;
	if (g < 0.0) g = 0.0;
	if (b < 0.0) b = 0.0;
}

// Decode and downscale in one pass, averaging in LINEAR light.
//
// The order matters and it is the reason this is not a QImage::scaled() after
// the fact. Averaging PQ code values is averaging an encoding of luminance:
// a pixel at 4000 nits beside a pixel at 4 nits averages to something near
// their encoded midpoint, roughly 500 nits, when the light landing on that
// part of the sensor was 2002. Specular highlights in an HDR photo are exactly
// that case, and a thumbnail made the other way loses them.
LinearImage decodeLinear(const hdr_image* img, int maxEdge) {
	LinearImage out;

	cairo_surface_flush(img->surface);
	const int w = cairo_image_surface_get_width(img->surface);
	const int h = cairo_image_surface_get_height(img->surface);
	const auto* data = reinterpret_cast<const uint32_t*>(cairo_image_surface_get_data(img->surface));
	const int stride = cairo_image_surface_get_stride(img->surface) / 4;
	if (w <= 0 || h <= 0 || data == nullptr || maxEdge <= 0) return out;

	// Twice the box: the result is resampled once more on the way into the
	// tile, and handing that step a bit more than it needs is what keeps the
	// downscale from looking like a nearest-neighbour one.
	const int target = maxEdge * 2;
	int step = (w > h ? w : h) / target;
	if (step < 1) step = 1;

	out.width = w / step;
	out.height = h / step;
	if (out.width < 1) out.width = 1;
	if (out.height < 1) out.height = 1;
	out.rgb.assign(size_t(out.width) * size_t(out.height) * 3, 0.0F);

	for (int y = 0; y < out.height; ++y) {
		for (int x = 0; x < out.width; ++x) {
			double ar = 0.0;
			double ag = 0.0;
			double ab = 0.0;
			int n = 0;
			for (int sy = y * step; sy < (y + 1) * step && sy < h; ++sy) {
				const uint32_t* row = data + size_t(sy) * size_t(stride);
				for (int sx = x * step; sx < (x + 1) * step && sx < w; ++sx) {
					double r = 0.0;
					double g = 0.0;
					double b = 0.0;
					decodePixel(row[sx], img->tf, img->primaries, r, g, b);
					ar += r;
					ag += g;
					ab += b;
					++n;
				}
			}
			if (n == 0) continue;
			ar /= n;
			ag /= n;
			ab /= n;

			const size_t i = (size_t(y) * size_t(out.width) + size_t(x)) * 3;
			out.rgb[i] = float(ar);
			out.rgb[i + 1] = float(ag);
			out.rgb[i + 2] = float(ab);

			const double m = ar > ag ? (ar > ab ? ar : ab) : (ag > ab ? ag : ab);
			if (m > out.peak) out.peak = m;
		}
	}

	return out;
}

// The tone-mapped result, at the working buffer's size.
//
// The peak is the DOWNSCALED image's, deliberately. A single stuck sensor
// pixel at 10000 nits in a 4K file would otherwise set the roll-off for the
// whole picture and darken everything else to compensate for one pixel nobody
// can see; averaging first is what stops one pixel from having that vote.
QImage encodeSrgb(const LinearImage& lin) {
	if (lin.width <= 0 || lin.height <= 0) return {};

	QImage out(lin.width, lin.height, QImage::Format_RGB888);
	if (out.isNull()) return {};

	const double lw = lin.peak;
	for (int y = 0; y < lin.height; ++y) {
		auto* row = out.scanLine(y);
		for (int x = 0; x < lin.width; ++x) {
			const size_t i = (size_t(y) * size_t(lin.width) + size_t(x)) * 3;
			for (int c = 0; c < 3; ++c) {
				const double v =
				    tonemap::srgbOetf(tonemap::reinhard(double(lin.rgb[i + size_t(c)]), lw));
				row[x * 3 + c] = uchar(v * 255.0 + 0.5);
			}
		}
	}
	return out;
}

QImage fitTo(const QImage& img, int maxEdge) {
	if (img.isNull() || maxEdge <= 0) return img;
	if (img.width() <= maxEdge && img.height() <= maxEdge) return img;
	return img.scaled(
	    maxEdge,
	    maxEdge,
	    Qt::KeepAspectRatio,
	    Qt::SmoothTransformation
	);
}

} // namespace

HdrThumbProvider::HdrThumbProvider(): QQuickImageProvider(QQuickImageProvider::Image) {}

bool HdrThumbProvider::isHdrFile(const QString& path) {
	hdr_image* img = hdr_image_load(path.toUtf8().constData());
	if (img == nullptr) return false;
	const bool hdr = img->is_hdr;
	hdr_image_destroy(img);
	return hdr;
}

QImage HdrThumbProvider::thumbnail(const QString& path, int maxEdge) {
	if (path.isEmpty() || maxEdge <= 0) return {};

	// The HDR decoder first, and it answers NULL for everything that is not an
	// AVIF or JPEG XL carrying PQ/HLG of its own -- including an SDR file in
	// either of those formats. So this is not "try the expensive one first":
	// it is the only test for whether the expensive one is needed.
	if (hdr_image* img = hdr_image_load(path.toUtf8().constData())) {
		QImage mapped;
		if (img->is_hdr) mapped = fitTo(encodeSrgb(decodeLinear(img, maxEdge)), maxEdge);
		hdr_image_destroy(img);
		if (!mapped.isNull()) return mapped;
		// An HDR file that decoded but would not convert falls through rather
		// than returning nothing: a washed-out tile is worse than a correct
		// one and better than a hole.
	}

	QImageReader reader(path);
	reader.setAutoTransform(true);
	const QSize natural = reader.size();
	if (natural.isValid() && !natural.isEmpty()
	    && (natural.width() > maxEdge || natural.height() > maxEdge)) {
		// Scaled by the READER, which for most formats decodes at the reduced
		// size rather than decoding 4K and throwing it away.
		QSize want = natural;
		want.scale(maxEdge, maxEdge, Qt::KeepAspectRatio);
		reader.setScaledSize(want);
	}
	return reader.read();
}

QImage HdrThumbProvider::requestImage(
    const QString& id,
    QSize* size,
    const QSize& requestedSize
) {
	Q_UNUSED(requestedSize);

	// id is `<max edge>/<percent-encoded path>`. The box is in the URL rather
	// than taken from requestedSize because the URL is what Qt caches on: two
	// tiles asking for the same file at the same size must be one decode, and
	// a sourceSize the delegate happens to have at layout time is not a stable
	// key for that.
	const int slash = id.indexOf(QLatin1Char('/'));
	if (slash <= 0) return {};

	bool ok = false;
	const int box = id.left(slash).toInt(&ok);
	if (!ok || box <= 0) return {};

	QString path = QUrl::fromPercentEncoding(id.mid(slash + 1).toUtf8());
	if (path.startsWith(QLatin1String("file://"))) path = QUrl(path).toLocalFile();
	if (path.isEmpty()) return {};

	const QImage img = thumbnail(path, box);
	if (size != nullptr) *size = img.size();
	return img;
}
