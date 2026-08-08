#pragma once

// Tray artwork, normalised by optical weight rather than by box.
//
//   image://opticalicon/<box>/<percent-encoded source url>
//
// Every icon in the tray is already fitted into the same box -- measured on a
// live bar, the two tray items came out 15x15 and 17x14 inside an identical
// advance. They still do not read as the same size, because a box is not what
// the eye measures. One of them is a solid filled block covering 97% of its
// canvas and the other is a sparse logo covering 79%, and the solid one looks
// bigger at identical dimensions. That difference is baked into the artwork,
// so no amount of layout arithmetic in QML can reach it: it needs the pixels.
//
// So this measures the ink -- the fraction of the canvas carrying meaningful
// alpha -- and scales the artwork by sqrt(target / coverage), which is the
// factor that equalises AREA rather than extent. That is the correction a
// designer applies by hand when a glyph set mixes solid and open shapes.
//
// SHRINK ONLY. Growing an icon past the box it was given would overflow an
// advance the pill has already reserved, and every module's width is computed
// from that advance -- so a normalisation that could grow would push the bar's
// layout around as tray items come and go. Under-covered artwork is left
// alone; over-covered artwork comes down to meet it.
//
// The wrapped URL may be another provider's (`image://icon/...`, which is what
// quickshell hands back for a tray item whose icon is a theme name or an
// inline SNI pixmap), a file:// URL, or a plain path. Providers are resolved
// through the engine's own registry, which is why this is installed from
// initializeEngine rather than registerTypes -- a QQuickImageProvider that
// cannot reach its engine cannot delegate.

#include <QtCore/QString>
#include <QtGui/QImage>
#include <QtQuick/QQuickImageProvider>

class QQmlEngine;

class OpticalIconProvider: public QQuickImageProvider {
public:
	explicit OpticalIconProvider(QQmlEngine* engine);

	QImage requestImage(const QString& id, QSize* size, const QSize& requestedSize) override;

	// Fraction of the box the ink is allowed to cover before it is scaled
	// down.
	//
	// MEASURED, not guessed. The first value here was 0.75, reasoned from what
	// a well-drawn 16px-grid icon "should" cover -- and it sat above every
	// icon in a real tray, so each one scored "already fine", the provider
	// returned its input unchanged, and a correctly wired feature was
	// indistinguishable from a broken one. A live tray measured 0.721 for a
	// solid block and 0.631 for a sparse logo (ASTEROIDZ_BAR_ICON_DEBUG=1
	// prints these), so the constant belongs just under the sparse end: the
	// dense icon comes down to meet it and the sparse one is left alone,
	// which is the whole intent.
	static constexpr double kTargetCoverage = 0.62;
	// Never shrink past this. A pathological icon -- one solid opaque square,
	// coverage 1.0 -- would otherwise come down by 13%, and beyond that the
	// cure is worse than the complaint.
	static constexpr double kMinScale = 0.80;
	// Alpha at or above this counts as ink. Below it is antialiasing, a soft
	// shadow, or a glow, none of which carry visual weight.
	static constexpr int kInkAlpha = 96;

	// Exposed for the unit test: coverage of an image, 0..1.
	static double coverage(const QImage& img);
	// Exposed for the unit test: the scale coverage implies.
	static double scaleFor(double cov);

private:
	QImage fetch(const QString& url, const QSize& requestedSize);

	QQmlEngine* m_engine;
};
