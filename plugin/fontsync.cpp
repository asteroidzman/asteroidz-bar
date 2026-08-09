#include "fontsync.hpp"

#include <QtCore/QFileInfo>
#include <QtCore/QProcess>
#include <QtCore/QRegularExpression>
#include <QtCore/QSettings>
#include <QtCore/QStandardPaths>
#include <QtGui/QFont>

namespace {

// Pango's font string is "Family [Style words] Size". The size is the trailing
// number; everything before it is the family and optional style, and a family
// can contain spaces ("Noto Sans"), so the split is from the RIGHT.
const QRegularExpression& pangoRe() {
	static const QRegularExpression re(QStringLiteral("^(.*?)\\s+(\\d+(?:\\.\\d+)?)\\s*$"));
	return re;
}

// Style words Pango accepts after the family. They are not part of the family
// name, and leaving them in gives GTK a font called "Ubuntu Bold" -- which does
// not exist, so it silently falls back to the default and the whole exercise
// achieves nothing.
const QStringList& styleWords() {
	static const QStringList words {
	    QStringLiteral("thin"),      QStringLiteral("ultra-light"),
	    QStringLiteral("light"),     QStringLiteral("semi-light"),
	    QStringLiteral("book"),      QStringLiteral("regular"),
	    QStringLiteral("medium"),    QStringLiteral("semi-bold"),
	    QStringLiteral("bold"),      QStringLiteral("ultra-bold"),
	    QStringLiteral("heavy"),     QStringLiteral("black"),
	    QStringLiteral("italic"),    QStringLiteral("oblique"),
	    QStringLiteral("condensed"), QStringLiteral("expanded"),
	};
	return words;
}

} // namespace

FontSync::FontSync(QObject* parent): QObject(parent) {}

QString FontSync::familyOf(const QString& font) const {
	auto head = font.trimmed();
	const auto m = pangoRe().match(head);
	if (m.hasMatch()) head = m.captured(1).trimmed();

	// A trailing comma is not part of the family, and this is not hypothetical:
	// the gtk-3.0/settings.ini found on this machine said "Roboto,  10", so
	// reading a value back and writing it forward would have asked GTK for a
	// family called "Roboto," -- which does not exist, and which GTK answers by
	// silently falling back to its default.
	head.remove(QRegularExpression(QStringLiteral("[,;]+\\s*$")));

	auto parts = head.split(QLatin1Char(' '), Qt::SkipEmptyParts);
	while (parts.size() > 1 && styleWords().contains(parts.last().toLower())) parts.removeLast();
	auto family = parts.join(QLatin1Char(' '));
	while (family.endsWith(QLatin1Char(','))) family.chop(1);
	return family;
}

int FontSync::sizeOf(const QString& font) const {
	const auto m = pangoRe().match(font.trimmed());
	if (!m.hasMatch()) return 0;
	return qRound(m.captured(2).toDouble());
}

bool FontSync::apply(const QString& font) {
	const auto family = this->familyOf(font);
	const auto size = this->sizeOf(font);

	this->mApplied.clear();
	if (family.isEmpty() || size <= 0) {
		this->setError(QStringLiteral("cannot read a font out of \"%1\"").arg(font));
		emit this->appliedChanged();
		return false;
	}

	// GTK's own spelling: family and size, no comma. The file found here said
	// "Roboto,  10" -- which GTK does parse, but writing it back that way would
	// be copying a typo forward.
	const auto pango = QStringLiteral("%1 %2").arg(family).arg(size);

	// XDG_CONFIG_HOME, not $HOME/.config -- and that distinction is the whole
	// reason this function can be run at all without consequences.
	//
	// The first version hard-coded QDir::homePath() + "/.config". Every headless
	// test starts a real bar, and a real bar reaches Component.onCompleted and
	// pushes the font: contrib/process-test.sh declares `theme { font "Ubuntu
	// 16" }`, so running the test suite rewrote the developer's ACTUAL desktop
	// font to the test's value -- GTK, Qt and gsettings, all five targets. It
	// was found the way these are always found, by someone noticing their
	// desktop had changed.
	//
	// The bug was not the missing sandbox in the harness. It was that no
	// sandbox was POSSIBLE: a hard-coded $HOME/.config cannot be pointed
	// anywhere else, so no amount of care in the test scripts could have
	// contained it. Honouring the variable the specification already defines
	// for exactly this is what makes the harness able to set it -- and dconf
	// keeps its user database under the same root, so gsettings is contained by
	// the same one variable.
	const auto cfg = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
	if (cfg.isEmpty()) {
		this->setError(QStringLiteral("no config directory"));
		emit this->appliedChanged();
		return false;
	}

	auto any = false;
	any |= this->writeGtkIni(cfg + QStringLiteral("/gtk-3.0/settings.ini"), pango);
	any |= this->writeGtkIni(cfg + QStringLiteral("/gtk-4.0/settings.ini"), pango);
	any |= this->writeQtConf(cfg + QStringLiteral("/qt6ct/qt6ct.conf"), family, size);
	any |= this->writeQtConf(cfg + QStringLiteral("/qt5ct/qt5ct.conf"), family, size);
	any |= this->writeGSettings(pango);

	this->setError(any ? QString() : QStringLiteral("nothing could be written"));
	emit this->appliedChanged();
	return any;
}

