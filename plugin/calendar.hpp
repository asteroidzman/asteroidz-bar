#pragma once

// Google Calendar, in the shell's own process.
//
// dcal is gone; this replaces the part of it the bar actually needed. What it
// does NOT replace is dcal's sync engine in full -- there is no local store, no
// incremental sync tokens, no write access. A bar's calendar is a read of the
// next few weeks, so it fetches a window and holds it in memory.
//
// The single largest simplification is singleEvents=true on the events query:
// Google expands recurrences server-side and hands back concrete instances, so
// there is no RRULE engine here. That one parameter is the difference between
// this file and a calendar library.
//
// Credentials come from the Secret Service. dcal stored two items per account,
// and the first run MIGRATES them into this shell's own items so that removing
// dcal cannot take the login with it:
//
//   <email>::google.app     {client_id, client_secret}
//   <email>::google.token   {access_token, refresh_token, expiry}
//
// Re-authorisation is ours too, which is what makes dropping dcal complete: a
// refresh token that Google has expired or revoked (it has happened once
// already) is recovered by authorize(), which runs the loopback OAuth flow --
// a one-shot localhost listener, the system browser, and the code exchange --
// rather than by reinstalling the thing this replaced.

#include <QtCore/QDateTime>
#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QVariantList>

class QNetworkAccessManager;
class QNetworkReply;
class QTcpServer;

class Calendar: public QObject {
	Q_OBJECT

	// Concrete event instances in the fetched window, soonest first. Recurring
	// events arrive already expanded, so each element is one occurrence:
	//   id, calendarId, summary, location, description
	//   start, end       ISO 8601 in local time
	//   allDay           bool
	//   colour           the calendar's colour, so a UI can stripe by source
	Q_PROPERTY(QVariantList events READ events NOTIFY eventsChanged)

	// {id, name, colour, selected}. A UI offers these as toggles; `selected`
	// is what the events list is filtered by.
	Q_PROPERTY(QVariantList calendars READ calendars NOTIFY calendarsChanged)

	Q_PROPERTY(bool configured READ configured NOTIFY configuredChanged)
	Q_PROPERTY(bool syncing READ syncing NOTIFY syncingChanged)

	// Set when Google has rejected the refresh token -- the invalid_grant that
	// dcal hit. Distinct from `error`, because it is the one failure a user can
	// do something about, and what they do about it is authorize().
	Q_PROPERTY(bool needsAuth READ needsAuth NOTIFY needsAuthChanged)
	Q_PROPERTY(QString error READ error NOTIFY errorChanged)
	Q_PROPERTY(QString account READ account NOTIFY accountChanged)
	Q_PROPERTY(QDateTime lastSync READ lastSync NOTIFY lastSyncChanged)

	// How far ahead to fetch, in days. A bar shows "what is coming"; a year of
	// events would be a year of JSON for a panel that displays a fortnight.
	Q_PROPERTY(int horizonDays READ horizonDays WRITE setHorizonDays NOTIFY horizonDaysChanged)

public:
	explicit Calendar(QObject* parent = nullptr);
	~Calendar() override;

	Q_DISABLE_COPY_MOVE(Calendar)

	[[nodiscard]] QVariantList events() const { return this->mEvents; }
	[[nodiscard]] QVariantList calendars() const { return this->mCalendars; }
	[[nodiscard]] bool configured() const { return !this->mRefreshToken.isEmpty(); }
	[[nodiscard]] bool syncing() const { return this->mSyncing; }
	[[nodiscard]] bool needsAuth() const { return this->mNeedsAuth; }
	[[nodiscard]] QString error() const { return this->mError; }
	[[nodiscard]] QString account() const { return this->mAccount; }
	[[nodiscard]] QDateTime lastSync() const { return this->mLastSync; }
	[[nodiscard]] int horizonDays() const { return this->mHorizonDays; }

	void setHorizonDays(int days);

	// Fetch the window. Cheap to call: a sync already in flight is not
	// restarted, and the access token is reused until it expires.
	Q_INVOKABLE void sync();

	// The loopback OAuth flow, for a first login or after a revoked token.
	// Binds 127.0.0.1 on an ephemeral port, opens the system browser at
	// Google's consent screen, and completes when the redirect comes back.
	Q_INVOKABLE void authorize();

	// Show or hide one calendar's events without refetching.
	Q_INVOKABLE void setCalendarSelected(const QString& id, bool selected);

signals:
	void eventsChanged();
	void calendarsChanged();
	void configuredChanged();
	void syncingChanged();
	void needsAuthChanged();
	void errorChanged();
	void accountChanged();
	void lastSyncChanged();
	void horizonDaysChanged();

	// Raised when authorize() completes, so a UI can say so and resync.
	void authorized();

private:
	struct CalendarInfo {
		QString id;
		QString name;
		QString colour;
		bool selected = true;
	};

	// ── credentials ─────────────────────────────────────────────────────────
	bool loadCredentials();
	bool migrateFromDcal();
	void storeToken();
	[[nodiscard]] static QString secretLookup(const QString& profile);
	static bool secretStore(const QString& label, const QString& profile, const QString& value);

	// ── oauth ───────────────────────────────────────────────────────────────
	void refreshAccessToken();
	void onTokenReply(QNetworkReply* reply, bool fromAuthCode);
	void exchangeCode(const QString& code, const QString& redirectUri, const QString& verifier);
	void finishAuthServer();

	// ── api ─────────────────────────────────────────────────────────────────
	void fetchCalendarList();
	void fetchEvents();
	void onEventsReply(QNetworkReply* reply, const QString& calendarId);
	void rebuildEvents();

	void setError(const QString& error);
	void setSyncing(bool syncing);
	void setNeedsAuth(bool needsAuth);

	QNetworkAccessManager* mNet = nullptr;

	QString mAccount;
	QString mClientId;
	QString mClientSecret;
	QString mRefreshToken;
	QString mAccessToken;
	QDateTime mAccessExpiry;

	// The loopback listener, alive only for the duration of a consent flow.
	QTcpServer* mAuthServer = nullptr;
	QString mAuthVerifier;
	QString mAuthState;

	QList<CalendarInfo> mCalendarList;
	// Raw instances per calendar, merged into mEvents once all replies land.
	QHash<QString, QVariantList> mPerCalendar;
	int mPending = 0;

	QVariantList mEvents;
	QVariantList mCalendars;
	QDateTime mLastSync;
	QString mError;
	int mHorizonDays = 60;
	bool mSyncing = false;
	bool mNeedsAuth = false;
};
