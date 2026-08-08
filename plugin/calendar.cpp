#include "calendar.hpp"

#include <QtCore/QCryptographicHash>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QRandomGenerator>
#include <QtCore/QTimeZone>
#include <QtCore/QUrlQuery>
#include <QtGui/QDesktopServices>
#include <QtNetwork/QNetworkAccessManager>
#include <QtNetwork/QNetworkReply>
#include <QtNetwork/QNetworkRequest>
#include <QtNetwork/QTcpServer>
#include <QtNetwork/QTcpSocket>

// glib's headers and Qt's `signals` macro cannot both be themselves in one
// translation unit -- the same collision meson.build describes for gdk-pixbuf,
// which it solves by keeping that code in a separate C library. There is no
// separate library to hide behind here, so the macro is stood down for the one
// include that needs it and put straight back.
#pragma push_macro("signals")
#undef signals
#include <libsecret/secret.h>
#pragma pop_macro("signals")

namespace {

const char* const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const char* const AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth";
const char* const API_ROOT = "https://www.googleapis.com/calendar/v3";

// Read-only, deliberately. Nothing here creates or edits an event, and asking
// for write access to display a fortnight is a scope a user would be right to
// refuse.
const char* const SCOPE = "https://www.googleapis.com/auth/calendar.readonly";

// The Secret Service schema dcal wrote under, so its items can be read back.
// DONT_MATCH_NAME because the match that matters is the `profile` attribute --
// the schema name is metadata both sides happen to agree on.
const SecretSchema* profileSchema() {
	static const SecretSchema schema = {
	    "org.freedesktop.Secret.Generic",
	    SECRET_SCHEMA_DONT_MATCH_NAME,
	    {
	        {"profile", SECRET_SCHEMA_ATTRIBUTE_STRING},
	        {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING},
	    },
	    0, 0, 0, 0, 0, 0, 0, 0,
	};
	return &schema;
}

// Our own items are namespaced so they cannot collide with dcal's, and so that
// removing dcal leaves ours untouched.
QString ourProfile(const QString& kind) {
	return QStringLiteral("asteroidz-bar::google.") + kind;
}

QString randomToken(int bytes) {
	QByteArray raw(bytes, Qt::Uninitialized);
	QRandomGenerator::system()->generate(raw.begin(), raw.end());
	return QString::fromLatin1(raw.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)
	);
}

} // namespace

// ---------------------------------------------------------------- lifecycle

Calendar::Calendar(QObject* parent): QObject(parent) {
	this->mNet = new QNetworkAccessManager(this);

	if (this->loadCredentials()) {
		this->sync();
	}
}

Calendar::~Calendar() { this->finishAuthServer(); }

// ---------------------------------------------------------------- secrets

QString Calendar::secretLookup(const QString& profile) {
	GError* err = nullptr;
	gchar* value = secret_password_lookup_sync(
	    profileSchema(),
	    nullptr,
	    &err,
	    "profile",
	    profile.toUtf8().constData(),
	    nullptr
	);
	if (err != nullptr) {
		g_error_free(err);
		return {};
	}
	if (value == nullptr) return {};

	auto out = QString::fromUtf8(value);
	secret_password_free(value);
	return out;
}

bool Calendar::secretStore(const QString& label, const QString& profile, const QString& value) {
	GError* err = nullptr;
	const auto ok = secret_password_store_sync(
	    profileSchema(),
	    SECRET_COLLECTION_DEFAULT,
	    label.toUtf8().constData(),
	    value.toUtf8().constData(),
	    nullptr,
	    &err,
	    "profile",
	    profile.toUtf8().constData(),
	    nullptr
	);
	if (err != nullptr) {
		g_error_free(err);
		return false;
	}
	return ok != FALSE;
}

