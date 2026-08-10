// The QML module the shell imports as `Asteroidz.Bar`.
//
// Types for things QML cannot do at all:
//
//   Backdrop   the wallpaper, drawn on the shell's own Wayland connection,
//              in 10-bit HDR when the image is HDR
//   Paths      does this file exist?
//   Clipboard  the selection history, read off ext-data-control-v1 on that
//              same connection -- no cliphist, no wl-paste subprocess
//
// Plus two image providers: `image://opticalicon/...`, which normalises tray
// artwork by ink coverage (opticalicon.hpp), and `image://wallthumb/...`,
// which tone maps an HDR wallpaper down to sRGB for the picker's tiles
// (hdrthumb.hpp).
//
// Registered by hand through QQmlExtensionPlugin rather than declared with
// QML_ELEMENT: the declarative form needs qmltyperegistrar wired into the
// build, which meson's Qt module does not provide, and the hand-written
// version is four lines.

#include <QtQml/QQmlEngine>
#include <QtQml/QQmlExtensionPlugin>
#include <QtQml/qqml.h>

#include "calendar.hpp"
#include "clipboard.hpp"
#include "hdrthumb.hpp"
#include "opticalicon.hpp"
#include "fontsync.hpp"
#include "palette.hpp"
#include "paths.hpp"
#include "processes.hpp"
#include "windowicon.hpp"
#include "wallpaper.hpp"

class AsteroidzBarPlugin: public QQmlExtensionPlugin {
	Q_OBJECT
	Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)

public:
	void registerTypes(const char* uri) override {
		Q_ASSERT(qstrcmp(uri, "Asteroidz.Bar") == 0);

		qmlRegisterType<Backdrop>(uri, 1, 0, "Backdrop");
		qmlRegisterSingletonType<Paths>(
		    uri,
		    1,
		    0,
		    "Paths",
		    [](QQmlEngine* engine, QJSEngine* /*script*/) -> QObject* {
			    // The image provider goes in HERE, not in initializeEngine.
			    // That override is compiled into this plugin and quickshell's
			    // engine never calls it -- the tray logged "Invalid image
			    // provider" for every icon and drew them unnormalised. A
			    // singleton factory runs on first access, which is a thing
			    // that definitely happens, and Paths.opticalIcon() is what
			    // builds the URLs, so the provider cannot be missing by the
			    // time one is used.
			    if (engine != nullptr
			        && engine->imageProvider(QStringLiteral("opticalicon")) == nullptr) {
				    engine->addImageProvider(
				        QStringLiteral("opticalicon"),
				        new OpticalIconProvider(engine)
				    );
			    }
			    // Same reasoning, same moment: Paths.wallpaperThumb() is what
			    // builds the URLs this one answers, so the provider cannot be
			    // missing by the time the picker asks for a tile.
			    if (engine != nullptr
			        && engine->imageProvider(QStringLiteral("wallthumb")) == nullptr) {
				    engine->addImageProvider(QStringLiteral("wallthumb"), new HdrThumbProvider());
			    }
			    return new Paths();
		    }
		);
		// Also a singleton, and for a sharper reason than the clipboard's: a
		// second instance would mean a second OAuth token refresh racing the
		// first, and two writers to the same keyring item.
		qmlRegisterSingletonType<Calendar>(
		    uri,
		    1,
		    0,
		    "Calendar",
		    [](QQmlEngine* engine, QJSEngine* /*script*/) -> QObject* {
			    Q_UNUSED(engine);
			    return new Calendar();
		    }
		);

		// A singleton, not a type: the history is the machine's, not any one
		// bar's, and a second instance would mean a second data-control device
		// racing the first for the same selections.
		qmlRegisterSingletonType<Clipboard>(
		    uri,
		    1,
		    0,
		    "Clipboard",
		    [](QQmlEngine* engine, QJSEngine* /*script*/) -> QObject* {
			    Q_UNUSED(engine);
			    return new Clipboard();
		    }
		);
		qmlRegisterSingletonType<FontSync>(
		    uri,
		    1,
		    0,
		    "FontSync",
		    [](QQmlEngine* engine, QJSEngine* /*script*/) -> QObject* {
			    Q_UNUSED(engine);
			    return new FontSync();
		    }
		);
		qmlRegisterSingletonType<Palette>(
		    uri,
		    1,
		    0,
		    // NOT "Palette": QtQuick already has a Palette (QQuickPalette, the
		    // one behind Item.palette), and registering ours under that name
		    // does not conflict loudly -- it is simply shadowed, so every
		    // ColorEngine.<x> silently reads Qt's palette instead. qmllint
		    // caught it; nothing at runtime would have.
		    "ColorEngine",
		    [](QQmlEngine* engine, QJSEngine* /*script*/) -> QObject* {
			    Q_UNUSED(engine);
			    return new Palette();
		    }
		);
		// A singleton: /proc is the machine's, and two samplers would each see
		// half the other's CPU deltas.
		qmlRegisterSingletonType<Processes>(
		    uri,
		    1,
		    0,
		    "Processes",
		    [](QQmlEngine* engine, QJSEngine* /*script*/) -> QObject* {
			    Q_UNUSED(engine);
			    return new Processes();
		    }
		);
		qmlRegisterSingletonType<WindowIcon>(
		    uri,
		    1,
		    0,
		    "WindowIcon",
		    [](QQmlEngine* engine, QJSEngine* /*script*/) -> QObject* {
			    Q_UNUSED(engine);
			    return new WindowIcon();
		    }
		);
	}

};

#include "plugin.moc"
