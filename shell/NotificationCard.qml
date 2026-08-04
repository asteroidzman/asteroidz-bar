// One notification, drawn.
//
// Shared by the toasts and the notification centre deliberately: the same
// notification looked at twice is the same notification, and two renderings of
// it would drift the first time either gained a field. `timed` is the only
// difference between the two -- a toast counts down, an entry in the centre
// waits to be dealt with.

import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications
import QtQuick
import Qt5Compat.GraphicalEffects
import "."

Rectangle {
    id: root

    property var notification: null
    // A toast expires on its own; a row in the centre does not.
    property bool timed: true

    signal dismissed()
    signal expired()
    signal activated(var action)

    readonly property bool critical:
        notification && notification.urgency === NotificationUrgency.Critical

    implicitHeight: content.implicitHeight + Cfg.panelPadding * 2
    radius: Cfg.panelRadius
    color: Cfg.panelColor

    // Critical is the one urgency the spec reserves for something that has
    // gone wrong, so it is the one that gets a border. Colour alone would be
    // the whole card, which is unreadable against a themed palette.
    border.width: critical ? 1 : 0
    border.color: Cfg.urgent

    // ── the shadow ──────────────────────────────────────────────────────────
    //
    // The same geometry Panel.qml draws for the bar's slab, because this is
    // the same object: a translucent rounded panel floating over the
    // wallpaper. NotificationPopups already reserved the margin for it -- see
    // `shadowRoom` there -- and then nothing drew one, so the toasts sat flat
    // on the desktop while every other panel in the shell had depth.
    //
    // Only in the toasts. A card in the centre is a row inside a panel that
    // has a shadow of its own, and shadows under rows inside a shadowed panel
    // read as clutter rather than depth.
    //
    // See Panel.qml for why RectangularGlow rather than MultiEffect, why
    // `spread` is 0, and why the alpha is halved -- the reasoning is identical
    // and is not repeated here.
    RectangularGlow {
        readonly property int delta: Cfg.panelShadowSize
        readonly property int reach: delta + Math.ceil(Cfg.panelShadowBlur * 2)

        anchors.centerIn: parent
        width: root.width
        height: root.height
        anchors.verticalCenterOffset: Math.round(delta / 3)

        cornerRadius: Cfg.panelRadius + delta
        glowRadius: reach
        spread: 0
        color: Qt.rgba(Cfg.panelShadowColor.r, Cfg.panelShadowColor.g,
                       Cfg.panelShadowColor.b, Cfg.panelShadowColor.a * 0.5)
        visible: root.timed && Cfg.panelShadow && Cfg.panelEnable
        z: -1
    }

    // The countdown. Restarted whenever the notification changes, so a card
    // reused by the Repeater for a different notification does not inherit the
    // remains of the previous one's clock.
    Timer {
        id: life
        interval: NotificationService.timeoutFor(root.notification)
        // 0 means "until dismissed" per the spec, and that is a real answer
        // rather than a missing one -- a failed backup should still be there
        // when you come back to the desk.
        running: root.timed && root.notification !== null && interval > 0
        onTriggered: root.expired()
    }

    Connections {
        target: root
        function onNotificationChanged() { life.restart(); }
    }

    // Hovering holds it. Reading something is the clearest possible signal
    // that it should not be taken away mid-sentence.
    HoverHandler {
        id: hover
        onHoveredChanged: {
            if (!root.timed)
                return;
            if (hovered)
                life.stop();
            else
                life.restart();
        }
    }

    Column {
        id: content
        x: Cfg.panelPadding
        y: Cfg.panelPadding
        width: parent.width - Cfg.panelPadding * 2
        spacing: 4

        // ── who sent it, and the way out ────────────────────────────────────
        Item {
            width: parent.width
            height: Math.max(appLabel.implicitHeight, closeBtn.height)

            Text {
                id: appLabel
                anchors.left: parent.left
                anchors.right: closeBtn.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: root.notification ? (root.notification.appName || "notification") : ""
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                font.family: Cfg.fontFamily
                font.pointSize: Math.max(7, Cfg.fontSize * 0.72)
                font.hintingPreference: Font.PreferFullHinting
            }

            Rectangle {
                id: closeBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Math.round(Cfg.fontPixelSize * 1.1)
                height: width
                radius: width / 2
                color: closeHover.hovered ? Qt.rgba(1, 1, 1, 0.16) : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: "×"
                    color: Cfg.fg
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                }
                HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.dismissed() }
            }
        }

        // ── the image the sender supplied ───────────────────────────────────
        //
        // `image` covers both an image-data hint and an icon path; the server
        // resolves them to one string, so there is one thing to draw rather
        // than a branch per hint the spec has accumulated.
        Row {
            width: parent.width
            spacing: root.hasImage ? 10 : 0

            IconImage {
                visible: root.hasImage
                width: visible ? 40 : 0
                height: 40
                source: root.hasImage ? root.imageSource : ""
            }

            Column {
                width: parent.width - (root.hasImage ? 50 : 0)
                spacing: 2

                Text {
                    width: parent.width
                    visible: text !== ""
                    text: root.notification ? root.notification.summary : ""
                    color: Cfg.fg
                    elide: Text.ElideRight
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.weight: Font.DemiBold
                    font.hintingPreference: Font.PreferFullHinting
                }

                Text {
                    width: parent.width
                    visible: text !== ""
                    text: root.notification ? root.notification.body : ""
                    color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.8)
                    wrapMode: Text.WordWrap
                    maximumLineCount: root.timed ? 4 : 12
                    elide: Text.ElideRight
                    // The server claims body-markup, so this has to render it.
                    // Claiming it and then showing the tags is how `<b>` ends
                    // up in front of somebody.
                    textFormat: Text.StyledText
                    font.family: Cfg.fontFamily
                    font.pointSize: Math.max(7, Cfg.fontSize * 0.85)
                    font.hintingPreference: Font.PreferFullHinting
                }
            }
        }

        // ── whatever the sender offered to do ───────────────────────────────
        Flow {
            width: parent.width
            spacing: 6
            visible: root.actionList.length > 0

            Repeater {
                model: root.actionList

                delegate: Rectangle {
                    required property var modelData
                    height: Math.max(24, Math.round(Cfg.fontPixelSize * 1.4))
                    width: actLabel.implicitWidth + Math.round(Cfg.fontPixelSize * 1.2)
                    radius: Cfg.themeRadius
                    color: actHover.hovered ? Qt.rgba(1, 1, 1, 0.14)
                                            : Qt.rgba(1, 1, 1, 0.07)

                    Text {
                        id: actLabel
                        anchors.centerIn: parent
                        text: modelData.text || modelData.identifier
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                    HoverHandler { id: actHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.activated(modelData) }
                }
            }
        }
    }

    // `default` is the action a click on the body invokes, by convention, and
    // it is not meant to be drawn as a button -- so it is filtered out of the
    // row above and handled by the tap below.
    readonly property var actionList: {
        if (!notification || !notification.actions)
            return [];
        return notification.actions.filter(a => a && a.identifier !== "default");
    }

    readonly property bool hasDefaultAction: {
        if (!notification || !notification.actions)
            return false;
        return notification.actions.some(a => a && a.identifier === "default");
    }

    readonly property string imageSource:
        notification && notification.image ? notification.image
        : (notification && notification.appIcon ? notification.appIcon : "")
    readonly property bool hasImage: imageSource !== ""

    // Clicking the card runs the default action if there is one. Nothing at
    // all if there is not -- a click that silently dismissed would lose
    // whatever the person was about to read.
    TapHandler {
        enabled: root.hasDefaultAction
        onTapped: {
            for (const a of root.notification.actions)
                if (a && a.identifier === "default") {
                    root.activated(a);
                    return;
                }
        }
    }
}
