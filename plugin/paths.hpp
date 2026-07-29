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

private:
	// Icons are asked for repeatedly -- every pill that draws one asks on
	// every config change -- and the answer only changes when a file is
	// added or removed, which is a package install. Caching the miss matters
	// as much as caching the hit: a name with no file anywhere costs a stat
	// per root each time otherwise.
	QHash<QString, QString> mCache;
};
