#pragma once

// A palette engine: wallpaper in, themed roles out.
//
// This replaces matugen, and the reason is not that shelling out is ugly -- it
// is that Material You answers a different question than a desktop theme asks.
// Three differences, in order of how much they show:
//
//   OKLab, not HCT. Both are perceptual, but OKLab's lightness is far better
//   behaved at the extremes, which is exactly where a dark theme lives. HCT
//   tone steps bunch up in the shadows, so "surface" and "surface_container"
//   come out nearly indistinguishable on a dark wallpaper and the whole UI
//   flattens.
//
//   Seed chosen by AREA times chroma, not by chroma alone. Material's scorer
//   prefers colourful over prevalent, so a wallpaper that is ninety percent
//   deep teal with one orange sunset pixel themes the desktop orange. That is
//   defensible for a launcher icon and wrong for the surface behind your
//   windows: the theme should look like the picture.
//
//   Foregrounds SOLVED for contrast, not assigned a fixed tone. Material picks
//   a fixed tone for an "on" colour and takes whatever contrast results.
//
//   That is worth being precise about, because measuring it deflated the first
//   version of this claim: on a dark surface matugen's fixed tones land around
//   14:1, which is generous, and an early build here that solved for WCAG AA's
//   4.5 was therefore WORSE than what it replaced. The solver's value is not a
//   better number on a given wallpaper -- it is the same guarantee on EVERY
//   wallpaper, including the pale ones where a fixed tone has no reason to
//   land anywhere in particular.
//
// Role NAMES are Material's on purpose. The compositor's colours.kdl template
// and the settings page both address them by name, and a better engine is not
// a reason to make everyone rewrite their template.

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QVariantMap>

class Palette: public QObject {
	Q_OBJECT

	// role name -> "#rrggbb". Material's names; see the note above.
	Q_PROPERTY(QVariantMap roles READ roles NOTIFY rolesChanged)

	// The colour the palette was built from, as "#rrggbb". Shown by the
	// settings page so a surprising theme can be traced to a plausible cause.
	Q_PROPERTY(QString seed READ seed NOTIFY rolesChanged)

	Q_PROPERTY(QString source READ source WRITE setSource NOTIFY sourceChanged)
	Q_PROPERTY(bool dark READ dark WRITE setDark NOTIFY darkChanged)

	// 0 = the contrast targets below, 1 = noticeably firmer. A slider rather
	// than a boolean because "readable" is not the same number for everyone.
	Q_PROPERTY(double contrast READ contrast WRITE setContrast NOTIFY contrastChanged)

	Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
	// A colour in OKLab. Public because the helpers that do the arithmetic
	// live in the .cpp and would otherwise need a twin of this declared
	// beside them -- which is exactly the mistake that made the first build
	// fail with "invalid initialization of reference".
	struct Lab {
		double l = 0;
		double a = 0;
		double b = 0;
	};

	explicit Palette(QObject* parent = nullptr);
	~Palette() override = default;

	Q_DISABLE_COPY_MOVE(Palette)

	[[nodiscard]] QVariantMap roles() const { return this->mRoles; }
	[[nodiscard]] QString seed() const { return this->mSeed; }
	[[nodiscard]] QString source() const { return this->mSource; }
	[[nodiscard]] bool dark() const { return this->mDark; }
	[[nodiscard]] double contrast() const { return this->mContrast; }
	[[nodiscard]] QString error() const { return this->mError; }

	void setSource(const QString& source);
	void setDark(bool dark);
	void setContrast(double contrast);

	// Rebuild from the current source. Cheap to call: the image is decoded and
	// quantised once per source change, and only the role mapping is redone
	// when dark/contrast move.
	Q_INVOKABLE void regenerate();

	// The measured contrast between two roles, so a UI can show its work
	// rather than asking you to trust it. WCAG ratio, 1..21.
	Q_INVOKABLE double contrastBetween(const QString& a, const QString& b) const;

signals:
	void rolesChanged();
	void sourceChanged();
	void darkChanged();
	void contrastChanged();
	void errorChanged();

private:
	bool quantise();  // image -> mClusters, only when the source changes
	void buildRoles(); // clusters -> roles, whenever anything changes

	void setError(const QString& error);

	struct Cluster {
		Lab centre;
		double weight = 0; // share of the image, 0..1
		double chroma = 0;
	};

	QList<Cluster> mClusters;
	Lab mSeedLab;

	QVariantMap mRoles;
	QString mSeed;
	QString mSource;
	QString mQuantisedSource; // what mClusters was built from
	QString mError;
	double mContrast = 0.0;
	bool mDark = true;
};
