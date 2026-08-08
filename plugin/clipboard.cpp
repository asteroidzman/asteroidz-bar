#include "clipboard.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <QtCore/QBuffer>
#include <QtCore/QSocketNotifier>
#include <QtGui/QGuiApplication>
#include <QtGui/QImage>
#include <QtGui/qguiapplication_platform.h>

#include <wayland-client.h>

#include "ext-data-control-v1-client-protocol.h"

namespace {

// Qt's own connection, handed over as-is. Same accessor the wallpaper uses --
// QNativeInterface::QWaylandApplication is public QtGui API, so this needs no
// private Qt headers and no qtwayland development package.
wl_display* hostDisplay() {
	auto* app = qGuiApp;
	if (app == nullptr) return nullptr;

	auto* wayland = app->nativeInterface<QNativeInterface::QWaylandApplication>();
	if (wayland == nullptr) return nullptr;

	return wayland->display();
}

// Preference order. The first of these an offer advertises is the one taken.
//
// text/plain;charset=utf-8 above bare text/plain because the bare one carries
// no encoding and is latin-1 by the letter of the spec, which mangles anything
// a terminal or a browser actually puts on the clipboard. UTF8_STRING is the
// X11 spelling, still emitted by XWayland clients.
const char* const TEXT_MIMES[] = {
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "STRING",
    "TEXT",
};

const char* const IMAGE_MIMES[] = {
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/bmp",
};

constexpr int PREVIEW_CHARS = 160;
constexpr int THUMBNAIL_EDGE = 96;

// A clipboard entry is held whole in memory, so a 200MB video frame pasted
// from a browser would otherwise sit in the shell forever.
constexpr int MAX_ENTRY_BYTES = 8 * 1024 * 1024;

QString previewOf(const QString& text) {
	QString out = text.simplified();
	if (out.length() > PREVIEW_CHARS) {
		out.truncate(PREVIEW_CHARS);
		out += QStringLiteral("…");
	}
	return out;
}

} // namespace

// ---------------------------------------------------------------- listeners

const wl_registry_listener REGISTRY_LISTENER = {
    .global = &Clipboard::onGlobal,
    .global_remove = &Clipboard::onGlobalRemove,
};

const ext_data_control_device_v1_listener DEVICE_LISTENER = {
    .data_offer = &Clipboard::onDataOffer,
    .selection = &Clipboard::onSelection,
    .finished = &Clipboard::onFinished,
    .primary_selection = &Clipboard::onPrimarySelection,
};

const ext_data_control_offer_v1_listener OFFER_LISTENER = {
    .offer = &Clipboard::onOfferMime,
};

const ext_data_control_source_v1_listener SOURCE_LISTENER = {
    .send = &Clipboard::onSourceSend,
    .cancelled = &Clipboard::onSourceCancelled,
};

// ---------------------------------------------------------------- lifecycle

Clipboard::Clipboard(QObject* parent): QObject(parent) {
	this->mDisplay = hostDisplay();
	if (this->mDisplay == nullptr) {
		this->setError(QStringLiteral("not running on Wayland: the clipboard needs the shell's display"
		));
		return;
	}

	// Our own registry on the host's display, and deliberately no roundtrip --
	// blocking on a display Qt is dispatching is how a client deadlocks
	// itself. The globals arrive as events like everything else, and tryBind()
	// runs again as each one does.
	this->mRegistry = wl_display_get_registry(this->mDisplay);
	wl_registry_add_listener(this->mRegistry, &REGISTRY_LISTENER, this);
	wl_display_flush(this->mDisplay);
}

Clipboard::~Clipboard() {
	this->finishRead();
	if (this->mSource != nullptr) ext_data_control_source_v1_destroy(this->mSource);
	if (this->mDevice != nullptr) ext_data_control_device_v1_destroy(this->mDevice);
	if (this->mManager != nullptr) ext_data_control_manager_v1_destroy(this->mManager);
	if (this->mSeat != nullptr) wl_seat_destroy(this->mSeat);
	if (this->mRegistry != nullptr) wl_registry_destroy(this->mRegistry);
	if (this->mDisplay != nullptr) wl_display_flush(this->mDisplay);
}

// ---------------------------------------------------------------- registry

