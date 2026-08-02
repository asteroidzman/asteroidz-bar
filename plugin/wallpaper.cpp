#include "wallpaper.hpp"

#include <QtCore/QDebug>
#include <QtCore/QMetaObject>
#include <QtCore/QPointer>
#include <QtCore/QHash>
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

void Backdrop::setSources(const QVariantMap& sources) {
	if (sources == this->mSources) return;
	this->mSources = sources;
	emit this->sourcesChanged();
	this->reload();
}

void Backdrop::refreshOutputs() {
	if (this->mBackdrop == nullptr) return;

	QStringList names;
	auto n = azbg_backdrop_output_count(this->mBackdrop);
	names.reserve(static_cast<qsizetype>(n));
	for (size_t i = 0; i < n; i++) {
		const auto* name = azbg_backdrop_output_name(this->mBackdrop, i);
		if (name != nullptr) names.append(QString::fromUtf8(name));
	}
	// Sorted, because the order the compositor happens to announce outputs in
	// is not something a settings page should present as if it meant anything.
	names.sort();
	if (names == this->mOutputs) return;

	this->mOutputs = names;
	emit this->outputsChanged();
}

Backdrop::Plan Backdrop::plan() const {
	// Outputs grouped by the image they want, so a file shared by three
	// monitors is decoded once instead of three times. The empty output list
	// is the default image and means "every output not named in the map" --
	// left as that rather than enumerated, so a monitor that shows up later is
	// already covered.
	Plan out;
	QHash<QString, QStringList> byPath;
	QStringList order;

	for (const auto& name: this->mOutputs) {
		auto path = this->mSources.value(name).toString();
		if (path.isEmpty()) continue; // takes the default below
		if (!byPath.contains(path)) order.append(path);
		byPath[path].append(name);
	}

	// The default goes first, and it goes on EVERY output including the ones
	// that are about to be overwritten. That is one redundant draw per
	// overridden monitor on a cold start, and it buys the thing that matters:
	// an output whose name has not arrived yet still gets a wallpaper, rather
	// than staying black until xdg-output answers.
	if (!this->mSource.isEmpty()) out.append({this->mSource, {}});
	for (const auto& path: order) out.append({path, byPath.value(path)});
	return out;
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
	if (this->mBackdrop == nullptr) return;

	// A plan already running: abandon what is left of it and start over when
	// it lands. Newest wins -- the remaining entries were computed from a
	// configuration that no longer holds, and the intermediate wallpapers of a
	// fast cycle were never going to be seen anyway.
	if (this->mLoading) {
		this->mRestart = true;
		return;
	}

	this->mQueue = this->plan();
	if (this->mQueue.isEmpty()) return;

	this->mPlanHdr = false;
	this->mPlanDrew = false;
	this->startNext();
}

void Backdrop::startNext() {
	if (this->mQueue.isEmpty()) {
		this->mLoading = false;
		return;
	}

	auto path = this->mQueue.first().first;
	this->mLoading = true;
	QPointer<Backdrop> self(this);

	QThreadPool::globalInstance()->start([self, path]() {
		auto* image = azbg_image_load(path.toUtf8().constData());

		QMetaObject::invokeMethod(
		    // The receiver is what keeps this safe: if the shell tore the
		    // Backdrop down while the decode was running, the queued call
		    // never runs -- so the image is freed here rather than leaked to
		    // a handler that will not be reached.
		    qGuiApp,
		    [self, image, path]() {
			    if (self.isNull()) {
				    azbg_image_destroy(image);
				    return;
			    }
			    self->loaded(image, path);
		    },
		    Qt::QueuedConnection
		);
	});
}

void Backdrop::loaded(azbg_image* image, const QString& forPath) {
	this->mLoading = false;

	// The entry this decode was for. Taken now rather than at the end, so
	// every path out of here has already consumed it.
	QStringList outputs;
	if (!this->mQueue.isEmpty()) {
		outputs = this->mQueue.first().second;
		this->mQueue.removeFirst();
	}

	if (image == nullptr) {
		// Named, because with several images in play "cannot decode" alone
		// does not say which monitor is the black one.
		this->setError(
		    outputs.isEmpty()
		        ? QStringLiteral("cannot decode %1").arg(forPath)
		        : QStringLiteral("cannot decode %1 (for %2)")
		              .arg(forPath, outputs.join(QStringLiteral(", ")))
		);
	} else {
		// Drawn and dropped: the buffer the compositor now holds is the only
		// copy that has to stay in memory. Keeping the decoded surface would
		// cost tens of megabytes for the life of the shell to save a decode
		// that happens when a monitor changes, which is ~never.
		auto mode = this->mMode.toUtf8();
		if (outputs.isEmpty()) {
			if (azbg_backdrop_present(this->mBackdrop, image, mode.constData()))
				this->mPlanHdr = true;
			this->mPlanDrew = true;
		} else {
			for (const auto& name: outputs) {
				if (azbg_backdrop_present_output(
				        this->mBackdrop, name.toUtf8().constData(), image, mode.constData()
				    ))
					this->mPlanHdr = true;
				this->mPlanDrew = true;
			}
		}
		azbg_image_destroy(image);
		this->setError(QString());
	}

	// A change arrived mid-plan: what is left was computed from the old
	// configuration, so it is dropped rather than drawn.
	if (this->mRestart) {
		this->mRestart = false;
		this->mQueue.clear();
		this->reload();
		return;
	}

	if (!this->mQueue.isEmpty()) {
		this->startNext();
		return;
	}

	// The plan is done, so `hdr` can be answered: it is a statement about what
	// is on screen as a whole, and mid-plan there is no such whole. True if
	// any monitor got HDR pixels -- on a mixed pair, "no" would be wrong about
	// one of them and "yes" is at least true of one.
	if (this->mPlanHdr != this->mHdr) {
		this->mHdr = this->mPlanHdr;
		emit this->hdrChanged();
	}
	if (this->mPlanDrew && !this->mReady) {
		this->mReady = true;
		emit this->readyChanged();
	}
}

void Backdrop::flush() {
	this->mFlushQueued = false;
	if (this->mBackdrop == nullptr) return;

	// An output may have arrived, gone, or only just told us its name -- and
	// the name is what a per-output wallpaper is addressed by.
	this->refreshOutputs();

	// An output that appeared or resized wants pixels, and the image is not
	// kept -- so this is where it gets read again.
	if (azbg_backdrop_flush(this->mBackdrop)) this->reload();
}
