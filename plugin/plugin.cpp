// The QML module the shell imports as `Asteroidz.Bar`.
//
// Two types, both for things QML cannot do at all:
//
//   Backdrop   the wallpaper, drawn on the shell's own Wayland connection,
//              in 10-bit HDR when the image is HDR
//   Paths      does this file exist?
//
// Plus one image provider, `image://opticalicon/...`, which normalises tray
// artwork by ink coverage -- see opticalicon.hpp.
//
// Registered by hand through QQmlExtensionPlugin rather than declared with
// QML_ELEMENT: the declarative form needs qmltyperegistrar wired into the
// build, which meson's Qt module does not provide, and the hand-written
// version is four lines.

#include <QtQml/QQmlEngine>
#include <QtQml/QQmlExtensionPlugin>
#include <QtQml/qqml.h>

#include "opticalicon.hpp"
#include "paths.hpp"
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
			    return new Paths();
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
