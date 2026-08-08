#include "opticalicon.hpp"

#include <QtCore/QUrl>
#include <QtGui/QImageReader>
#include <QtGui/QPainter>
#include <QtQml/QQmlEngine>

#include <cmath>
#include <cstdlib>

#include <QtCore/QLoggingCategory>

OpticalIconProvider::OpticalIconProvider(QQmlEngine* engine)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_engine(engine) {}

double OpticalIconProvider::coverage(const QImage& img) {
	if (img.isNull()) return 0.0;

	QImage a = img.convertToFormat(QImage::Format_ARGB32);
	const int w = a.width();
	const int h = a.height();
	if (w <= 0 || h <= 0) return 0.0;

	qint64 ink = 0;
	for (int y = 0; y < h; ++y) {
		const QRgb* row = reinterpret_cast<const QRgb*>(a.constScanLine(y));
		for (int x = 0; x < w; ++x) {
			if (qAlpha(row[x]) >= kInkAlpha) ++ink;
		}
	}

	// Against the SQUARE the icon is fitted into, not its own canvas. A wide
	// logo occupies less of the square than its own bitmap suggests, and the
	// square is what sits in the bar.
	const int side = w > h ? w : h;
	return double(ink) / double(qint64(side) * side);
}

double OpticalIconProvider::scaleFor(double cov) {
	if (cov <= 0.0 || cov <= kTargetCoverage) return 1.0;
	const double s = std::sqrt(kTargetCoverage / cov);
	return s < kMinScale ? kMinScale : s;
}

QImage OpticalIconProvider::fetch(const QString& url, const QSize& requestedSize) {
	const QUrl u(url);

	if (u.scheme() == QLatin1String("image")) {
		if (m_engine == nullptr) return {};
		QQmlImageProviderBase* base = m_engine->imageProvider(u.host());
		if (base == nullptr) return {};

		// The inner provider's id is everything after `image://host/`, path
		// and query alike -- quickshell's icon ids carry a query string
		// (?path=…) that must survive intact.
		QString inner = u.path();
		if (inner.startsWith(QLatin1Char('/'))) inner.remove(0, 1);
		if (u.hasQuery()) inner += QLatin1Char('?') + u.query();

		QSize got;
		switch (base->imageType()) {
		case QQmlImageProviderBase::Image:
			return static_cast<QQuickImageProvider*>(base)->requestImage(inner, &got, requestedSize);
		case QQmlImageProviderBase::Pixmap:
			return static_cast<QQuickImageProvider*>(base)
			    ->requestPixmap(inner, &got, requestedSize)
			    .toImage();
		default:
			// ImageResponse (async) and Texture cannot be read synchronously
			// from here. Returning nothing makes the caller fall back to the
			// unnormalised source rather than draw a hole.
			return {};
		}
	}

	const QString path = u.scheme() == QLatin1String("file") ? u.toLocalFile() : url;
	QImageReader reader(path);
	reader.setAutoTransform(true);
	// SVGs have no natural size; ask for the box so the rasterisation is
	// crisp rather than an upscale of whatever default the reader picks.
	if (requestedSize.isValid() && !requestedSize.isEmpty()) {
		reader.setScaledSize(requestedSize);
	}
	return reader.read();
}

QImage OpticalIconProvider::requestImage(
    const QString& id,
    QSize* size,
    const QSize& requestedSize
) {
	// id is `<box>/<percent-encoded url>`. The box is what the bar reserved;
	// the output is always exactly that, with the artwork centred inside it,
	// so a normalised icon still occupies the advance the layout expects.
	const int slash = id.indexOf(QLatin1Char('/'));
	if (slash <= 0) return {};

	bool ok = false;
	const int box = id.left(slash).toInt(&ok);
	if (!ok || box <= 0) return {};

	const QString inner = QUrl::fromPercentEncoding(id.mid(slash + 1).toUtf8());
	if (inner.isEmpty()) return {};

	// Rasterise generously: the artwork is about to be scaled down and then
	// drawn into `box`, and asking for exactly `box` would resample twice.
	const QSize ask(box * 2, box * 2);
	QImage src = fetch(inner, ask);
	if (src.isNull()) return {};

	const double cov = coverage(src);
	const double scale = scaleFor(cov);

	// ASTEROIDZ_BAR_ICON_DEBUG=1 reports what each icon measured. The whole
	// correction turns on one constant, and the only way to choose it is to
	// see where real tray artwork actually lands -- the first value picked was
	// above everything in the tray, so every icon scored "already fine" and
	// the provider was a no-op that looked like a wiring bug.
	if (std::getenv("ASTEROIDZ_BAR_ICON_DEBUG") != nullptr) {
		qWarning(
		    "opticalicon: %s src %dx%d coverage %.3f scale %.3f",
		    qUtf8Printable(inner),
		    src.width(),
		    src.height(),
		    cov,
		    scale
		);
	}

	const QSize out(box, box);
	if (size != nullptr) *size = out;

	QImage dst(out, QImage::Format_ARGB32_Premultiplied);
	dst.fill(Qt::transparent);

	// Fit the source into `box * scale`, preserving aspect, centred. Fitting
	// rather than filling matters for a non-square logo: the tray's advance is
	// a square and a wide icon must not be cropped to it.
	QSize fitted = src.size();
	fitted.scale(QSize(int(std::lround(box * scale)), int(std::lround(box * scale))),
	             Qt::KeepAspectRatio);
	if (fitted.isEmpty()) return {};

	QPainter p(&dst);
	p.setRenderHint(QPainter::SmoothPixmapTransform, true);
	p.drawImage(
	    QRect((box - fitted.width()) / 2, (box - fitted.height()) / 2,
	          fitted.width(), fitted.height()),
	    src
	);
	p.end();

	return dst;
}
