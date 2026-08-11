#pragma once

// A directory, watched, with nothing forked.
//
//   DirWatcher { path: "/home/me/Pictures"; onChanged: rescan() }
//
// This replaces the `inotifywait -m` subprocess the wallpaper browser used to
// keep. That process was the shell's one unkillable orphan: it only ever
// noticed the bar was gone by taking SIGPIPE on a write to the dead pipe, and
// a watcher over a quiet folder never writes -- so every crash-restart cycle
// of the shell stranded one inotifywait on ~/Pictures, forever. A
// QFileSystemWatcher is an fd in this process: it cannot outlive the shell,
// costs no fork, and drops the inotify-tools optdepend.
//
// One deliberate narrowing: a directory watch reports create/delete/rename,
// not close_write, so a large file still being copied in is announced by its
// creation rather than its completion. The consumer debounces and rescans the
// directory either way, and a decoder handed a half-written file reports an
// error rather than crashing -- the same position the scan-on-open path was
// already in.

#include <QtCore/QFileSystemWatcher>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QTimer>
#include <QtQml/qqml.h>

class DirWatcher: public QObject {
	Q_OBJECT

	Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)

public:
	explicit DirWatcher(QObject* parent = nullptr);
	Q_DISABLE_COPY_MOVE(DirWatcher)
	~DirWatcher() override = default;

	[[nodiscard]] QString path() const { return this->mPath; }
	void setPath(const QString& path);

signals:
	void pathChanged();
	// Something in the directory changed. Fired per kernel event; the
	// consumer is expected to debounce, exactly as it did for inotifywait's
	// line-per-event output.
	void changed();

private slots:
	void onDirectoryChanged(const QString& path);
	void rearm();

private:
	QFileSystemWatcher mWatcher;
	// The directory itself can be deleted and recreated (a Pictures folder on
	// removable media). The watch dies with the inode, so it is re-armed on a
	// timer until the path exists again.
	QTimer mRearm;
	QString mPath;
};
