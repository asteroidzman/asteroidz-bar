#pragma once

// The application icon, which QML cannot set.
//
//   WindowIcon.set("file:///run/user/1000/asteroidz-bar-logo-xxxx.svg")
//
// The settings window is an ordinary xdg toplevel, so anything that lists
// windows -- a taskbar, an overview, an alt-tab switcher -- wants an icon for
// it. Wayland has one way to provide it, `xdg-toplevel-icon-v1`, and Qt drives
// that from QGuiApplication/QWindow::setIcon. Neither is reachable from QML:
// QtQuick's Window has no `icon` property and quickshell's window types do not
// add one.
//
// Application-wide rather than per-window on purpose. The shell's bars are layer
// surfaces, not toplevels, so the settings window is the only thing that can
// carry an icon at all -- a per-window API would be a parameter with exactly one
// possible value, and would need the underlying QWindow, which the quickshell
// wrapper does not hand out.
//
// A THEME NAME, not a file. The protocol carries `set_name` and `add_buffer`, and
// asteroidz stores only the name -- so an icon built from a path arrives as
// buffers and is dropped on the floor, which is exactly what happened first:
// `get all-clients` kept reporting `"icon": ""` while everything looked correct
// on this side.
//
// That also settles a question this could not otherwise answer. Logo.qml writes a
// copy of the ship with its flame recoloured to the theme accent, and that copy
// cannot travel down a channel that carries a name -- so the window icon is the
// packaged ship in its own colours, not the accent-tinted one in the bar.

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtQml/qqml.h>

class WindowIcon: public QObject {
	Q_OBJECT

public:
	explicit WindowIcon(QObject* parent = nullptr): QObject(parent) {}

	// An icon-theme name, e.g. "asteroidz-settings".
	Q_INVOKABLE void set(const QString& name);
};
