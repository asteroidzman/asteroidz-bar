#pragma once

// Wallpaper thumbnails that look like the wallpaper.
//
//   image://wallthumb/<max edge>/<percent-encoded path>
//
// The picker used to draw its tiles straight from the file (`source: "file://"
// + path`), which is right for every format Qt reads as ordinary sRGB and
// wrong for the two this desktop exists to display properly. Qt's JPEG XL and
// AVIF readers hand back the file's code values without touching them, and for
// a PQ file those code values are not colours -- they are an ST 2084 encoding
// of absolute luminance. Drawn as if they were sRGB, a 1000-nit sunset is a
// flat grey rectangle. Reported as "jxl files are not shown in the wallpaper
// picker": they were shown, they just did not look like pictures.
//
// So an HDR file is decoded through asteroidzbg -- the same decoder that puts
// it on screen, so the tile cannot disagree with the wallpaper about what the
// file contains -- and tone mapped to sRGB for the tile. Everything else goes
// through QImageReader exactly as before.
//
// SYNCHRONOUS, on quickshell's image thread. `asynchronous: true` on the
// delegate's Image is what keeps a 4K decode off the GUI thread; this class
// must not be called from the GUI thread directly.

#include <QtCore/QString>
#include <QtGui/QImage>
#include <QtQuick/QQuickImageProvider>

class HdrThumbProvider: public QQuickImageProvider {
public:
	HdrThumbProvider();

	QImage requestImage(const QString& id, QSize* size, const QSize& requestedSize) override;

	// The whole job for one file, exposed so a test can ask for a thumbnail
	// without an engine: `path` decoded, tone mapped if it is HDR, and fitted
	// into a box of `maxEdge` on its longest side. A null image means the file
	// could not be read at all.
	static QImage thumbnail(const QString& path, int maxEdge);

	// True if the file carries PQ or HLG colorimetry of its own -- i.e. if
	// thumbnail() took the tone-mapping path rather than QImageReader.
	// Exposed for the test, which otherwise cannot tell a correct conversion
	// from a decoder that quietly fell back.
	static bool isHdrFile(const QString& path);
};
