#pragma once

// Which of these files exists?
//
//   Paths.resolve(["/a/logo.svg", "/b/logo.svg"])  ->  "file:///b/logo.svg"
//
// QML has no way to ask, which is why the bar's icon search was implemented by
// pointing an Image at each candidate in turn and moving on when it failed.
// That works, but every miss is a warning -- and the search is *expected* to
// miss, because the whole point of a path list is that later entries are
// fallbacks. A cold start logged a dozen "Cannot open" lines for artwork that
// was found a candidate later and drawn correctly.
//
// So: one stat per candidate, no rejected image loads, no warnings.

#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QStringList>
#include <QtQml/qqml.h>

class Paths: public QObject {
	Q_OBJECT

public:
	explicit Paths(QObject* parent = nullptr): QObject(parent) {}

	// The first candidate that exists, as a file: URL ready for Image.source,
	// or an empty string if none do.
	Q_INVOKABLE [[nodiscard]] QString resolve(const QStringList& candidates);

	// Every filename extension the image decoder can actually read, lower case
	// and without the dot: "png", "jpg", "heic", "jxl"...
	//
	// Asked rather than listed. The wallpaper browser had a hardcoded six, and a
	// hardcoded list of somebody else's capabilities is correct until they gain
	// one: gdk-pixbuf on this machine reads heic, heif, tiff, bmp, gif, svg and
	// qoi as well, so a folder of perfectly displayable wallpapers showed six
	// formats' worth. The same reasoning as the Palette page asking matugen for
	// its role list instead of shipping a table of them.
	//
	// It is the DECODER's list on purpose. asteroidzbg draws through gdk-pixbuf
	// (with its own paths for 10-bit AVIF and JXL), so what gdk-pixbuf can read
	// is exactly what can go on screen -- offering more would put unopenable
	// files in a picker, and offering fewer hides usable ones.
	Q_INVOKABLE [[nodiscard]] QStringList imageExtensions();

private:
	// Icons are asked for repeatedly -- every pill that draws one asks on
	// every config change -- and the answer only changes when a file is
	// added or removed, which is a package install. Caching the miss matters
	// as much as caching the hit: a name with no file anywhere costs a stat
	// per root each time otherwise.
	QHash<QString, QString> mCache;
	// The decoder's format list does not change while the process runs.
	QStringList mExtensions;
};
