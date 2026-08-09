#include "processes.hpp"

#include <unistd.h>

#include <QtCore/QByteArray>
#include <QtCore/QDir>
#include <QtCore/QFile>

namespace {

// /proc/stat's first line: the machine's jiffies since boot, summed across
// every field. Idle is included on purpose -- the denominator is elapsed
// capacity, not elapsed work.
unsigned long long totalJiffies() {
	QFile f(QStringLiteral("/proc/stat"));
	if (!f.open(QIODevice::ReadOnly)) return 0;

	const auto line = f.readLine();
	const auto parts = line.simplified().split(' ');
	unsigned long long total = 0;
	for (int i = 1; i < parts.size(); i++) total += parts.at(i).toULongLong();
	return total;
}

// /proc/meminfo, in bytes. MemAvailable rather than MemFree: free excludes
// cache the kernel would hand back on demand, which is why "free" alarms
// people who have plenty.
void memoryTotals(qulonglong* total, qulonglong* used) {
	QFile f(QStringLiteral("/proc/meminfo"));
	if (!f.open(QIODevice::ReadOnly)) return;

	// readAll() and split, NOT a `while (!f.atEnd())` loop over readLine().
	//
	// procfs files report a size of 0, and QFile::atEnd() answers from size --
	// so the loop condition is false on the very first test and the body never
	// runs. It fails silently: no error, no exception, just a total of zero
	// bytes read and both figures left at 0, which is how this shipped its
	// first sample reporting a machine with no memory. totalJiffies() above
	// escapes it only because a single readLine() asks no such question.
	qulonglong kbTotal = 0;
	qulonglong kbAvail = 0;
	const auto lines = f.readAll().split('\n');
	for (const auto& line: lines) {
		const auto parts = line.simplified().split(' ');
		if (parts.size() < 2) continue;
		if (parts.at(0) == "MemTotal:") kbTotal = parts.at(1).toULongLong();
		else if (parts.at(0) == "MemAvailable:") kbAvail = parts.at(1).toULongLong();
	}
	*total = kbTotal * 1024ULL;
	*used = (kbTotal > kbAvail ? kbTotal - kbAvail : 0) * 1024ULL;
}

} // namespace

Processes::Processes(QObject* parent): QObject(parent) {
	this->mTimer.setInterval(this->mIntervalMs);
	QObject::connect(&this->mTimer, &QTimer::timeout, this, &Processes::sample);
}

void Processes::setActive(bool active) {
	if (this->mActive == active) return;
	this->mActive = active;
	emit this->activeChanged();

	if (active) {
		// Two samples make a percentage, so the first one can only ever report
		// 0% for everything -- and at the normal interval that means opening
		// the panel and reading a column of zeros for two full seconds, which
		// looks broken rather than pending.
		//
		// So: sample now for names and memory, take a SECOND one shortly after
		// to turn the CPU column on, and only then settle into the configured
		// interval. A short delta is still a true delta; it is just noisier,
		// which is the right trade for the first frame you actually look at.
		this->sample();
		QTimer::singleShot(400, this, [this]() {
			if (this->mActive) this->sample();
		});
		this->mTimer.start();
	} else {
		this->mTimer.stop();
		// Dropped rather than kept: a delta against a sample from whenever the
		// panel was last open would report a process's average over minutes as
		// if it were current.
		this->mPrev.clear();
		this->mPrevTotal = 0;
	}
}

void Processes::refresh() { this->sample(); }