void Clipboard::onGlobal(
    void* data,
    wl_registry* registry,
    uint32_t name,
    const char* interface,
    uint32_t /*version*/
) {
	auto* self = static_cast<Clipboard*>(data);

	if (qstrcmp(interface, wl_seat_interface.name) == 0) {
		if (self->mSeat != nullptr) return; // first seat wins; this shell is single-seat
		self->mSeat = static_cast<wl_seat*>(wl_registry_bind(registry, name, &wl_seat_interface, 1));
	} else if (qstrcmp(interface, ext_data_control_manager_v1_interface.name) == 0) {
		self->mManager = static_cast<ext_data_control_manager_v1*>(
		    wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1)
		);
	} else {
		return;
	}

	self->tryBind();
}

void Clipboard::onGlobalRemove(void* /*data*/, wl_registry* /*registry*/, uint32_t /*name*/) {}

// The device needs both halves, and they arrive in whatever order the
// compositor advertises them, so this runs after each and does nothing until
// it can do all of it.
void Clipboard::tryBind() {
	if (this->mDevice != nullptr || this->mManager == nullptr || this->mSeat == nullptr) return;

	this->mDevice = ext_data_control_manager_v1_get_data_device(this->mManager, this->mSeat);
	ext_data_control_device_v1_add_listener(this->mDevice, &DEVICE_LISTENER, this);
	wl_display_flush(this->mDisplay);

	this->mAvailable = true;
	emit this->availableChanged();
}

// ---------------------------------------------------------------- offers

void Clipboard::onDataOffer(
    void* data,
    ext_data_control_device_v1* /*device*/,
    ext_data_control_offer_v1* offer
) {
	auto* self = static_cast<Clipboard*>(data);
	// The mime types follow as offer events; the offer is not usable until the
	// selection event names it, so all this does is start collecting.
	self->mOfferMimes.insert(offer, {});
	ext_data_control_offer_v1_add_listener(offer, &OFFER_LISTENER, self);
}

void Clipboard::onOfferMime(void* data, ext_data_control_offer_v1* offer, const char* mimeType) {
	auto* self = static_cast<Clipboard*>(data);
	auto it = self->mOfferMimes.find(offer);
	if (it != self->mOfferMimes.end()) it->append(QString::fromUtf8(mimeType));
}

void Clipboard::onSelection(
    void* data,
    ext_data_control_device_v1* /*device*/,
    ext_data_control_offer_v1* offer
) {
	auto* self = static_cast<Clipboard*>(data);

	// A null offer means the selection was cleared. Nothing to record, and the
	// history deliberately keeps what it had -- "I cleared the clipboard"
	// should not erase the thing you copied before it.
	if (offer == nullptr) return;

	const auto mimes = self->mOfferMimes.value(offer);

	// Pause still drains the offer's bookkeeping above, it just does not read.
	if (self->mPaused) {
		self->mOfferMimes.remove(offer);
		ext_data_control_offer_v1_destroy(offer);
		return;
	}

	QString chosen;
	for (const auto* mime: TEXT_MIMES) {
		if (mimes.contains(QLatin1String(mime))) {
			chosen = QLatin1String(mime);
			break;
		}
	}
	if (chosen.isEmpty()) {
		for (const auto* mime: IMAGE_MIMES) {
			if (mimes.contains(QLatin1String(mime))) {
				chosen = QLatin1String(mime);
				break;
			}
		}
	}

	if (chosen.isEmpty()) {
		// Nothing we can render -- a file list, a custom app format. Dropped
		// rather than stored as opaque bytes nobody could paste usefully.
		self->mOfferMimes.remove(offer);
		ext_data_control_offer_v1_destroy(offer);
		return;
	}

	self->startRead(offer, chosen);
}

void Clipboard::onFinished(void* data, ext_data_control_device_v1* /*device*/) {
	// The compositor has taken the device away (another manager took over, or
	// the seat went). Stop claiming to work.
	auto* self = static_cast<Clipboard*>(data);
	self->mAvailable = false;
	emit self->availableChanged();
}

void Clipboard::onPrimarySelection(
    void* /*data*/,
    ext_data_control_device_v1* /*device*/,
    ext_data_control_offer_v1* offer
) {
	// Middle-click selection is a different clipboard and is deliberately not
	// recorded: it changes on every drag of the mouse over text, so a history
	// of it is noise, and asteroidz can be configured to not offer it at all.
	if (offer != nullptr) ext_data_control_offer_v1_destroy(offer);
}

// ---------------------------------------------------------------- reading

