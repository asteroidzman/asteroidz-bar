// The notification centre: everything that has arrived and not been dealt
// with, in a panel under the bell.
//
// Shown through the bar's one shared popover rather than a window of its own,
// which is what makes it dismiss on the first click outside like every other
// panel here. That is also its limitation -- see the note in Popover.qml about
// the height cap -- so the list scrolls rather than growing without bound.

import Quickshell
import QtQuick
import "."

Item {
    id: root

    // Raised when the panel has done the thing it was opened for. Wired to the
    // bar's closeMenu() by whoever opens it -- this file cannot reach the bar
    // itself, because it is loaded from a Component and only that Component's
    // defining scope has `bar` in it.
    signal closeRequested()

    implicitWidth: Cfg.notifyWidth
    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        // ── the header ──────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: NotificationService.count === 0
                      ? "Notifications"
                      : "Notifications (" + NotificationService.count + ")"
                color: Cfg.fg
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSize
                font.weight: Font.DemiBold
                font.hintingPreference: Font.PreferFullHinting
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                // Do not disturb, where it is discoverable. It quiets the
                // POPUP and nothing else -- what arrives still arrives, and is
                // still here -- so the label says "quiet" rather than "off".
                Rectangle {
                    height: Math.max(24, Math.round(Cfg.fontPixelSize * 1.4))
                    width: dndLabel.implicitWidth + Math.round(Cfg.fontPixelSize * 1.2)
                    radius: Cfg.themeRadius
                    color: NotificationService.dnd ? Cfg.focusBg
                         : (dndHover.hovered ? Qt.rgba(1, 1, 1, 0.14)
                                             : Qt.rgba(1, 1, 1, 0.07))

                    Text {
                        id: dndLabel
                        anchors.centerIn: parent
                        text: "quiet"
                        color: NotificationService.dnd
                               ? Cfg.legibleOn(Cfg.focusFg, Cfg.focusBg) : Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                    HoverHandler { id: dndHover; cursorShape: Qt.PointingHandCursor }
                    // Closes after acting. Quieting is a decision, not a
                    // setting you sit and adjust -- leaving the panel up
                    // afterwards means a second click to dismiss something you
                    // are already done with.
                    TapHandler {
                        onTapped: {
                            NotificationService.toggleDnd();
                            root.closeRequested();
                        }
                    }
                }

                Rectangle {
                    visible: NotificationService.count > 0
                    height: Math.max(24, Math.round(Cfg.fontPixelSize * 1.4))
                    width: clearLabel.implicitWidth + Math.round(Cfg.fontPixelSize * 1.2)
                    radius: Cfg.themeRadius
                    color: clearHover.hovered ? Qt.rgba(1, 1, 1, 0.14)
                                              : Qt.rgba(1, 1, 1, 0.07)

                    Text {
                        id: clearLabel
                        anchors.centerIn: parent
                        text: "clear all"
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                    HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                    // And clearing empties the very list the panel exists to
                    // show, so staying open leaves you looking at "Nothing
                    // waiting."
                    TapHandler {
                        onTapped: {
                            NotificationService.clearAll();
                            root.closeRequested();
                        }
                    }
                }
            }
        }

        // ── nothing to show ─────────────────────────────────────────────────
        Text {
            width: parent.width
            visible: NotificationService.count === 0
            text: NotificationService.dnd
                  ? "Nothing waiting. Popups are quieted."
                  : "Nothing waiting."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            wrapMode: Text.WordWrap
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        // ── the list ────────────────────────────────────────────────────────
        //
        // Scrolls rather than growing: the popover caps its own height and
        // silently loses anything past the cap, so a long list has to be
        // scrollable inside a bounded box rather than a tall column.
        Flickable {
            width: parent.width
            visible: NotificationService.count > 0
            height: Math.min(rows.implicitHeight, root.maxListHeight)
            contentWidth: width
            contentHeight: rows.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: rows
                width: parent.width
                spacing: 6

                Repeater {
                    model: NotificationService.list

                    delegate: NotificationCard {
                        required property var modelData
                        notification: modelData
                        // The centre is where things WAIT. A row that expired
                        // while being read would be the opposite of a centre.
                        timed: false
                        width: rows.width
                        onDismissed: NotificationService.dismiss(modelData)
                        onActivated: act => {
                            NotificationService.invoke(act);
                            NotificationService.dismiss(modelData);
                        }
                    }
                }
            }
        }
    }

    readonly property int maxListHeight:
        Cfg.notifyCentreHeight
}