void Processes::sample() {
	const auto total = totalJiffies();
	const auto totalDelta = total > this->mPrevTotal ? total - this->mPrevTotal : 0;
	memoryTotals(&this->mMemTotal, &this->mMemUsed);

	QDir proc(QStringLiteral("/proc"));
	const auto entries =
	    proc.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::NoSort);

	this->mRows.clear();
	this->mRows.reserve(entries.size());

	for (const auto& entry: entries) {
		bool isPid = false;
		const auto pid = entry.toInt(&isPid);
		if (!isPid) continue;

		QFile statFile(QStringLiteral("/proc/%1/stat").arg(pid));
		if (!statFile.open(QIODevice::ReadOnly)) continue; // exited mid-scan
		const auto stat = statFile.readAll();

		// comm is field 2 and is wrapped in parentheses -- and may itself
		// contain spaces AND parentheses ("(sd-pam)", "Web Content"). Splitting
		// on whitespace mangles those, so the fields after it are found from
		// the LAST ')' rather than by counting from the start.
		const auto close = stat.lastIndexOf(')');
		const auto open = stat.indexOf('(');
		if (open < 0 || close < 0 || close < open) continue;

		const auto name = QString::fromUtf8(stat.mid(open + 1, close - open - 1));
		const auto rest = stat.mid(close + 2).simplified().split(' ');
		// After comm, field 3 is state; utime is field 14 and stime 15 overall,
		// which is index 11 and 12 of what follows the state.
		if (rest.size() < 13) continue;
		const auto jiffies = rest.at(11).toULongLong() + rest.at(12).toULongLong();

		QFile statmFile(QStringLiteral("/proc/%1/statm").arg(pid));
		qulonglong rss = 0;
		if (statmFile.open(QIODevice::ReadOnly)) {
			const auto statm = statmFile.readAll().simplified().split(' ');
			if (statm.size() >= 2)
				rss = statm.at(1).toULongLong() * static_cast<qulonglong>(sysconf(_SC_PAGESIZE));
		}

		double cpu = 0;
		const auto it = this->mPrev.find(pid);
		if (it != this->mPrev.end() && totalDelta > 0 && jiffies >= it->jiffies) {
			cpu = 100.0 * static_cast<double>(jiffies - it->jiffies)
			    / static_cast<double>(totalDelta);
		}

		this->mPrev.insert(pid, Sample { jiffies, true });
		this->mRows.append(Row { pid, name, cpu, rss });
	}

	// Drop pids that did not appear this round, or the table grows for the
	// life of the shell on a machine that churns processes.
	for (auto it = this->mPrev.begin(); it != this->mPrev.end();) {
		if (!it->seen) it = this->mPrev.erase(it);
		else {
			it->seen = false;
			++it;
		}
	}
	// The rows just inserted must survive the sweep above, so they are marked
	// again after it rather than before.
	for (const auto& row: std::as_const(this->mRows))
		this->mPrev[row.pid].seen = true;

	// The header's CPU figure is the sum of the rows, deliberately: a total
	// taken from a second source would disagree with the list under it by a
	// percent or two and look like a bug in one of them.
	double busy = 0;
	for (const auto& row: std::as_const(this->mRows)) busy += row.cpu;
	this->mCpuPct = qBound(0, qRound(busy), 100);

	this->mPrevTotal = total;
	this->rebuild();
}

void Processes::rebuild() {
	auto rows = this->mRows;
	const auto byMem = this->mSortBy == QStringLiteral("mem");

	std::sort(rows.begin(), rows.end(), [byMem](const Row& a, const Row& b) {
		if (byMem) return a.rss > b.rss;
		// CPU ties are common -- most processes are at 0 -- so memory breaks
		// them, which keeps the tail of the list stable between ticks instead
		// of shuffling every refresh.
		if (a.cpu != b.cpu) return a.cpu > b.cpu;
		return a.rss > b.rss;
	});

	if (rows.size() > this->mLimit) rows.resize(this->mLimit);

	QVariantList out;
	out.reserve(rows.size());
	for (const auto& row: std::as_const(rows)) {
		out.append(QVariantMap {
		    {QStringLiteral("pid"), row.pid},
		    {QStringLiteral("name"), row.name},
		    {QStringLiteral("cpu"), row.cpu},
		    {QStringLiteral("mem"), static_cast<qulonglong>(row.rss)},
		    {QStringLiteral("memPct"),
		     this->mMemTotal > 0
		         ? 100.0 * static_cast<double>(row.rss) / static_cast<double>(this->mMemTotal)
		         : 0.0},
		});
	}

	this->mList = std::move(out);
	emit this->listChanged();
}

void Processes::setSortBy(const QString& sortBy) {
	if (this->mSortBy == sortBy) return;
	this->mSortBy = sortBy;
	emit this->sortByChanged();
	// Re-sorted from the sample already in hand, not refetched: changing the
	// question should not cost a walk of /proc.
	this->rebuild();
}

void Processes::setLimit(int limit) {
	if (limit < 1) limit = 1;
	if (this->mLimit == limit) return;
	this->mLimit = limit;
	emit this->limitChanged();
	this->rebuild();
}

void Processes::setIntervalMs(int ms) {
	if (ms < 250) ms = 250;
	if (this->mIntervalMs == ms) return;
	this->mIntervalMs = ms;
	this->mTimer.setInterval(ms);
	emit this->intervalMsChanged();
}