// Take dcal's login, once.
//
// This is what makes "drop dcal" safe rather than destructive: the account is
// already authorised, and making the user consent again just to change which
// program asks would be a worse experience than the migration. After this the
// shell has its own items and never reads dcal's again -- so uninstalling it,
// or dcal clearing its own keys, cannot take the calendar down.
bool Calendar::migrateFromDcal() {
	// dcal keys its items by the account address, which is not something we
	// know in advance. Reading it out of dcal's SQLite would mean linking
	// sqlite3 for one string; its keyring LABEL carries the same address, and
	// the keyring is already open, so the account is discovered by walking
	// labels instead.
	//
	// Nothing here reads a value it does not need: the walk looks only at
	// labels, and only the two items belonging to the account are fetched.
	// ENUMERATE the collections; do not search them.
	//
	// secret_service_search_sync() answers "which items carry these
	// attributes", so an empty attribute table is not a wildcard -- it matches
	// nothing, and returned 0 items here while the account sat in the keyring
	// the whole time. (Passing NULL instead is worse: libsecret walks the table
	// unconditionally while validating, so NULL segfaults inside
	// secret_attributes_validate and took the whole shell down.) There is no
	// attribute to search on anyway, because the account address is precisely
	// the thing being discovered.
	GError* err = nullptr;
	SecretService* service =
	    secret_service_get_sync(SECRET_SERVICE_LOAD_COLLECTIONS, nullptr, &err);
	if (service == nullptr) {
		if (err != nullptr) g_error_free(err);
		return false;
	}

	QString account;
	GList* collections = secret_service_get_collections(service);
	for (GList* c = collections; c != nullptr && account.isEmpty(); c = c->next) {
		auto* collection = static_cast<SecretCollection*>(c->data);

		// A locked collection lists no items. Unlocking prompts, which is the
		// correct thing to do for a migration the user asked for.
		if (secret_collection_get_locked(collection) != FALSE) {
			GList* one = g_list_append(nullptr, collection);
			GList* unlocked = nullptr;
			secret_service_unlock_sync(service, one, nullptr, &unlocked, nullptr);
			g_list_free(one);
			g_list_free(unlocked);
		}

		GList* items = secret_collection_get_items(collection);
		for (GList* l = items; l != nullptr; l = l->next) {
			auto* item = static_cast<SecretItem*>(l->data);
			gchar* label = secret_item_get_label(item);
			const auto text = QString::fromUtf8(label != nullptr ? label : "");
			g_free(label);

			// "dankcal: someone@example.com (google.app)"
			if (!text.startsWith(QStringLiteral("dankcal: "))) continue;
			if (!text.contains(QStringLiteral("(google.app)"))) continue;

			account = text.mid(QStringLiteral("dankcal: ").length());
			account = account.left(account.indexOf(QStringLiteral(" (")));
			break;
		}
		g_list_free_full(items, g_object_unref);
	}
	g_list_free_full(collections, g_object_unref);
	g_object_unref(service);

	if (account.isEmpty()) return false;

	const auto app = secretLookup(account + QStringLiteral("::google.app"));
	const auto token = secretLookup(account + QStringLiteral("::google.token"));
	if (app.isEmpty() || token.isEmpty()) return false;

	secretStore(QStringLiteral("asteroidz-bar: %1 (google.app)").arg(account), ourProfile("app"), app);
	secretStore(
	    QStringLiteral("asteroidz-bar: %1 (google.token)").arg(account),
	    ourProfile("token"),
	    token
	);
	secretStore(QStringLiteral("asteroidz-bar: account"), ourProfile("account"), account);
	return true;
}

