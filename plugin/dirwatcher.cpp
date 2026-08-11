#include "dirwatcher.hpp"

#include <QtCore/QFileInfo>

DirWatcher::DirWatcher(QObject* parent): QObject(parent) {
	QObject::connect(
	    &this->mWatcher,
	    &QFileSystemWatcher::directoryChanged,
	    this,
	    &DirWatcher::onDirectoryChanged
	);
	// A few seconds, not a poll in disguise: this timer only runs while the
	// watched directory does not exist, which is the removable-media case and
	// nothing else. While the directory is present the watch is an inotify fd
	// and this timer is stopped.
	this->mRearm.setInterval(3000);
	this->mRearm.setSingleShot(true);
	QObject::connect(&this->mRearm, &QTimer::timeout, this, &DirWatcher::rearm);
}

void DirWatcher::setPath(const QString& path) {
	if (path == this->mPath) return;

	if (!this->mPath.isEmpty()) this->mWatcher.removePath(this->mPath);
	this->mPath = path;
	this->mRearm.stop();
	this->rearm();
	emit this->pathChanged();
}

void DirWatcher::rearm() {
	if (this->mPath.isEmpty()) return;

	if (QFileInfo(this->mPath).isDir() && this->mWatcher.addPath(this->mPath)) {
		// The gap between the watch dying and this re-arm is invisible to the
		// consumer unless it is told: anything that happened in between was
		// never reported, so report the re-arm itself as a change and let the
		// rescan see what is actually there now.
		emit this->changed();
	} else {
		this->mRearm.start();
	}
}

void DirWatcher::onDirectoryChanged(const QString& /*path*/) {
	// The event might be the directory's own deletion, in which case the
	// watcher silently dropped it from its list and nothing would ever fire
	// again -- re-arm handles both that and the ordinary case, where the
	// directory still exists and addPath() is a cheap no-op on an already
	// watched path... except it is not a no-op: QFileSystemWatcher refuses
	// duplicates, so the call is made only when the watch was actually lost.
	if (!this->mWatcher.directories().contains(this->mPath)) this->mRearm.start();
	emit this->changed();
}
