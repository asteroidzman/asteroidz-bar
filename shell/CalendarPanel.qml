// The calendar, under the clock.
//
// A month you can page through, and the day you picked written out underneath.
// That is the whole thing. DankMaterialShell's equivalent runs to about three
// thousand lines across an editor, a detail view and a context menu; this is a
// bar panel, and the question a bar panel answers is "what is on today, and
// what is the date on Thursday".
//
// Events come from the C++ Calendar singleton (Google Calendar over the
// account migrated from dcal). Nothing here fetches, parses or knows what a
// recurrence is -- instances arrive already expanded.

import Quickshell
import QtQuick
import Asteroidz.Bar
import "."

Item {
    id: root

    signal closeRequested()

    implicitWidth: Cfg.calendarWidth
    implicitHeight: col.implicitHeight

    // The month on show, as the first of it. Paging moves this; picking a day
    // does not, so clicking the 3rd of next month does not snap you back.
    property date shownMonth: {
        const now = new Date();
        return new Date(now.getFullYear(), now.getMonth(), 1);
    }
    property date selectedDay: new Date()

    readonly property date today: new Date()

    function sameDay(a, b) {
        return a.getFullYear() === b.getFullYear()
            && a.getMonth() === b.getMonth()
            && a.getDate() === b.getDate();
    }

    function pageMonth(delta) {
        root.shownMonth = new Date(root.shownMonth.getFullYear(),
                                   root.shownMonth.getMonth() + delta, 1);
    }

    // Tell the backend which month is on show, so it can widen its fetch.
    //
    // The grid pages without limit; the fetch reaches horizonDays ahead. Left
    // to itself that means paging past the horizon draws a month with no dots,
    // which reads as "nothing on all month" rather than "not fetched" -- the
    // one thing a calendar must not get wrong. ensureMonth() only refetches
    // when the range actually grows.
    onShownMonthChanged: Calendar.ensureMonth(root.shownMonth)

    // Events grouped by day, built once per change rather than filtered per
    // cell: a month grid asks "has this day anything" 42 times, and doing that
    // as a scan of the whole list each time is 42 scans for one repaint.
    readonly property var byDay: {
        const map = ({});
        for (const e of Calendar.events) {
            const d = e.start;
            const key = d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate();
            if (!map[key])
                map[key] = [];
            map[key].push(e);
        }
        return map;
    }

    function eventsOn(date) {
        const key = date.getFullYear() + "-" + date.getMonth() + "-" + date.getDate();
        return root.byDay[key] || [];
    }

    // The 42 cells of the grid: six weeks from the Monday on or before the
    // first of the month. Fixed at six rows so the panel does not change
    // height as you page, which is what makes the arrows feel like paging
    // rather than resizing.
    readonly property var cells: {
        const first = new Date(root.shownMonth);
        // getDay() is 0=Sunday; this week starts Monday, so Sunday is 6 back.
        const offset = (first.getDay() + 6) % 7;
        const start = new Date(first.getFullYear(), first.getMonth(), 1 - offset);
        const out = [];
        for (let i = 0; i < 42; i++)
            out.push(new Date(start.getFullYear(), start.getMonth(), start.getDate() + i));
        return out;
    }

    Component.onCompleted: {
        Calendar.horizonDays = Cfg.calendarHorizon;
        // Cheap when it is already current: sync() reuses an unexpired access
        // token and refuses to start a second fetch over one in flight.
        Calendar.sync();
    }

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        // ── month header ────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.shownMonth, "MMMM yyyy")
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.weight: Font.DemiBold
                font.hintingPreference: Font.PreferFullHinting
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Repeater {
                    model: [
                        { glyph: "‹", delta: -1 },
                        { glyph: "·", delta: 0 },
                        { glyph: "›", delta: 1 },
                    ]

                    delegate: Rectangle {
                        required property var modelData
                        width: Math.max(20, Math.round(Cfg.fontPixelSize * 1.3))
                        height: width
                        radius: Cfg.themeRadius
                        color: hov.hovered ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.12)
                                           : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: modelData.glyph
                            color: Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }
                        HoverHandler { id: hov; cursorShape: Qt.PointingHandCursor }
                        // The middle one is "back to today", which is the only
                        // navigation anyone needs after paging six months out.
                        TapHandler {
                            onTapped: {
                                if (modelData.delta === 0) {
                                    const now = new Date();
                                    root.shownMonth = new Date(now.getFullYear(), now.getMonth(), 1);
                                    root.selectedDay = now;
                                } else {
                                    root.pageMonth(modelData.delta);
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── weekday initials ────────────────────────────────────────────────
        Row {
            width: parent.width
            Repeater {
                model: ["M", "T", "W", "T", "F", "S", "S"]
                delegate: Text {
                    required property string modelData
                    width: col.width / 7
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData
                    color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
                    font.family: Cfg.fontFamily
                    font.pointSize: Math.max(6, Cfg.fontSize * 0.7)
                    font.hintingPreference: Font.PreferFullHinting
                }
            }
        }

        // ── the grid ────────────────────────────────────────────────────────
        Grid {
            width: parent.width
            columns: 7

            Repeater {
                model: root.cells

                delegate: Item {
                    id: cell
                    required property var modelData
                    readonly property bool inMonth:
                        modelData.getMonth() === root.shownMonth.getMonth()
                    readonly property bool isToday: root.sameDay(modelData, root.today)
                    readonly property bool isSelected: root.sameDay(modelData, root.selectedDay)
                    readonly property var dayEvents: root.eventsOn(modelData)

                    width: col.width / 7
                    height: Math.round(Cfg.fontPixelSize * 1.9)

                    Rectangle {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, parent.height)
                        height: width
                        radius: width / 2
                        color: cell.isSelected ? Cfg.focusBg
                             : cell.isToday ? Qt.rgba(Cfg.focusBg.r, Cfg.focusBg.g, Cfg.focusBg.b, 0.28)
                             : dayHover.hovered ? Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.10)
                                                : "transparent"
                    }

                    Text {
                        anchors.centerIn: parent
                        text: cell.modelData.getDate()
                        // A day outside the month is context, not content, so
                        // it is dimmed rather than hidden -- an empty corner
                        // reads as a bug, and the 31st sitting next to the 1st
                        // is how you see that a week straddles a month.
                        color: cell.isSelected ? Cfg.focusFg
                             : cell.inMonth ? Cfg.fg
                                            : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.3)
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
                        font.weight: cell.isToday ? Font.DemiBold : Font.Normal
                        font.hintingPreference: Font.PreferFullHinting
                    }

                    // One dot for "something is on", not one per event. A
                    // count would be a number you cannot act on at this size,
                    // and three dots on a 24px cell is noise.
                    Rectangle {
                        visible: cell.dayEvents.length > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 1
                        width: 3
                        height: 3
                        radius: 1.5
                        color: cell.isSelected ? Cfg.focusFg
                                               : (cell.dayEvents[0].colour || Cfg.focusBg)
                    }

                    HoverHandler { id: dayHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.selectedDay = cell.modelData }
                }
            }
        }

        // ── the day ─────────────────────────────────────────────────────────
        Text {
            width: parent.width
            text: Qt.formatDate(root.selectedDay, "dddd d MMMM")
            color: Cfg.fg
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.85)
            font.weight: Font.DemiBold
            font.hintingPreference: Font.PreferFullHinting
        }

        // Everything the panel wants to say when there are no rows to show:
        // not configured, needs a login, syncing, or simply a free day. One
        // Text rather than four, because they are mutually exclusive states of
        // the same question.
        Text {
            width: parent.width
            visible: root.eventsOn(root.selectedDay).length === 0
            text: {
                if (!Calendar.configured)
                    return "No calendar account.";
                if (Calendar.needsAuth)
                    return "The calendar login has expired.";
                if (Calendar.syncing && Calendar.events.length === 0)
                    return "Syncing…";
                if (Calendar.error !== "")
                    return Calendar.error;
                return "Nothing on.";
            }
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            wrapMode: Text.WordWrap
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
            font.hintingPreference: Font.PreferFullHinting
        }

        // The way back from an expired token, in the one place the expiry is
        // reported. authorize() opens the browser and the shell finishes the
        // exchange itself -- there is no other program to run any more.
        Rectangle {
            // CalendarService.revealAuth is the testing door: the first two
            // conditions only ever come true once the login is already broken,
            // which is far too late to find out the button does not work. See
            // the note there.
            visible: Calendar.needsAuth
                     || CalendarService.revealAuth
                     || (!Calendar.configured && !Calendar.syncing)
            width: authLabel.implicitWidth + 16
            height: Math.max(20, Math.round(Cfg.fontPixelSize * 1.25))
            radius: Cfg.themeRadius
            color: authHover.hovered ? Cfg.focusBg
                                     : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.12)

            Text {
                id: authLabel
                anchors.centerIn: parent
                text: !Calendar.configured ? "Connect a calendar"
                    : Calendar.needsAuth ? "Reauthorise"
                                         : "Reauthorise (test)"
                color: authHover.hovered ? Cfg.focusFg : Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                font.hintingPreference: Font.PreferFullHinting
            }
            HoverHandler { id: authHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
                onTapped: {
                    Calendar.authorize();
                    // The browser is about to take the screen, and the panel
                    // dismisses on focus loss anyway.
                    root.closeRequested();
                }
            }
        }

        // ── the agenda ──────────────────────────────────────────────────────
        Flickable {
            width: parent.width
            visible: root.eventsOn(root.selectedDay).length > 0
            height: Math.min(agenda.implicitHeight, Cfg.calendarAgendaHeight)
            contentWidth: width
            contentHeight: agenda.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: agenda
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.eventsOn(root.selectedDay)

                    delegate: Item {
                        id: row
                        required property var modelData
                        width: agenda.width
                        height: Math.max(
                            Math.round(Cfg.fontPixelSize * 1.5),
                            title.implicitHeight + 4
                        )

                        // The calendar's own colour, as a spine. With three
                        // calendars merged into one list, which one a thing
                        // came from is most of what tells work from holidays.
                        Rectangle {
                            id: spine
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: parent.height - 4
                            radius: 1.5
                            color: row.modelData.colour || Cfg.focusBg
                        }

                        Text {
                            id: when
                            anchors.left: spine.right
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: row.modelData.allDay ? 0 : implicitWidth
                            visible: !row.modelData.allDay
                            text: Qt.formatTime(row.modelData.start, "HH:mm")
                            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                            font.family: Cfg.fontFamily
                            font.pointSize: Math.max(6, Cfg.fontSize * 0.75)
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Text {
                            id: title
                            anchors.left: row.modelData.allDay ? spine.right : when.right
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.modelData.summary || "(no title)"
                            color: Cfg.fg
                            elide: Text.ElideRight
                            font.family: Cfg.fontFamily
                            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
                            font.hintingPreference: Font.PreferFullHinting
                        }
                    }
                }
            }
        }
    }
}