bool Calendar::loadCredentials() {
	auto app = secretLookup(ourProfile("app"));
	auto token = secretLookup(ourProfile("token"));
	this->mAccount = secretLookup(ourProfile("account"));

	if (app.isEmpty() || token.isEmpty()) {
		if (!this->migrateFromDcal()) return false;
		app = secretLookup(ourProfile("app"));
		token = secretLookup(ourProfile("token"));
		this->mAccount = secretLookup(ourProfile("account"));
		if (app.isEmpty() || token.isEmpty()) return false;
	}

	const auto appDoc = QJsonDocument::fromJson(app.toUtf8()).object();
	this->mClientId = appDoc.value(QStringLiteral("client_id")).toString();
	this->mClientSecret = appDoc.value(QStringLiteral("client_secret")).toString();

	const auto tokDoc = QJsonDocument::fromJson(token.toUtf8()).object();
	this->mRefreshToken = tokDoc.value(QStringLiteral("refresh_token")).toString();
	this->mAccessToken = tokDoc.value(QStringLiteral("access_token")).toString();
	this->mAccessExpiry =
	    QDateTime::fromString(tokDoc.value(QStringLiteral("expiry")).toString(), Qt::ISODate);

	emit this->accountChanged();
	emit this->configuredChanged();
	return !this->mRefreshToken.isEmpty() && !this->mClientId.isEmpty();
}

void Calendar::storeToken() {
	QJsonObject obj {
	    {QStringLiteral("access_token"), this->mAccessToken},
	    {QStringLiteral("refresh_token"), this->mRefreshToken},
	    {QStringLiteral("token_type"), QStringLiteral("Bearer")},
	    {QStringLiteral("expiry"), this->mAccessExpiry.toUTC().toString(Qt::ISODate)},
	};
	secretStore(
	    QStringLiteral("asteroidz-bar: %1 (google.token)").arg(this->mAccount),
	    ourProfile("token"),
	    QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact))
	);
}

// ---------------------------------------------------------------- oauth

void Calendar::refreshAccessToken() {
	QUrlQuery form;
	form.addQueryItem(QStringLiteral("client_id"), this->mClientId);
	if (!this->mClientSecret.isEmpty())
		form.addQueryItem(QStringLiteral("client_secret"), this->mClientSecret);
	form.addQueryItem(QStringLiteral("refresh_token"), this->mRefreshToken);
	form.addQueryItem(QStringLiteral("grant_type"), QStringLiteral("refresh_token"));

	QNetworkRequest req { QUrl(QString::fromLatin1(TOKEN_ENDPOINT)) };
	req.setHeader(
	    QNetworkRequest::ContentTypeHeader,
	    QStringLiteral("application/x-www-form-urlencoded")
	);

	auto* reply = this->mNet->post(req, form.toString(QUrl::FullyEncoded).toUtf8());
	QObject::connect(reply, &QNetworkReply::finished, this, [this, reply]() {
		this->onTokenReply(reply, false);
	});
}

void Calendar::onTokenReply(QNetworkReply* reply, bool fromAuthCode) {
	reply->deleteLater();
	const auto body = reply->readAll();
	const auto obj = QJsonDocument::fromJson(body).object();

	if (obj.contains(QStringLiteral("error"))) {
		const auto code = obj.value(QStringLiteral("error")).toString();
		// invalid_grant is the one that is not a transient failure: Google has
		// expired or revoked the refresh token, and no amount of retrying will
		// change that. It is exactly what killed dcal's login, and the answer
		// is a new consent, so say so rather than logging a 400 forever.
		if (code == QStringLiteral("invalid_grant")) {
			this->setNeedsAuth(true);
			this->setError(QStringLiteral("the calendar login has expired -- reauthorise"));
		} else {
			this->setError(QStringLiteral("token: %1").arg(code));
		}
		this->setSyncing(false);
		return;
	}

	this->mAccessToken = obj.value(QStringLiteral("access_token")).toString();
	const auto ttl = obj.value(QStringLiteral("expires_in")).toInt(3600);
	// A minute of slack, so a request is never issued against a token that
	// expires while it is in flight.
	this->mAccessExpiry = QDateTime::currentDateTimeUtc().addSecs(ttl - 60);

	// Only an authorisation-code exchange returns a refresh token; a refresh
	// does not, and overwriting the stored one with an empty string is how a
	// working login becomes a broken one.
	const auto fresh = obj.value(QStringLiteral("refresh_token")).toString();
	if (!fresh.isEmpty()) this->mRefreshToken = fresh;

	this->storeToken();
	this->setNeedsAuth(false);
	this->setError({});

	if (fromAuthCode) {
		emit this->configuredChanged();
		emit this->authorized();
	}
	this->fetchCalendarList();
}

