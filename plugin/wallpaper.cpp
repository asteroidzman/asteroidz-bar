#include "wallpaper.hpp"

#include <QtCore/QDebug>
#include <QtCore/QMetaObject>
#include <QtCore/QPointer>
#include <QtCore/QThreadPool>
#include <QtGui/QGuiApplication>
#include <QtGui/qguiapplication_platform.h>

extern "C" {
#include "backdrop.h"
#include "log.h"
}

namespace {

// Qt's own connection, handed over as-is.
//
// QNativeInterface::QWaylandApplication is public QtGui API, so this needs no
// private Qt headers and no qtwayland development package -- which matters,
// because a shell that fails to build against the next Qt point release is a
// shell that stops drawing the wallpaper.
wl_display* hostDisplay() {
	auto* app = qGuiApp;
	if (app == nullptr) return nullptr;

	auto* wayland = app->nativeInterface<QNativeInterface::QWaylandApplication>();
	if (wayland == nullptr) return nullptr;

	return wayland->display();
}

} // namespace

Backdrop::Backdrop(QObject* parent): QObject(parent) {
	// asteroidzbg's own logging, which main() used to turn up to LOG_DEBUG.
	// Errors always speak; the rest is opt-in, because a wallpaper that works
	// has nothing to say and this shares the shell's stderr.
	asteroidzbg_log_init(
	    qEnvironmentVariableIsSet("ASTEROIDZ_BAR_BG_DEBUG") ? LOG_DEBUG : LOG_ERROR
	);

	auto* display = hostDisplay();
	if (display == nullptr) {
		this->setError(QStringLiteral(
		    "not running on Wayland: the wallpaper needs the shell's own display"
		));
		return;
	}

	this->mBackdrop = azbg_backdrop_create(
	    display,
	    [](void* user) {
		    // Called from inside a Wayland event handler, which is inside
		    // Qt's dispatch of the display. Doing the work here would
		    // re-enter that dispatch, so it is queued onto the event loop.
		    auto* self = static_cast<Backdrop*>(user);
		    if (self->mFlushQueued) return;
		    self->mFlushQueued = true;
		    QMetaObject::invokeMethod(self, [self]() { self->flush(); }, Qt::QueuedConnection);
	    },
	    this
	);

	if (this->mBackdrop == nullptr) {
		this->setError(QStringLiteral("failed to create the wallpaper surface"));
	}
}

Backdrop::~Backdrop() {
	if (this->mBackdrop != nullptr) azbg_backdrop_destroy(this->mBackdrop);
}

void Backdrop::setSource(const QString& source) {
	if (source == this->mSource) return;
	this->mSource = source;
	emit this->sourceChanged();
	this->reload();
}

void Backdrop::setMode(const QString& mode) {
	if (mode == this->mMode) return;
	this->mMode = mode;
	emit this->modeChanged();
	this->reload();
}

void Backdrop::setError(const QString& error) {
	if (error == this->mError) return;
	this->mError = error;
	if (!error.isEmpty()) qWarning() << "asteroidz-bar: wallpaper:" << error;
	emit this->errorChanged();
}

void Backdrop::reload() {
	if (this->mBackdrop == nullptr || this->mSource.isEmpty()) return;

	// A decode already running: remember what to do next instead of racing
	// it. Only the newest request survives -- the intermediate wallpapers of
	// a fast cycle were never going to be seen anyway.
	if (this->mLoading) {
		this->mPending = this->mSource;
		return;
	}

	this->mLoading = true;
	auto source = this->mSource;
	QPointer<Backdrop> self(this);

	QThreadPool::globalInstance()->start([self, source]() {
		auto* image = azbg_image_load(source.toUtf8().constData());

		QMetaObject::invokeMethod(
		    // The receiver is what keeps this safe: if the shell tore the
		    // Backdrop down while the decode was running, the queued call
		    // never runs -- so the image is freed here rather than leaked to
		    // a handler that will not be reached.
		    qGuiApp,
		    [self, image, source]() {
			    if (self.isNull()) {
				    azbg_image_destroy(image);
				    return;
			    }
			    self->loaded(image, source);
		    },
		    Qt::QueuedConnection
		);
	});
}

void Backdrop::loaded(azbg_image* image, const QString& forSource) {
	this->mLoading = false;

	if (image == nullptr) {
		this->setError(QStringLiteral("cannot decode %1").arg(forSource));
	} else {
		// Drawn and dropped: the buffer the compositor now holds is the only
		// copy that has to stay in memory. Keeping the decoded surface would
		// cost tens of megabytes for the life of the shell to save a decode
		// that happens when a monitor changes, which is ~never.
		bool hdr =
		    azbg_backdrop_present(this->mBackdrop, image, this->mMode.toUtf8().constData());
		azbg_image_destroy(image);

		if (hdr != this->mHdr) {
			this->mHdr = hdr;
			emit this->hdrChanged();
		}

		this->setError(QString());
		if (!this->mReady) {
			this->mReady = true;
			emit this->readyChanged();
		}
	}

	if (!this->mPending.isEmpty()) {
		this->mPending.clear();
		this->reload();
	}
}

void Backdrop::flush() {
	this->mFlushQueued = false;
	if (this->mBackdrop == nullptr) return;

	// An output that appeared or resized wants pixels, and the image is not
	// kept -- so this is where it gets read again.
	if (azbg_backdrop_flush(this->mBackdrop)) this->reload();
}
