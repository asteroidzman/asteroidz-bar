#include "paths.hpp"

#include <QtCore/QDir>
#include <QtCore/QFileInfo>
#include <QtCore/QUrl>

#include <cstdlib>

#include "imageformats.h"

QString Paths::resolve(const QStringList& candidates) {
	if (candidates.isEmpty()) return {};

	auto key = candidates.join(QLatin1Char('\n'));
	auto cached = this->mCache.constFind(key);
	if (cached != this->mCache.constEnd()) return *cached;

	QString found;
	for (const auto& candidate: candidates) {
		if (candidate.isEmpty()) continue;

		// Anything already addressed -- a URL, or one of quickshell's
		// image:// providers -- is not ours to check and is passed through.
		if (candidate.contains(QStringLiteral("://"))) {
			found = candidate;
			break;
		}

		if (QFileInfo::exists(candidate)) {
			found = QUrl::fromLocalFile(candidate).toString();
			break;
		}
	}

	this->mCache.insert(key, found);
	return found;
}

QStringList Paths::imageExtensions() {
	if (!this->mExtensions.isEmpty()) return this->mExtensions;

	const char* const* exts = azbar_image_extensions();
	for (const char* const* e = exts; e != nullptr && *e != nullptr; e++)
		this->mExtensions.append(QString::fromUtf8(*e));
	this->mExtensions.sort();
	return this->mExtensions;
}

QString Paths::renderToPng(const QString& source, const QString& dest, int maxEdge) {
	if (source.isEmpty() || dest.isEmpty()) return QStringLiteral("no path given");

	// A file: URL is what everything else in this class deals in, and a caller
	// holding a wallpaper path may well have one.
	auto in = source.startsWith(QStringLiteral("file://"))
	            ? QUrl(source).toLocalFile()
	            : source;

	auto dir = QFileInfo(dest).absolutePath();
	if (!QDir().mkpath(dir))
		return QStringLiteral("could not create %1").arg(dir);

	char* err = nullptr;
	auto ok = azbar_image_to_png(in.toUtf8().constData(), dest.toUtf8().constData(),
	                             maxEdge, &err);
	if (ok) return {};

	auto why = err != nullptr ? QString::fromUtf8(err) : QStringLiteral("failed");
	std::free(err);
	return why;
}