void Calendar::authorize() {
	this->finishAuthServer();

	// PKCE, even with a client secret present: the code travels back over a
	// plain-HTTP loopback redirect, which is the one hop another local process
	// could conceivably observe.
	this->mAuthVerifier = randomToken(48);
	this->mAuthState = randomToken(16);
	const auto challenge = QString::fromLatin1(
	    QCryptographicHash::hash(this->mAuthVerifier.toUtf8(), QCryptographicHash::Sha256)
	        .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)
	);

	this->mAuthServer = new QTcpServer(this);
	if (!this->mAuthServer->listen(QHostAddress::LocalHost, 0)) {
		this->setError(QStringLiteral("could not open a local port for the login"));
		this->finishAuthServer();
		return;
	}

	const auto redirect =
	    QStringLiteral("http://127.0.0.1:%1").arg(this->mAuthServer->serverPort());

	QObject::connect(this->mAuthServer, &QTcpServer::newConnection, this, [this, redirect]() {
		auto* sock = this->mAuthServer->nextPendingConnection();
		if (sock == nullptr) return;

		QObject::connect(sock, &QTcpSocket::readyRead, this, [this, sock, redirect]() {
			const auto line = QString::fromUtf8(sock->readLine());
			// "GET /?code=...&state=... HTTP/1.1"
			const auto path = line.section(' ', 1, 1);
			const QUrlQuery q { QUrl(QStringLiteral("http://x") + path).query() };

			const auto code = q.queryItemValue(QStringLiteral("code"), QUrl::FullyDecoded);
			const auto state = q.queryItemValue(QStringLiteral("state"), QUrl::FullyDecoded);
			const auto err = q.queryItemValue(QStringLiteral("error"), QUrl::FullyDecoded);

			QString message;
			if (!err.isEmpty()) {
				message = QStringLiteral("Authorisation refused: %1").arg(err);
				this->setError(message);
			} else if (state != this->mAuthState) {
				// Not pedantry: without it any page you visit could hand this
				// listener a code of its choosing.
				message = QStringLiteral("Authorisation failed: state mismatch");
				this->setError(message);
			} else if (code.isEmpty()) {
				message = QStringLiteral("Authorisation returned no code");
				this->setError(message);
			} else {
				message = QStringLiteral("Signed in. You can close this tab.");
			}

			const auto html = QStringLiteral("<!doctype html><meta charset=utf-8>"
			                                 "<body style='font-family:sans-serif;padding:3em'>"
			                                 "<p>%1</p></body>")
			                      .arg(message)
			                      .toUtf8();
			sock->write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n");
			sock->write(QStringLiteral("Content-Length: %1\r\n\r\n").arg(html.size()).toUtf8());
			sock->write(html);
			sock->flush();
			sock->disconnectFromHost();

			if (!code.isEmpty() && state == this->mAuthState)
				this->exchangeCode(code, redirect, this->mAuthVerifier);

			this->finishAuthServer();
		});
	});

	QUrlQuery q;
	q.addQueryItem(QStringLiteral("client_id"), this->mClientId);
	q.addQueryItem(QStringLiteral("redirect_uri"), redirect);
	q.addQueryItem(QStringLiteral("response_type"), QStringLiteral("code"));
	q.addQueryItem(QStringLiteral("scope"), QString::fromLatin1(SCOPE));
	// offline + consent, or Google returns no refresh token on a re-consent for
	// an already-approved client -- which would leave this able to read the
	// calendar exactly once, until the access token expired an hour later.
	q.addQueryItem(QStringLiteral("access_type"), QStringLiteral("offline"));
	q.addQueryItem(QStringLiteral("prompt"), QStringLiteral("consent"));
	q.addQueryItem(QStringLiteral("code_challenge"), challenge);
	q.addQueryItem(QStringLiteral("code_challenge_method"), QStringLiteral("S256"));
	q.addQueryItem(QStringLiteral("state"), this->mAuthState);
	if (!this->mAccount.isEmpty())
		q.addQueryItem(QStringLiteral("login_hint"), this->mAccount);

	QUrl url { QString::fromLatin1(AUTH_ENDPOINT) };
	url.setQuery(q);
	QDesktopServices::openUrl(url);
}

