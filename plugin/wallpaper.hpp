#pragma once

// The wallpaper, as a QML object.
//
//   Backdrop { source: "/home/me/Pictures/x.avif"; mode: "fill" }
//
// Setting `source` puts that image up on every output, in this process, over
// Qt's own Wayland connection -- there is no wallpaper program any more. What
// draws it is asteroidzbg, linked in (subprojects/asteroidzbg), which is why
// an HDR10 AVIF still arrives as 10-bit PQ pixels tagged through
// wp_color_manager_v1 rather than as a washed-out sRGB approximation. QML
// cannot express any of that, so none of it was rewritten in QML.
//
// Decoding happens on a worker thread. A 4K AVIF takes long enough that doing
// it on the GUI thread visibly stalls the bar -- a cost the separate process
// did not have, and not one worth inheriting to save a thread.
//
// The header is .hpp and the C library's is .h on purpose: a quoted include
// resolves against the including file's own directory first, so two headers
// both called backdrop.h would have this one silently including itself.

#include <QtCore/QList>
#include <QtCore/QObject>
#include <QtCore/QPair>
#include <QtCore/QString>
#include <QtCore/QStringList>
#include <QtCore/QVariantMap>
#include <QtQml/qqml.h>

struct azbg_backdrop;
struct azbg_image;

class Backdrop: public QObject {
	Q_OBJECT

	// The image to show. A plain filesystem path, not a URL: this goes
	// straight to a decoder, not through Qt's image providers.
	Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
	// Per-output overrides: { "DP-1": "/home/me/Pictures/left.avif" }.
	//
	// An output named here gets that image; every other output gets `source`.
	// Two properties rather than a map with an entry per output, because
	// "every monitor unless it says otherwise" is the ordinary case and has to
	// survive a monitor being added, unplugged or renamed -- a map alone would
	// leave a monitor nobody had listed with no wallpaper at all.
	Q_PROPERTY(QVariantMap sources READ sources WRITE setSources NOTIFY sourcesChanged)
	// The outputs this shell can see, by name, as they become known. A
	// settings page cannot offer "the wallpaper on DP-1" without knowing DP-1
	// is there.
	Q_PROPERTY(QStringList outputs READ outputs NOTIFY outputsChanged)
	// stretch, fill, fit, center or tile -- asteroidzbg's -m.
	Q_PROPERTY(QString mode READ mode WRITE setMode NOTIFY modeChanged)
	// True once an image has actually been drawn: the wallpaper is up.
	Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
	// Whether it went up as HDR: 10-bit pixels tagged with their real
	// transfer function. False for an ordinary image AND for an HDR one on a
	// compositor that cannot be told about it -- the outcome is the same 8-bit
	// sRGB either way, and this says which one is on screen rather than which
	// one the file claims to be.
	Q_PROPERTY(bool hdr READ hdr NOTIFY hdrChanged)
	// Empty unless the last attempt failed, in which case it says why -- a
	// missing or undecodable file should be visible, not silently black.
	Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
	explicit Backdrop(QObject* parent = nullptr);
	~Backdrop() override;
	Q_DISABLE_COPY_MOVE(Backdrop)

	[[nodiscard]] QString source() const { return this->mSource; }
	void setSource(const QString& source);

	[[nodiscard]] QVariantMap sources() const { return this->mSources; }
	void setSources(const QVariantMap& sources);

	[[nodiscard]] QStringList outputs() const { return this->mOutputs; }

	[[nodiscard]] QString mode() const { return this->mMode; }
	void setMode(const QString& mode);

	[[nodiscard]] bool ready() const { return this->mReady; }
	[[nodiscard]] bool hdr() const { return this->mHdr; }
	[[nodiscard]] QString error() const { return this->mError; }

signals:
	void sourceChanged();
	void sourcesChanged();
	void outputsChanged();
	void modeChanged();
	void readyChanged();
	void hdrChanged();
	void errorChanged();

private:
	// Deferred work asked for by a Wayland event (an output appeared,
	// resized, changed scale). Queued rather than run in the event handler,
	// which is still inside Qt's dispatch of the display.
	void flush();
	void loaded(azbg_image* image, const QString& forPath);
	void reload();
	void setError(const QString& error);

	// One decode per DISTINCT image, drawn onto every output that wants it:
	// { "/path/a.avif": ["DP-1"], "/path/b.png": [] } where the empty list
	// means "every output not named anywhere else".
	using Plan = QList<QPair<QString, QStringList>>;
	[[nodiscard]] Plan plan() const;
	void startNext();
	// Whether the outputs the backdrop knows about still match mOutputs.
	void refreshOutputs();

	azbg_backdrop* mBackdrop = nullptr;
	QString mSource;
	QVariantMap mSources;
	QStringList mOutputs;
	QString mMode = QStringLiteral("fill");
	QString mError;
	bool mReady = false;
	bool mHdr = false;
	// One decode at a time, newest wins: cycling wallpapers quickly must not
	// pile up worker threads, nor let a slow early decode land on top of a
	// later one.
	//
	// With per-output images there can be several to draw for one request, so
	// the plan is a queue worked through one decode at a time rather than a
	// single pending path. `mRestart` is the newest-wins flag: a change that
	// arrives mid-plan abandons the rest of it and starts over, because the
	// remaining entries were computed from the old configuration.
	bool mLoading = false;
	Plan mQueue;
	bool mRestart = false;
	bool mFlushQueued = false;
	// Set while a plan is running, folded into mHdr when it finishes: "the
	// wallpaper is HDR" is only meaningful as a statement about all of them.
	bool mPlanHdr = false;
	bool mPlanDrew = false;
};