bool FontSync::writeGtkIni(const QString& path, const QString& pango) {
	// Only where the toolkit is already configured. Creating a settings.ini for
	// a GTK version that has none would be this shell deciding the user runs
	// GTK4 apps, and an empty file with one key in it changes how every other
	// setting resolves.
	if (!QFileInfo::exists(path)) return false;

	// A LINE EDIT, not QSettings -- and this is not a style preference, it is
	// the second attempt. GTK's settings.ini is not a Qt INI, and running it
	// through QSettings damaged both files on this machine:
	//
	//   gtk-decoration-layout=icon:minimize,maximize,close came back as
	//   "icon:minimize, maximize, close", because QSettings reads a comma as a
	//   LIST separator and re-joins with ", ".
	//
	//   gtk-4.0 sets gtk-application-prefer-dark-theme TWICE, once as `true`
	//   and once as `1`. QSettings has no concept of a duplicate key, so it
	//   kept one and silently dropped the other.
	//
	// Nothing warned; the files simply came out different. Rewriting one line
	// and copying the rest through verbatim cannot do either.
	QFile f(path);
	if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return false;
	const auto original = QString::fromUtf8(f.readAll());
	f.close();

	auto lines = original.split(QLatin1Char('\n'));
	const auto wanted = QStringLiteral("gtk-font-name=") + pango;

	auto replaced = false;
	for (auto& line: lines) {
		if (!line.trimmed().startsWith(QStringLiteral("gtk-font-name"))) continue;
		if (line == wanted) {
			this->mApplied.append(QStringLiteral("%1: already %2").arg(path, pango));
			return true;
		}
		line = wanted;
		replaced = true;
		break; // only the first; a duplicate below is the user's business
	}

	if (!replaced) {
		// No font line yet: put it inside [Settings] rather than at the end,
		// where it would belong to whatever section came last.
		auto at = lines.indexOf(QStringLiteral("[Settings]"));
		if (at < 0) return false;
		lines.insert(at + 1, wanted);
	}

	QFile out(path + QStringLiteral(".new"));
	if (!out.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) return false;
	out.write(lines.join(QLatin1Char('\n')).toUtf8());
	out.close();

	QFile::remove(path);
	if (!out.rename(path)) return false;

	this->mApplied.append(QStringLiteral("%1: gtk-font-name=%2").arg(path, pango));
	return true;
}

bool FontSync::writeQtConf(const QString& path, const QString& family, int size) {
	if (!QFileInfo::exists(path)) return false;

	// QFont::toString(), not a hand-written field list. qt6ct stores a
	// serialised QFont -- nineteen comma-separated fields whose meaning and
	// COUNT have changed between Qt versions -- and writing those out by hand
	// is a promise to break on the next one. Qt already knows its own format.
	QFont f(family, size);
	const auto serialised = f.toString();

	QSettings conf(path, QSettings::IniFormat);
	if (conf.status() != QSettings::NoError) return false;

	conf.beginGroup(QStringLiteral("Fonts"));
	// `general` only. `fixed` is the monospace font and has no business being
	// set to a UI font -- that is how a terminal ends up proportional.
	conf.setValue(QStringLiteral("general"), serialised);
	conf.endGroup();
	conf.sync();

	this->mApplied.append(QStringLiteral("%1: general=%2 %3").arg(path, family).arg(size));
	return conf.status() == QSettings::NoError;
}

bool FontSync::writeGSettings(const QString& pango) {
	// What a portal answers with.
	//
	// GTK4 under xdg-desktop-portal-gtk asks the portal for its settings rather
	// than reading settings.ini, and the portal reads gsettings -- which is why
	// the desktop found here had settings.ini and gsettings disagreeing, and
	// why writing only the file would have fixed nothing for those apps.
	//
	// Spawned rather than linked: pulling in GIO for one string is a dependency
	// for a call made once per font change.
	if (QStandardPaths::findExecutable(QStringLiteral("gsettings")).isEmpty()) return false;

	QProcess p;
	p.start(
	    QStringLiteral("gsettings"),
	    { QStringLiteral("set"),
	      QStringLiteral("org.gnome.desktop.interface"),
	      QStringLiteral("font-name"),
	      pango }
	);
	if (!p.waitForFinished(3000)) {
		p.kill();
		return false;
	}
	if (p.exitCode() != 0) return false;

	this->mApplied.append(QStringLiteral("gsettings: font-name=%1").arg(pango));
	return true;
}

void FontSync::setError(const QString& error) {
	if (this->mError == error) return;
	this->mError = error;
	emit this->errorChanged();
}
