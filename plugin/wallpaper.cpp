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
#include "dynwall.h"
#include "log.h"
}

#include <QtCore/QCryptographicHash>
#include <QtCore/QDir>
#include <QtCore/QFileInfo>
#include <QtCore/QStandardPaths>

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

namespace {

// Where in the day we are, as the fraction Apple's table is keyed by: 0.0 is
// local midnight, 0.5 local midday. LOCAL, because a wallpaper that turns dark
// in the evening means the evening where the machine is.
double dayFraction(const QDateTime& when) {
	auto t = when.time();
	return (t.hour() * 3600.0 + t.minute() * 60.0 + t.second()) / 86400.0;
}

// The extracted frame's file. Keyed by the source path, its size and its
// modification time as well as the index, so replacing a wallpaper with a
// different file of the same name does not show the old one forever.
QString framePath(const QString& source, int index) {
	QFileInfo info(source);
	auto key = QStringLiteral("%1|%2|%3|%4")
	               .arg(source)
	               .arg(info.size())
	               .arg(info.lastModified().toMSecsSinceEpoch())
	               .arg(index);
	auto hash = QCryptographicHash::hash(key.toUtf8(), QCryptographicHash::Sha1).toHex();

	auto dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
	if (dir.isEmpty()) dir = QStringLiteral("/tmp");
	return dir + QStringLiteral("/dynamic-wallpaper/") + QString::fromUtf8(hash)
	     + QStringLiteral(".png");
}

} // namespace

Backdrop::Resolved Backdrop::resolve(const QString& path) const {
	Backdrop::Resolved out {path, {}};
	if (path.isEmpty()) return out;

	azbar_dyn_schedule schedule {};
	if (!azbar_dyn_schedule_read(path.toUtf8().constData(), &schedule)) return out;

	auto now = QDateTime::currentDateTime();
	auto fraction = dayFraction(now);

	int index = -1;
	if (schedule.solar && this->mHasLocation) {
		// The real thing: where the sun actually is, here, now. The file's
		// table is altitude and azimuth, so with a location it can be read as
		// written rather than approximated by the light/dark pair.
		double altitude = 0;
		double azimuth = 0;
		azbar_sun_position(
		    this->mLatitude, this->mLongitude, now.toSecsSinceEpoch(), &altitude, &azimuth
		);
		index = azbar_dyn_frame_at_sun(&schedule, altitude, azimuth);
	}
	if (index < 0) index = azbar_dyn_frame_at(&schedule, fraction);
	auto next = azbar_dyn_next_change(&schedule, fraction);
	bool solar = schedule.solar;
	azbar_dyn_schedule_free(&schedule);

	if (index < 0) return out;

	out.file = framePath(path, index);
	if (solar && this->mHasLocation) {
		// The sun moves continuously, so there is no boundary to aim at the way
		// a clock table has one. Re-checked on a fixed tick instead: fifteen
		// minutes moves the sun under four degrees, which no wallpaper's table
		// resolves.
		out.changeAt = now.addSecs(15 * 60);
	} else if (next >= 0.0) {
		// The table is a time of day, so the moment is that far into today --
		// and `next` is allowed to exceed 1.0, which is how "tomorrow" is
		// expressed.
		out.changeAt = QDateTime(now.date(), QTime(0, 0))
		                   .addSecs(static_cast<qint64>(next * 86400.0));
	}
	return out;
}

void Backdrop::scheduleNextFrame() {
	if (this->mFrameTimer == nullptr) {
		this->mFrameTimer = new QTimer(this);
		this->mFrameTimer->setSingleShot(true);
		QObject::connect(this->mFrameTimer, &QTimer::timeout, this, [this]() {
			this->reload();
		});
	}

	QDateTime earliest;
	auto consider = [&](const QString& path) {
		auto r = this->resolve(path);
		if (r.changeAt.isValid() && (!earliest.isValid() || r.changeAt < earliest))
			earliest = r.changeAt;
	};
	consider(this->mSource);
	for (auto it = this->mSources.constBegin(); it != this->mSources.constEnd(); ++it)
		consider(it.value().toString());

	if (!earliest.isValid()) {
		this->mFrameTimer->stop();
		return;
	}

	// A second past the boundary, so a timer that fires a hair early does not
	// resolve to the frame that is still on screen and then sit idle until
	// tomorrow. Floored at a second for the same reason.
	auto ms = QDateTime::currentDateTime().msecsTo(earliest) + 1000;
	this->mFrameTimer->start(static_cast<int>(qMax<qint64>(ms, 1000)));
}

