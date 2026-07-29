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

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtQml/qqml.h>

struct azbg_backdrop;
struct azbg_image;

class Backdrop: public QObject {
	Q_OBJECT

	// The image to show. A plain filesystem path, not a URL: this goes
	// straight to a decoder, not through Qt's image providers.
	Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
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

	[[nodiscard]] QString mode() const { return this->mMode; }
	void setMode(const QString& mode);

	[[nodiscard]] bool ready() const { return this->mReady; }
	[[nodiscard]] bool hdr() const { return this->mHdr; }
	[[nodiscard]] QString error() const { return this->mError; }

signals:
	void sourceChanged();
	void modeChanged();
	void readyChanged();
	void hdrChanged();
	void errorChanged();

private:
	// Deferred work asked for by a Wayland event (an output appeared,
	// resized, changed scale). Queued rather than run in the event handler,
	// which is still inside Qt's dispatch of the display.
	void flush();
	void loaded(azbg_image* image, const QString& forSource);
	void reload();
	void setError(const QString& error);

	azbg_backdrop* mBackdrop = nullptr;
	QString mSource;
	QString mMode = QStringLiteral("fill");
	QString mError;
	bool mReady = false;
	bool mHdr = false;
	// One decode at a time, newest wins: cycling wallpapers quickly must not
	// pile up worker threads, nor let a slow early decode land on top of a
	// later one.
	bool mLoading = false;
	QString mPending;
	bool mFlushQueued = false;
};