void Clipboard::startRead(ext_data_control_offer_v1* offer, const QString& mime) {
	// A second selection mid-read cancels the first: its data is already the
	// old clipboard, and letting both run would race on mPending.
	this->finishRead();

	int fds[2];
	if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) != 0) {
		this->mOfferMimes.remove(offer);
		ext_data_control_offer_v1_destroy(offer);
		return;
	}

	ext_data_control_offer_v1_receive(offer, mime.toUtf8().constData(), fds[1]);
	// The compositor needs to see the request before it will write, and this
	// is the one place a roundtrip would be tempting. Flush is enough: the
	// write end is ours to close, and the read completes on later event loop
	// turns through the notifier below.
	wl_display_flush(this->mDisplay);
	::close(fds[1]);

	this->mOfferMimes.remove(offer);
	ext_data_control_offer_v1_destroy(offer);

	this->mReadFd = fds[0];
	this->mPendingMime = mime;
	this->mPending.clear();

	this->mNotifier = new QSocketNotifier(this->mReadFd, QSocketNotifier::Read, this);
	QObject::connect(this->mNotifier, &QSocketNotifier::activated, this, [this]() {
		char buf[64 * 1024];
		for (;;) {
			const auto got = ::read(this->mReadFd, buf, sizeof(buf));
			if (got > 0) {
				if (this->mPending.size() + got > MAX_ENTRY_BYTES) {
					// Too big to keep. Drain rather than abandon, or the
					// writer blocks on a full pipe forever.
					this->mPending.clear();
					this->mPendingMime.clear();
					continue;
				}
				this->mPending.append(buf, static_cast<int>(got));
				continue;
			}
			if (got == 0) break;                 // EOF: the writer closed
			if (errno == EINTR) continue;        // retry
			if (errno == EAGAIN || errno == EWOULDBLOCK) return; // more later
			break;                               // a real error
		}

		const auto mime = this->mPendingMime;
		const auto data = this->mPending;
		this->finishRead();
		if (mime.isEmpty() || data.isEmpty()) return;

		// Our own copy() echoed back by the compositor.
		if (mime == this->mOwnMime && data == this->mOwnData) return;

		Entry entry;
		entry.mime = mime;
		entry.data = data;

		if (mime.startsWith(QLatin1String("image/"))) {
			QImage image = QImage::fromData(data);
			if (image.isNull()) return;
			entry.kind = QStringLiteral("image");
			entry.width = image.width();
			entry.height = image.height();
			entry.preview = QStringLiteral("%1 × %2").arg(image.width()).arg(image.height());
		} else {
			const auto text = QString::fromUtf8(data);
			if (text.trimmed().isEmpty()) return;
			entry.kind = QStringLiteral("text");
			entry.text = text;
			entry.preview = previewOf(text);
		}

		this->addEntry(std::move(entry));
	});
}

void Clipboard::finishRead() {
	if (this->mNotifier != nullptr) {
		this->mNotifier->setEnabled(false);
		this->mNotifier->deleteLater();
		this->mNotifier = nullptr;
	}
	if (this->mReadFd >= 0) {
		::close(this->mReadFd);
		this->mReadFd = -1;
	}
	this->mPending.clear();
	this->mPendingMime.clear();
}

// ---------------------------------------------------------------- history

void Clipboard::addEntry(Entry entry) {
	// Copying the same thing twice moves it to the top rather than making a
	// second row of it -- a history full of the same string is what makes a
	// clipboard manager useless.
	for (auto i = 0; i < this->mList.size(); i++) {
		if (this->mList.at(i).data == entry.data && this->mList.at(i).mime == entry.mime) {
			const auto existing = this->mList.takeAt(i);
			this->mList.prepend(existing);
			this->rebuildEntries();
			return;
		}
	}

	entry.id = this->mNextId++;
	this->mList.prepend(std::move(entry));
	while (this->mList.size() > this->mLimit) this->mList.removeLast();
	this->rebuildEntries();
}

void Clipboard::rebuildEntries() {
	QVariantList out;
	out.reserve(this->mList.size());
	for (const auto& entry: this->mList) {
		out.append(QVariantMap {
		    {QStringLiteral("id"), entry.id},
		    {QStringLiteral("kind"), entry.kind},
		    {QStringLiteral("mime"), entry.mime},
		    {QStringLiteral("preview"), entry.preview},
		    {QStringLiteral("text"), entry.text},
		    {QStringLiteral("size"), entry.data.size()},
		    {QStringLiteral("width"), entry.width},
		    {QStringLiteral("height"), entry.height},
		});
	}
	this->mEntries = std::move(out);
	emit this->entriesChanged();
}

// ---------------------------------------------------------------- copy back