QVariantMap Backdrop::dynamicInfo(const QString& path) const {
	QVariantMap out;
	out[QStringLiteral("dynamic")] = false;
	if (path.isEmpty()) return out;

	azbar_dyn_schedule schedule {};
	if (!azbar_dyn_schedule_read(path.toUtf8().constData(), &schedule)) return out;

	auto fraction = dayFraction(QDateTime::currentDateTime());
	auto next = azbar_dyn_next_change(&schedule, fraction);

	out[QStringLiteral("dynamic")] = true;
	out[QStringLiteral("frames")] = static_cast<int>(schedule.n_frames);
	out[QStringLiteral("images")] = static_cast<int>(schedule.n_images);
	out[QStringLiteral("solar")] = schedule.solar;
	out[QStringLiteral("index")] = azbar_dyn_frame_at(&schedule, fraction);
	if (next >= 0.0)
		out[QStringLiteral("changesIn")] = qRound((next - fraction) * 24.0 * 60.0);
	azbar_dyn_schedule_free(&schedule);
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
	// Which frame of a dynamic wallpaper is due now. Deciding it here is cheap
	// -- libheif parses the container's boxes without decoding anything -- and
	// the expensive half, pulling that frame out, happens on the worker below
	// with the decode it feeds.
	auto frame = this->resolve(path);

	// Copied out for the worker: it must not read members off the GUI thread.
	struct { bool known; double lat; double lon; } loc {
	    this->mHasLocation, this->mLatitude, this->mLongitude
	};

	this->mLoading = true;
	QPointer<Backdrop> self(this);

	QThreadPool::globalInstance()->start([self, path, frame, loc]() {
		auto file = frame.file;
		if (file != path && !QFileInfo::exists(file)) {
			// Extracted once and kept: the frames of a 6016x6016 wallpaper are
			// slow to pull out and there are only ever a handful of them, so
			// the cache turns every later switch -- and every restart of the
			// shell -- into an ordinary file read.
			QDir().mkpath(QFileInfo(file).absolutePath());
			char* err = nullptr;
			azbar_dyn_schedule schedule {};
			int index = -1;
			if (azbar_dyn_schedule_read(path.toUtf8().constData(), &schedule)) {
				// Re-derived rather than carried: between deciding and running
				// here the clock may have crossed a boundary, and drawing the
				// frame that just expired would leave it up until tomorrow.
				auto now = QDateTime::currentDateTime();
				if (schedule.solar && loc.known) {
					double altitude = 0;
					double azimuth = 0;
					azbar_sun_position(loc.lat, loc.lon, now.toSecsSinceEpoch(), &altitude, &azimuth);
					index = azbar_dyn_frame_at_sun(&schedule, altitude, azimuth);
				}
				if (index < 0) index = azbar_dyn_frame_at(&schedule, dayFraction(now));
				azbar_dyn_schedule_free(&schedule);
			}
			if (index < 0
			    || !azbar_dyn_extract(
			        path.toUtf8().constData(), index, file.toUtf8().constData(), &err
			    )) {
				// Fall back to the file itself, which decodes as its primary
				// image -- a still wallpaper rather than none.
				file = path;
			}
			free(err);
		}

		auto* image = azbg_image_load(file.toUtf8().constData());

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

	// Set here rather than when the sources change, because it depends on what
	// was actually drawn and on the clock at the time it was: a plan that took
	// a while to decode can land after the boundary it was aiming at.
	this->scheduleNextFrame();
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
