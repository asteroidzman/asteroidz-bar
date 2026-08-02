#include "paths.hpp"

#include <QtCore/QFileInfo>
#include <QtCore/QUrl>

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