void Calendar::exchangeCode(
    const QString& code,
    const QString& redirectUri,
    const QString& verifier
) {
	QUrlQuery form;
	form.addQueryItem(QStringLiteral("client_id"), this->mClientId);
	if (!this->mClientSecret.isEmpty())
		form.addQueryItem(QStringLiteral("client_secret"), this->mClientSecret);
	form.addQueryItem(QStringLiteral("code"), code);
	form.addQueryItem(QStringLiteral("code_verifier"), verifier);
	form.addQueryItem(QStringLiteral("redirect_uri"), redirectUri);
	form.addQueryItem(QStringLiteral("grant_type"), QStringLiteral("authorization_code"));

	QNetworkRequest req { QUrl(QString::fromLatin1(TOKEN_ENDPOINT)) };
	req.setHeader(
	    QNetworkRequest::ContentTypeHeader,
	    QStringLiteral("application/x-www-form-urlencoded")
	);

	auto* reply = this->mNet->post(req, form.toString(QUrl::FullyEncoded).toUtf8());
	QObject::connect(reply, &QNetworkReply::finished, this, [this, reply]() {
		this->onTokenReply(reply, true);
	});
}

void Calendar::finishAuthServer() {
	if (this->mAuthServer == nullptr) return;
	this->mAuthServer->close();
	this->mAuthServer->deleteLater();
	this->mAuthServer = nullptr;
}

// ---------------------------------------------------------------- api

void Calendar::sync() {
	if (this->mSyncing || this->mRefreshToken.isEmpty()) return;
	this->setSyncing(true);

	if (this->mAccessToken.isEmpty() || !this->mAccessExpiry.isValid()
	    || this->mAccessExpiry <= QDateTime::currentDateTimeUtc()) {
		this->refreshAccessToken();
		return;
	}
	this->fetchCalendarList();
}

void Calendar::ensureMonth(const QDate& month) {
	if (!month.isValid() || this->mRefreshToken.isEmpty()) return;

	// A whole month, plus the days either side that a six-week grid shows --
	// the cells before the 1st and after the last are real days with real
	// events, and a dot missing from them is the same lie as an empty month.
	const auto wantFrom = QDate(month.year(), month.month(), 1).addDays(-7);
	const auto wantTo = wantFrom.addDays(7).addMonths(1).addDays(7);

	const auto now = QDate::currentDate();
	if (!this->mRangeStart.isValid()) this->mRangeStart = now;
	if (!this->mRangeEnd.isValid()) this->mRangeEnd = now.addDays(this->mHorizonDays);

	auto grew = false;
	if (wantFrom < this->mRangeStart) {
		this->mRangeStart = wantFrom;
		grew = true;
	}
	if (wantTo > this->mRangeEnd) {
		this->mRangeEnd = wantTo;
		grew = true;
	}

	// Only when it actually grew. Paging back and forth across a boundary
	// would otherwise be a network round trip per keypress.
	if (grew) this->sync();
}

