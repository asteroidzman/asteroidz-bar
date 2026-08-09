#pragma once

// One font setting, pushed to every toolkit that wants its own.
//
// `theme { font "Ubuntu 13" }` in the compositor's config is the only place a
// font should be chosen, but nothing else on the desktop reads it. GTK reads
// settings.ini, GTK under a portal reads gsettings, and Qt reads qt6ct's own
// file -- in three different formats, none of which is the compositor's.
//
// The state this was written to fix is the one it found: gtk-3.0/settings.ini
// said "Roboto, 10", qt6ct said "Roboto,10,...", gsettings said "Noto Sans 10",
// and the compositor said "Ubuntu 13". Four sources, four answers, and no way
// to tell which an application would obey.
//
// Files are edited in place through QSettings rather than rewritten: these
// hold the user's other choices -- icon theme, cursor size, style -- and a
// generated file that replaced them would be a font sync that quietly reset
// the desktop.

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QStringList>

class FontSync: public QObject {
	Q_OBJECT

	// What the last apply() actually wrote, one line per target, for a UI or a
	// log to show. Empty before the first run.
	Q_PROPERTY(QStringList applied READ applied NOTIFY appliedChanged)
	Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
	explicit FontSync(QObject* parent = nullptr);
	~FontSync() override = default;

	Q_DISABLE_COPY_MOVE(FontSync)

	[[nodiscard]] QStringList applied() const { return this->mApplied; }
	[[nodiscard]] QString error() const { return this->mError; }

	// `font` is the compositor's own spelling: "Family Size", optionally with
	// a weight word, e.g. "Ubuntu 13" or "Ubuntu Bold 13" -- Pango's format,
	// because that is what asteroidz hands Pango.
	//
	// Returns false if nothing could be written at all. A single target failing
	// is reported in `applied` and does not fail the call: a missing qt6ct is
	// not a reason to leave GTK on the wrong font.
	Q_INVOKABLE bool apply(const QString& font);

	// Split "Ubuntu Bold 13" into family and size, exposed because the bar
	// needs the same split for its own text and two parsers would disagree
	// eventually.
	Q_INVOKABLE QString familyOf(const QString& font) const;
	Q_INVOKABLE int sizeOf(const QString& font) const;

signals:
	void appliedChanged();
	void errorChanged();

private:
	bool writeGtkIni(const QString& path, const QString& pango);
	bool writeQtConf(const QString& path, const QString& family, int size);
	bool writeGSettings(const QString& pango);

	void setError(const QString& error);

	QStringList mApplied;
	QString mError;
};
