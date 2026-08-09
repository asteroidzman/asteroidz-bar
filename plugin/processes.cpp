#include "processes.hpp"

#include <dirent.h>
#include <fcntl.h>
#include <linux/inet_diag.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h> // RTA_OK / RTA_NEXT / RTA_PAYLOAD, and rtattr
#include <linux/sock_diag.h>
#include <netinet/in.h>      // IPPROTO_TCP
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

#include <QtCore/QByteArray>
#include <QtCore/QDateTime>
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
		this->mPrevNet.clear();
		this->mPrevNetMs = 0;
	}
}

void Processes::refresh() { this->sample(); }


// Per-process network bytes, via netlink sock_diag.
//
// Linux does not offer this directly, and the obvious places are traps:
// /proc/<pid>/net/dev is per NETWORK NAMESPACE, so every process in the same
// namespace reports the machine's totals -- two unrelated pids return byte for
// byte the same numbers -- and /proc/<pid>/io counts all I/O, files included.
//
// What does exist is tcp_info, which the kernel keeps PER SOCKET and which
// carries tcpi_bytes_sent/tcpi_bytes_received. sock_diag hands those out for
// every socket along with its inode, and an inode maps to a pid through
// /proc/<pid>/fd. That is exactly what `ss -tinp` does; this is the same query
// without forking ss every tick.
//
// WHAT THIS DOES NOT SEE, which matters more than what it does:
//
//   UDP. There is no tcp_info for a UDP socket, so DNS, WireGuard, most games
//   and -- the big one -- HTTP/3 are invisible. A browser on QUIC can move
//   hundreds of megabytes and appear idle here. The interface totals on the
//   network pill DO include it, so the two disagreeing is expected rather than
//   a bug in either.
//
//   Sockets that both open and close between two samples. Their bytes are
//   never observed at all.
//
// Attribution is same-user only, which is the whole of a desktop session but
// means a system daemon's traffic lands nowhere.
void Processes::sampleNet(QHash<int, NetSample>* out) {
	// inode -> bytes, filled from netlink, then attributed to pids below.
	QHash<qulonglong, NetSample> byInode;

	for (const auto family: {AF_INET, AF_INET6}) {
		const auto fd = ::socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_INET_DIAG);
		if (fd < 0) return;

		struct {
			nlmsghdr nlh;
			inet_diag_req_v2 req;
		} query {};

		query.nlh.nlmsg_len = sizeof(query);
		query.nlh.nlmsg_type = SOCK_DIAG_BY_FAMILY;
		query.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
		query.req.sdiag_family = static_cast<uint8_t>(family);
		query.req.sdiag_protocol = IPPROTO_TCP;
		// INFO is the whole point: without it the reply carries no tcp_info and
		// therefore no byte counters.
		query.req.idiag_ext = 1u << (INET_DIAG_INFO - 1);
		query.req.idiag_states = ~0u;

		sockaddr_nl addr {};
		addr.nl_family = AF_NETLINK;
		if (::sendto(
		        fd,
		        &query,
		        sizeof(query),
		        0,
		        reinterpret_cast<sockaddr*>(&addr),
		        sizeof(addr)
		    )
		    < 0) {
			::close(fd);
			continue;
		}

		QByteArray buf(32768, Qt::Uninitialized);
		auto done = false;
		while (!done) {
			auto len = static_cast<int>(::recv(fd, buf.data(), buf.size(), 0));
			if (len <= 0) break;

			for (auto* nlh = reinterpret_cast<nlmsghdr*>(buf.data());
			     NLMSG_OK(nlh, static_cast<unsigned>(len));
			     nlh = NLMSG_NEXT(nlh, len)) {
				if (nlh->nlmsg_type == NLMSG_DONE || nlh->nlmsg_type == NLMSG_ERROR) {
					done = true;
					break;
				}

				const auto* msg = static_cast<inet_diag_msg*>(NLMSG_DATA(nlh));
				auto rta_len = static_cast<int>(nlh->nlmsg_len - NLMSG_LENGTH(sizeof(*msg)));

				for (auto* attr = reinterpret_cast<rtattr*>(
				         reinterpret_cast<char*>(NLMSG_DATA(nlh)) + NLMSG_ALIGN(sizeof(*msg))
				     );
				     RTA_OK(attr, rta_len);
				     attr = RTA_NEXT(attr, rta_len)) {
					if (attr->rta_type != INET_DIAG_INFO) continue;

					// Short-read guard: the struct grows between kernel
					// versions, and a build against newer headers than the
					// running kernel would otherwise read past the payload.
					tcp_info info {};
					const auto avail = static_cast<size_t>(RTA_PAYLOAD(attr));
					memcpy(&info, RTA_DATA(attr), qMin(avail, sizeof(info)));

					auto& entry = byInode[msg->idiag_inode];
					entry.rx += info.tcpi_bytes_received;
					entry.tx += info.tcpi_bytes_sent;
				}
			}
		}
		::close(fd);
	}

	if (byInode.isEmpty()) return;

	// inode -> pid, by reading every process's fd links. This is the expensive
	// half and the reason net sampling is opt-in: a browser alone can hold
	// thousands of descriptors.
	// opendir/readlinkat rather than QDir, for two reasons.
	//
	// Correctness first: /proc/<pid>/fd entries are symlinks to "socket:[N]",
	// which resolves to no real file. QDir::Files therefore matches NONE of
	// them -- the first version of this walked every process, found zero
	// descriptors, and reported a machine where nothing used the network while
	// netlink was handing back fifty live sockets.
	//
	// Speed second: this is the hot half of a sample, and QDir stats every
	// entry it lists. readlinkat asks the one question that matters.
	DIR* procDir = ::opendir("/proc");
	if (procDir == nullptr) return;

	while (auto* ent = ::readdir(procDir)) {
		char* end = nullptr;
		const auto pid = ::strtol(ent->d_name, &end, 10);
		if (end == ent->d_name || *end != '\0') continue;

		char path[64];
		::snprintf(path, sizeof(path), "/proc/%ld/fd", pid);
		DIR* fdDir = ::opendir(path);
		if (fdDir == nullptr) continue; // not ours, or exited mid-walk

		const auto dirFd = ::dirfd(fdDir);
		while (auto* fdEnt = ::readdir(fdDir)) {
			if (fdEnt->d_name[0] == '.') continue;

			char target[64];
			const auto n = ::readlinkat(dirFd, fdEnt->d_name, target, sizeof(target) - 1);
			if (n <= 0) continue;
			target[n] = '\0';

			if (::strncmp(target, "socket:[", 8) != 0) continue;
			const auto inode = ::strtoull(target + 8, nullptr, 10);

			const auto it = byInode.constFind(inode);
			if (it == byInode.constEnd()) continue;

			auto& acc = (*out)[static_cast<int>(pid)];
			acc.rx += it->rx;
			acc.tx += it->tx;
		}
		::closedir(fdDir);
	}
	::closedir(procDir);
}

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

	// Network, only when something is sorting by it: the fd walk below is the
	// expensive part of a sample and pointless when nobody is looking at the
	// column it fills.
	if (this->mSortBy == QStringLiteral("net")) {
		QHash<int, NetSample> now;
		this->sampleNet(&now);

		const auto nowMs = QDateTime::currentMSecsSinceEpoch();
		const auto elapsed = this->mPrevNetMs > 0
		    ? static_cast<double>(nowMs - this->mPrevNetMs) / 1000.0
		    : 0.0;

		if (elapsed > 0.05) {
			for (auto& row: this->mRows) {
				const auto cur = now.constFind(row.pid);
				if (cur == now.constEnd()) continue;
				const auto prev = this->mPrevNet.constFind(row.pid);
				if (prev == this->mPrevNet.constEnd()) continue;

				// Counters can go DOWN between samples: they are a sum over
				// live sockets, and a closed connection takes its bytes out of
				// the total. Clamping at zero reports "nothing new" rather
				// than a negative rate, which is the honest reading -- the
				// bytes did happen, we just stopped being able to see them.
				if (cur->rx > prev->rx) row.rx = static_cast<double>(cur->rx - prev->rx) / elapsed;
				if (cur->tx > prev->tx) row.tx = static_cast<double>(cur->tx - prev->tx) / elapsed;
			}
		}

		this->mPrevNet = now;
		this->mPrevNetMs = nowMs;
	}

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
	const auto byNet = this->mSortBy == QStringLiteral("net");

	std::sort(rows.begin(), rows.end(), [byMem, byNet](const Row& a, const Row& b) {
		if (byNet) {
			const auto at = a.rx + a.tx;
			const auto bt = b.rx + b.tx;
			// Total throughput, not rx or tx alone: an upload and a download
			// are both "using the network", and sorting on one buries the
			// other.
			if (at != bt) return at > bt;
			return a.rss > b.rss;
		}
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
		    {QStringLiteral("rx"), row.rx},
		    {QStringLiteral("tx"), row.tx},
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
