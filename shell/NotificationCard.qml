// One notification, drawn.
//
// Shared by the toasts and the notification centre deliberately: the same
// notification looked at twice is the same notification, and two renderings of
// it would drift the first time either gained a field. `timed` is the only
// difference between the two -- a toast counts down, an entry in the centre
// waits to be dealt with.

import Quickshell
import Quickshell.Services.Notifications
import QtQuick
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

    // No shadow is drawn here.
    //
    // A toast gets one from the compositor, around the layer surface it now
    // has to itself (ToastWindow) -- the same shadow, from the same config,
    // that every window on the desktop casts. A card in the notification
    // centre never had one and still does not: it is a row inside a panel that
    // has a shadow of its own, and shadows under rows inside a shadowed panel
    // read as clutter rather than depth.

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
                font.weight: Cfg.fontWeight
                id: appLabel
                anchors.left: parent.left
                anchors.right: closeBtn.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                // Who sent it. `appName` is what the sender passed as its own
                // name; the desktop-entry hint is the fallback because an
                // application that omits appName usually still identifies
                // itself that way, and "notification" tells you nothing.
                text: {
                    const n = root.notification;
                    if (!n)
                        return "";
                    if (n.appName)
                        return n.appName;
                    if (n.desktopEntry)
                        return String(n.desktopEntry).replace(/\.desktop$/, "");
                    return "notification";
                }
                color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
                font.family: Cfg.fontFamily
                font.pointSize: Cfg.fontSizeSmall
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
                    font.weight: Cfg.fontWeight
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
            spacing: 10

            // Always something. A notification with no artwork used to draw no
            // icon at all and the text slid left to fill the space, so a
            // column of toasts had a ragged left edge and nothing identified
            // the sender at a glance -- the app's name is there, but it is the
            // smallest text on the card.
            //
            // The box is fixed and the artwork is centred in it, because
            // Icon's own width is its ADVANCE: a portrait icon is narrower
            // than `size`, which would make the text column's width depend on
            // the shape of whatever artwork happened to arrive.
            Item {
                width: root.iconSize
                height: root.iconSize

                Icon {
                    anchors.centerIn: parent
                    name: root.iconName
                    size: root.iconSize
                    // The bundled bell is a monochrome glyph and has to be
                    // painted in the theme's colours. An application's own
                    // icon carries its own, and tinting would flatten it.
                    tint: root.iconName === root.fallbackIcon
                          ? Cfg.fg : "transparent"
                }
            }

            Column {
                width: parent.width - root.iconSize - 10
                spacing: 2

                Text {
                    width: parent.width
                    visible: text !== ""
                    text: root.notification ? root.notification.summary : ""
                    color: Cfg.fg
                    elide: Text.ElideRight
                    font.family: Cfg.fontFamily
                    font.pointSize: Cfg.fontSize
                    font.weight: Cfg.fontWeightEmphasis
                    font.hintingPreference: Font.PreferFullHinting
                }

                Text {
                    font.weight: Cfg.fontWeight
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
                    // Full size, like the bar's own labels. The body IS the
                    // notification -- the summary is its title -- and it was
                    // set at 0.85, which made the one line you actually have
                    // to read the second-smallest text on the card.
                    font.pointSize: Cfg.fontSize
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
                        font.weight: Cfg.fontWeight
                        id: actLabel
                        anchors.centerIn: parent
                        text: modelData.text || modelData.identifier
                        color: Cfg.fg
                        font.family: Cfg.fontFamily
                        font.pointSize: Cfg.fontSizeSmall
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

    // ── which icon ──────────────────────────────────────────────────────────
    //
    // In the order the spec makes them available, most specific first:
    //
    //   image         the image-data or image-path hint -- artwork chosen for
    //                 THIS notification (an album cover, a contact's photo).
    //                 The server has already resolved both spellings to one
    //                 string.
    //   appIcon       the app_icon argument: a theme name or a path.
    //   desktopEntry  the desktop-entry hint, which names the application
    //                 rather than the notification, so its icon is the app's.
    //   appName       last, and only if the theme actually has it. "Discord"
    //                 finds `discord`; "notify-send" finds nothing, which is
    //                 why this is checked rather than assumed.
    //
    // Icon resolves each form (path, relative asset, theme name, URL); the
    // theme lookups are checked here because a miss has to fall through to the
    // next candidate rather than draw an empty box.
    readonly property string fallbackIcon: "asteroidz-bar/bell.svg"

    readonly property string iconName: {
        const n = notification;
        if (!n)
            return fallbackIcon;
        if (n.image)
            return n.image;
        if (n.appIcon)
            return n.appIcon;

        const names = [];
        if (n.desktopEntry)
            names.push(String(n.desktopEntry).replace(/\.desktop$/, ""));
        if (n.appName)
            names.push(String(n.appName).toLowerCase().replace(/\s+/g, "-"));
        for (const candidate of names)
            if (candidate !== "" && Quickshell.iconPath(candidate, true) !== "")
                return candidate;

        return fallbackIcon;
    }

    readonly property int iconSize: Cfg.notifyIconSize

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