void Calendar::fetchCalendarList() {
	QNetworkRequest req { QUrl(QString::fromLatin1(API_ROOT) + QStringLiteral("/users/me/calendarList"))
	};
	req.setRawHeader("Authorization", ("Bearer " + this->mAccessToken).toUtf8());

	auto* reply = this->mNet->get(req);
	QObject::connect(reply, &QNetworkReply::finished, this, [this, reply]() {
		reply->deleteLater();
		const auto obj = QJsonDocument::fromJson(reply->readAll()).object();
		if (obj.contains(QStringLiteral("error"))) {
			this->setError(
			    QStringLiteral("calendars: %1")
			        .arg(obj.value(QStringLiteral("error")).toObject().value(QStringLiteral("message")).toString(
			        ))
			);
			this->setSyncing(false);
			return;
		}

		// Selections are the user's, not the server's, so they survive a resync.
		QHash<QString, bool> wasSelected;
		for (const auto& c: std::as_const(this->mCalendarList))
			wasSelected.insert(c.id, c.selected);

		this->mCalendarList.clear();
		const auto items = obj.value(QStringLiteral("items")).toArray();
		for (const auto& v: items) {
			const auto item = v.toObject();
			CalendarInfo info;
			info.id = item.value(QStringLiteral("id")).toString();
			info.name = item.value(QStringLiteral("summaryOverride")).toString();
			if (info.name.isEmpty()) info.name = item.value(QStringLiteral("summary")).toString();
			info.colour = item.value(QStringLiteral("backgroundColor")).toString();
			info.selected = wasSelected.value(info.id, !item.value(QStringLiteral("selected")).isBool()
			                                              || item.value(QStringLiteral("selected")).toBool());
			this->mCalendarList.append(info);
		}

		QVariantList out;
		for (const auto& c: std::as_const(this->mCalendarList)) {
			out.append(QVariantMap {
			    {QStringLiteral("id"), c.id},
			    {QStringLiteral("name"), c.name},
			    {QStringLiteral("colour"), c.colour},
			    {QStringLiteral("selected"), c.selected},
			});
		}
		this->mCalendars = std::move(out);
		emit this->calendarsChanged();

		this->fetchEvents();
	});
}

void Calendar::fetchEvents() {
	this->mPerCalendar.clear();
	this->mPending = 0;

	const auto now = QDateTime::currentDateTime();
	// From the start of today, not from this instant: an event you are in the
	// middle of is the one most worth showing.
	if (!this->mRangeStart.isValid()) this->mRangeStart = now.date();
	if (!this->mRangeEnd.isValid())
		this->mRangeEnd = now.date().addDays(this->mHorizonDays);

	const auto from = QDateTime(this->mRangeStart, QTime(0, 0), now.timeZone());
	const auto to = QDateTime(this->mRangeEnd, QTime(0, 0), now.timeZone());

	for (const auto& cal: std::as_const(this->mCalendarList)) {
		QUrlQuery q;
		q.addQueryItem(QStringLiteral("timeMin"), from.toUTC().toString(Qt::ISODate));
		q.addQueryItem(QStringLiteral("timeMax"), to.toUTC().toString(Qt::ISODate));
		// The line that removes an RRULE engine from this file: Google expands
		// recurrences and returns concrete instances.
		q.addQueryItem(QStringLiteral("singleEvents"), QStringLiteral("true"));
		q.addQueryItem(QStringLiteral("orderBy"), QStringLiteral("startTime"));
		q.addQueryItem(QStringLiteral("maxResults"), QStringLiteral("250"));

		QUrl url {
		    QString::fromLatin1(API_ROOT) + QStringLiteral("/calendars/")
		    + QString::fromUtf8(QUrl::toPercentEncoding(cal.id)) + QStringLiteral("/events")
		};
		url.setQuery(q);

		QNetworkRequest req { url };
		req.setRawHeader("Authorization", ("Bearer " + this->mAccessToken).toUtf8());

		this->mPending++;
		const auto id = cal.id;
		auto* reply = this->mNet->get(req);
		QObject::connect(reply, &QNetworkReply::finished, this, [this, reply, id]() {
			this->onEventsReply(reply, id);
		});
	}

	if (this->mPending == 0) {
		this->setSyncing(false);
		this->rebuildEvents();
	}
}

