#pragma once

// The clipboard history, read straight off the compositor.
//
// ext-data-control-v1 is the protocol a clipboard manager is meant to use: it
// hands a privileged client every selection as it is set, without that client
// needing keyboard focus (which is what rules out the ordinary wl_data_device
// route -- a bar never has focus, so it would never see a copy).
//
// No cliphist, no wl-paste subprocess, no polling. Those exist because most
// shells have no way to speak Wayland themselves; this one is already a
// Wayland client with a plugin, so the history is a list in this process and
// the "backend" is a listener rather than a daemon.
//
// Threading and dispatch: everything here runs on the GUI thread and rides
// Qt's own dispatch of the default event queue, exactly as the wallpaper does
// -- see the comment in azbg_backdrop_create(). That means:
//
//   * our own wl_registry on Qt's display is fine and expected,
//   * wl_display_flush() after issuing requests is required,
//   * wl_display_roundtrip() is FORBIDDEN. Blocking on a display somebody else
//     is dispatching deadlocks the shell.
//
// Reading a selection's bytes is the one part that is not a Wayland event: the
// offer is drained through a pipe, so that fd gets a QSocketNotifier and the
// read completes across later event loop turns.

#include <QtCore/QByteArray>
#include <QtCore/QHash>
#include <QtCore/QList>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QVariantList>

class QSocketNotifier;

struct wl_display;
struct wl_registry;
struct wl_seat;
struct ext_data_control_manager_v1;
struct ext_data_control_device_v1;
struct ext_data_control_offer_v1;
struct ext_data_control_source_v1;

class Clipboard: public QObject {
	Q_OBJECT

	// Newest first. Each element is a plain map so QML can bind to it without
	// a custom model type:
	//   id       int, stable for the life of the entry
	//   kind     "text" | "image"
	//   mime     the mime type the data was taken in
	//   preview  one-line text for the list (elided by the UI, not here)
	//   text     the full text, empty for an image
	//   size     bytes
	//   width    image pixels, 0 for text
	//   height   image pixels, 0 for text
	Q_PROPERTY(QVariantList entries READ entries NOTIFY entriesChanged)

	// False when the compositor does not offer ext-data-control-v1 at all, or
	// when we are not on Wayland. The UI says so rather than showing an empty
	// list that looks like "you have never copied anything".
	Q_PROPERTY(bool available READ available NOTIFY availableChanged)
	Q_PROPERTY(QString error READ error NOTIFY errorChanged)

	// How many entries to keep. Oldest are dropped past this.
	Q_PROPERTY(int limit READ limit WRITE setLimit NOTIFY limitChanged)

	// Off by default is wrong for a clipboard manager -- it would silently
	// record nothing until configured -- but a password manager's paste has no
	// business living in a list forever, so this is the switch the UI offers.
	Q_PROPERTY(bool paused READ paused WRITE setPaused NOTIFY pausedChanged)

public:
	explicit Clipboard(QObject* parent = nullptr);
	~Clipboard() override;

	Q_DISABLE_COPY_MOVE(Clipboard)

	[[nodiscard]] QVariantList entries() const { return this->mEntries; }
	[[nodiscard]] bool available() const { return this->mAvailable; }
	[[nodiscard]] QString error() const { return this->mError; }
	[[nodiscard]] int limit() const { return this->mLimit; }
	[[nodiscard]] bool paused() const { return this->mPaused; }

	void setLimit(int limit);
	void setPaused(bool paused);

	// Put an entry back on the clipboard. The compositor will echo it back to
	// us as a new selection; dedupe against the newest entry is what stops
	// that turning into a duplicate (see onSelection).
	Q_INVOKABLE void copy(int id);
	Q_INVOKABLE void remove(int id);
	Q_INVOKABLE void clear();

	// `image://` is not available here (the provider lives in opticalicon),
	// so an image entry hands QML a data: URL of a thumbnail. Built on demand
	// and cached, because a list of forty screenshots should not hold forty
	// full-size PNGs re-encoded as base64.
	Q_INVOKABLE QString thumbnail(int id);

signals:
	void entriesChanged();
	void availableChanged();
	void errorChanged();
	void limitChanged();
	void pausedChanged();

public:
	// Wayland C callbacks. Public only because the listener tables that name
	// them are file-scope constants in the .cpp -- a listener table cannot be
	// befriended, and threading them through a shim would buy nothing. Nothing
	// outside the protocol should call these.
	static void onGlobal(
	    void* data,
	    wl_registry* registry,
	    uint32_t name,
	    const char* interface,
	    uint32_t version
	);
	static void onGlobalRemove(void* data, wl_registry* registry, uint32_t name);

	static void
	onDataOffer(void* data, ext_data_control_device_v1* device, ext_data_control_offer_v1* offer);
	static void
	onSelection(void* data, ext_data_control_device_v1* device, ext_data_control_offer_v1* offer);
	static void onFinished(void* data, ext_data_control_device_v1* device);
	static void onPrimarySelection(
	    void* data,
	    ext_data_control_device_v1* device,
	    ext_data_control_offer_v1* offer
	);

	static void onOfferMime(void* data, ext_data_control_offer_v1* offer, const char* mimeType);

	static void
	onSourceSend(void* data, ext_data_control_source_v1* source, const char* mimeType, int32_t fd);
	static void onSourceCancelled(void* data, ext_data_control_source_v1* source);

private:
	struct Entry {
		int id = 0;
		QString kind;
		QString mime;
		QString preview;
		QString text;
		QByteArray data;
		int width = 0;
		int height = 0;
		QString thumbnail; // built lazily by thumbnail()
	};

	void tryBind();
	void startRead(ext_data_control_offer_v1* offer, const QString& mime);
	void finishRead();
	void addEntry(Entry entry);
	void rebuildEntries();
	void setError(const QString& error);

	wl_display* mDisplay = nullptr;
	wl_registry* mRegistry = nullptr;
	wl_seat* mSeat = nullptr;
	ext_data_control_manager_v1* mManager = nullptr;
	ext_data_control_device_v1* mDevice = nullptr;
	ext_data_control_source_v1* mSource = nullptr;

	// Mime types advertised by each live offer, keyed by the offer itself.
	QHash<ext_data_control_offer_v1*, QStringList> mOfferMimes;

	// The in-flight pipe read, if any. Only one at a time: a second selection
	// arriving mid-read cancels the first, because its data is already stale.
	QSocketNotifier* mNotifier = nullptr;
	int mReadFd = -1;
	QByteArray mPending;
	QString mPendingMime;

	// What we last put on the clipboard ourselves, so the compositor echoing
	// it back does not read as a fresh copy.
	QByteArray mOwnData;
	QString mOwnMime;

	QList<Entry> mList;
	QVariantList mEntries;
	int mNextId = 1;
	int mLimit = 100;
	bool mPaused = false;
	bool mAvailable = false;
	QString mError;
};
