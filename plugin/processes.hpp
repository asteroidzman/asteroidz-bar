#pragma once

// What is actually using the machine, read out of /proc.
//
// `top` in a popover. The pills already say which BAND you are in through
// their tint; this answers the question that follows, which is always "what
// is doing it".
//
// In C++ rather than QML for one reason: a sample is a readdir of /proc plus
// two small reads per process, several hundred times over, and a CPU
// percentage is a DELTA -- it needs the previous sample of every process kept
// between ticks. Doing that with FileView per process would be several hundred
// QML objects rebuilt on a timer.
//
// It samples only while something is looking. `active` is set by the panel
// while it is open, because a bar that walks /proc every two seconds forever
// to populate a list nobody has opened is exactly the kind of idle cost this
// shell exists to avoid.

#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QTimer>
#include <QtCore/QVariantList>

class Processes: public QObject {
	Q_OBJECT

	// Sorted by the current sortBy, descending, capped at `limit`. Each entry:
	//   pid    int
	//   name   the comm field, which is the executable rather than the whole
	//          command line -- a bar has no room for the latter
	//   cpu    percent of the WHOLE machine, so the column sums toward the
	//          same number the cpu pill is showing
	//   mem    resident bytes
	//   memPct percent of total RAM
	Q_PROPERTY(QVariantList list READ list NOTIFY listChanged)

	// Off by default. The panel turns it on while it is open; nothing else
	// should.
	Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)

	// "cpu" or "mem". The cpu pill opens sorted by cpu, the memory pill by
	// memory, because the pill you pressed is the question you asked.
	Q_PROPERTY(QString sortBy READ sortBy WRITE setSortBy NOTIFY sortByChanged)

	Q_PROPERTY(int limit READ limit WRITE setLimit NOTIFY limitChanged)
	Q_PROPERTY(int intervalMs READ intervalMs WRITE setIntervalMs NOTIFY intervalMsChanged)

	// Machine totals, so the panel's header does not need a second source that
	// could disagree with the rows underneath it.
	Q_PROPERTY(int cpuPct READ cpuPct NOTIFY listChanged)
	Q_PROPERTY(qulonglong memTotal READ memTotal NOTIFY listChanged)
	Q_PROPERTY(qulonglong memUsed READ memUsed NOTIFY listChanged)

public:
	explicit Processes(QObject* parent = nullptr);
	~Processes() override = default;

	Q_DISABLE_COPY_MOVE(Processes)

	[[nodiscard]] QVariantList list() const { return this->mList; }
	[[nodiscard]] bool active() const { return this->mActive; }
	[[nodiscard]] QString sortBy() const { return this->mSortBy; }
	[[nodiscard]] int limit() const { return this->mLimit; }
	[[nodiscard]] int intervalMs() const { return this->mIntervalMs; }
	[[nodiscard]] int cpuPct() const { return this->mCpuPct; }
	[[nodiscard]] qulonglong memTotal() const { return this->mMemTotal; }
	[[nodiscard]] qulonglong memUsed() const { return this->mMemUsed; }

	void setActive(bool active);
	void setSortBy(const QString& sortBy);
	void setLimit(int limit);
	void setIntervalMs(int ms);

	// Take a sample now, without waiting for the timer. Called when the panel
	// opens so it is not blank for a tick.
	Q_INVOKABLE void refresh();

signals:
	void listChanged();
	void activeChanged();
	void sortByChanged();
	void limitChanged();
	void intervalMsChanged();

private:
	struct Sample {
		unsigned long long jiffies = 0; // utime + stime
		bool seen = false;              // survives the sweep that drops dead pids
	};

	void sample();
	void rebuild();

	QTimer mTimer;

	// Per-pid CPU jiffies from the previous sample. A percentage needs two
	// points; the first sample of a process therefore reports 0, which is
	// correct and not worth faking.
	QHash<int, Sample> mPrev;
	unsigned long long mPrevTotal = 0;

	struct Row {
		int pid = 0;
		QString name;
		double cpu = 0;
		qulonglong rss = 0;
	};
	QList<Row> mRows;

	QVariantList mList;
	QString mSortBy = QStringLiteral("cpu");
	int mLimit = 12;
	int mIntervalMs = 2000;
	int mCpuPct = 0;
	qulonglong mMemTotal = 0;
	qulonglong mMemUsed = 0;
	bool mActive = false;
};