void Calendar::onEventsReply(QNetworkReply* reply, const QString& calendarId) {
	reply->deleteLater();
	const auto obj = QJsonDocument::fromJson(reply->readAll()).object();

	QVariantList out;
	const auto items = obj.value(QStringLiteral("items")).toArray();
	for (const auto& v: items) {
		const auto item = v.toObject();
		if (item.value(QStringLiteral("status")).toString() == QStringLiteral("cancelled"))
			continue;

		const auto startObj = item.value(QStringLiteral("start")).toObject();
		const auto endObj = item.value(QStringLiteral("end")).toObject();

		// An all-day event carries `date`; a timed one carries `dateTime`.
		// They are different fields, not a formatting difference, and treating
		// a date as a dateTime lands it at midnight UTC -- which is the day
		// before, for anyone west of Greenwich.
		const auto startDate = startObj.value(QStringLiteral("date")).toString();
		const auto allDay = !startDate.isEmpty();

		QDateTime start;
		QDateTime end;
		if (allDay) {
			start = QDateTime(QDate::fromString(startDate, Qt::ISODate), QTime(0, 0));
			end = QDateTime(
			    QDate::fromString(endObj.value(QStringLiteral("date")).toString(), Qt::ISODate),
			    QTime(0, 0)
			);
		} else {
			start = QDateTime::fromString(
			    startObj.value(QStringLiteral("dateTime")).toString(),
			    Qt::ISODate
			).toLocalTime();
			end = QDateTime::fromString(
			    endObj.value(QStringLiteral("dateTime")).toString(),
			    Qt::ISODate
			).toLocalTime();
		}
		if (!start.isValid()) continue;

		QString colour;
		for (const auto& c: std::as_const(this->mCalendarList))
			if (c.id == calendarId) colour = c.colour;

		out.append(QVariantMap {
		    {QStringLiteral("id"), item.value(QStringLiteral("id")).toString()},
		    {QStringLiteral("calendarId"), calendarId},
		    {QStringLiteral("summary"), item.value(QStringLiteral("summary")).toString()},
		    {QStringLiteral("location"), item.value(QStringLiteral("location")).toString()},
		    {QStringLiteral("description"), item.value(QStringLiteral("description")).toString()},
		    {QStringLiteral("start"), start},
		    {QStringLiteral("end"), end},
		    {QStringLiteral("allDay"), allDay},
		    {QStringLiteral("colour"), colour},
		});
	}

	this->mPerCalendar.insert(calendarId, out);

	if (--this->mPending <= 0) {
		this->mLastSync = QDateTime::currentDateTime();
		emit this->lastSyncChanged();
		this->setSyncing(false);
		this->setError({});
		this->rebuildEvents();
	}
}

void Calendar::rebuildEvents() {
	QVariantList all;
	for (const auto& cal: std::as_const(this->mCalendarList)) {
		if (!cal.selected) continue;
		all.append(this->mPerCalendar.value(cal.id));
	}

	std::sort(all.begin(), all.end(), [](const QVariant& a, const QVariant& b) {
		return a.toMap().value(QStringLiteral("start")).toDateTime()
		     < b.toMap().value(QStringLiteral("start")).toDateTime();
	});

	this->mEvents = std::move(all);
	emit this->eventsChanged();
}

void Calendar::setCalendarSelected(const QString& id, bool selected) {
	for (auto& c: this->mCalendarList) {
		if (c.id != id) continue;
		if (c.selected == selected) return;
		c.selected = selected;

		for (auto& v: this->mCalendars) {
			auto m = v.toMap();
			if (m.value(QStringLiteral("id")).toString() == id) {
				m.insert(QStringLiteral("selected"), selected);
				v = m;
			}
		}
		emit this->calendarsChanged();
		this->rebuildEvents();
		return;
	}
}

// ---------------------------------------------------------------- the rest

void Calendar::setHorizonDays(int days) {
	if (days < 1) days = 1;
	if (this->mHorizonDays == days) return;
	this->mHorizonDays = days;
	emit this->horizonDaysChanged();
	this->sync();
}

void Calendar::setError(const QString& error) {
	if (this->mError == error) return;
	this->mError = error;
	emit this->errorChanged();
}

void Calendar::setSyncing(bool syncing) {
	if (this->mSyncing == syncing) return;
	this->mSyncing = syncing;
	emit this->syncingChanged();
}

void Calendar::setNeedsAuth(bool needsAuth) {
	if (this->mNeedsAuth == needsAuth) return;
	this->mNeedsAuth = needsAuth;
	emit this->needsAuthChanged();
}