void Clipboard::copy(int id) {
	if (this->mManager == nullptr || this->mDevice == nullptr) return;

	for (const auto& entry: this->mList) {
		if (entry.id != id) continue;

		this->mOwnMime = entry.mime;
		this->mOwnData = entry.data;

		// The old source is destroyed only after the new one is set, so the
		// clipboard is never momentarily empty.
		auto* previous = this->mSource;
		this->mSource = ext_data_control_manager_v1_create_data_source(this->mManager);
		ext_data_control_source_v1_add_listener(this->mSource, &SOURCE_LISTENER, this);
		ext_data_control_source_v1_offer(this->mSource, entry.mime.toUtf8().constData());

		// Text is also offered under the plain spelling, because plenty of
		// clients ask only for text/plain and would otherwise see an empty
		// clipboard.
		if (entry.kind == QStringLiteral("text")
		    && entry.mime != QStringLiteral("text/plain")) {
			ext_data_control_source_v1_offer(this->mSource, "text/plain");
		}

		ext_data_control_device_v1_set_selection(this->mDevice, this->mSource);
		wl_display_flush(this->mDisplay);

		if (previous != nullptr) ext_data_control_source_v1_destroy(previous);

		// Move it to the top, so the list reads as most-recently-used.
		this->addEntry(entry);
		return;
	}
}

void Clipboard::onSourceSend(
    void* data,
    ext_data_control_source_v1* source,
    const char* /*mimeType*/,
    int32_t fd
) {
	auto* self = static_cast<Clipboard*>(data);

	// Only the current source answers. A cancelled one whose send is still in
	// flight must close the fd and say nothing, or the receiver waits on a
	// pipe that will never be written or closed.
	if (source != self->mSource) {
		::close(fd);
		return;
	}

	// Blocking write, deliberately. The data is already in memory and bounded
	// by MAX_ENTRY_BYTES, and the alternative -- another notifier and a
	// partial-write state machine -- is a lot of machinery for a paste.
	//
	// SIGPIPE is not a hazard here: QCoreApplication ignores it on Unix, so a
	// receiver that gives up mid-write surfaces as EPIPE rather than killing
	// the shell.
	const auto& payload = self->mOwnData;
	qint64 written = 0;
	while (written < payload.size()) {
		const auto got = ::write(fd, payload.constData() + written, payload.size() - written);
		if (got > 0) {
			written += got;
			continue;
		}
		if (got < 0 && errno == EINTR) continue;
		break;
	}
	::close(fd);
}

void Clipboard::onSourceCancelled(void* data, ext_data_control_source_v1* source) {
	// Somebody else took the clipboard. The source is dead the moment this
	// arrives and must not be used again.
	auto* self = static_cast<Clipboard*>(data);
	if (self->mSource == source) self->mSource = nullptr;
	ext_data_control_source_v1_destroy(source);
}

// ---------------------------------------------------------------- the rest

void Clipboard::remove(int id) {
	for (auto i = 0; i < this->mList.size(); i++) {
		if (this->mList.at(i).id == id) {
			this->mList.removeAt(i);
			this->rebuildEntries();
			return;
		}
	}
}

void Clipboard::clear() {
	if (this->mList.isEmpty()) return;
	this->mList.clear();
	this->rebuildEntries();
}

QString Clipboard::thumbnail(int id) {
	for (auto& entry: this->mList) {
		if (entry.id != id) continue;
		if (entry.kind != QStringLiteral("image")) return {};
		if (!entry.thumbnail.isEmpty()) return entry.thumbnail;

		QImage image = QImage::fromData(entry.data);
		if (image.isNull()) return {};

		image = image.scaled(
		    THUMBNAIL_EDGE,
		    THUMBNAIL_EDGE,
		    Qt::KeepAspectRatio,
		    Qt::SmoothTransformation
		);

		QByteArray png;
		QBuffer buffer(&png);
		buffer.open(QIODevice::WriteOnly);
		if (!image.save(&buffer, "PNG")) return {};

		entry.thumbnail =
		    QStringLiteral("data:image/png;base64,") + QString::fromLatin1(png.toBase64());
		return entry.thumbnail;
	}
	return {};
}

void Clipboard::setLimit(int limit) {
	if (limit < 1) limit = 1;
	if (this->mLimit == limit) return;
	this->mLimit = limit;
	emit this->limitChanged();

	if (this->mList.size() > this->mLimit) {
		while (this->mList.size() > this->mLimit) this->mList.removeLast();
		this->rebuildEntries();
	}
}

void Clipboard::setPaused(bool paused) {
	if (this->mPaused == paused) return;
	this->mPaused = paused;
	emit this->pausedChanged();
}

void Clipboard::setError(const QString& error) {
	if (this->mError == error) return;
	this->mError = error;
	emit this->errorChanged();
}
