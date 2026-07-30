#include "windowicon.hpp"

#include <QtGui/QGuiApplication>
#include <QtGui/QIcon>

void WindowIcon::set(const QString& name) {
	if (name.isEmpty()) return;

	// fromTheme, so the QIcon carries a NAME. Qt's xdg-toplevel-icon integration
	// sends `set_name` when there is one and falls back to shipping pixel buffers
	// when there is not -- and asteroidz records only the name, so a nameless
	// icon is silently discarded.
	QIcon icon = QIcon::fromTheme(name);

	// An empty QIcon would CLEAR the window icon rather than leave it alone, so a
	// missing theme entry is worse than doing nothing.
	if (icon.isNull() || icon.availableSizes().isEmpty()) return;

	QGuiApplication::setWindowIcon(icon);
}
