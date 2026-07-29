#include "paths.hpp"

#include <QtCore/QFileInfo>
#include <QtCore/QUrl>

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
