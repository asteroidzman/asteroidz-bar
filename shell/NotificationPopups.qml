// The toasts: what a notification looks like when it arrives.
//
// One of these per screen, alongside the bar. A layer-shell overlay rather
// than a popup anchored to the bell, because a notification is not a menu --
// it arrives without anybody clicking anything, it must not take the keyboard
// away from what the person is doing, and it has to be visible when the bar's
// own popover is not.
//
// `exclusiveZone: 0` is the whole reason it can be an overlay at all: it draws
// over the desktop without reserving any space, so windows do not shuffle
// sideways every time something is announced.

import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications
import QtQuick
import "."

PanelWindow {
    id: root

    required property var modelData
    screen: modelData

    // Only mapped when there is something to show. A layer surface that exists
    // with nothing in it still takes a frame and still counts as a client with
    // a surface on that output.
    visible: NotificationService.popups.length > 0

    color: "transparent"
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    // Nothing here is typed into, and taking the keyboard from a full-screen
    // application to show it a toast would be worse than not showing it.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Under the bar and against the same edge it is on, so a notification
    // appears to come out of the bell rather than from an unrelated corner.
    anchors {
        top: !Cfg.bottom
        bottom: Cfg.bottom
        right: true
    }
    margins {
        top: Cfg.bottom ? 0 : Cfg.height + Cfg.marginY * 2
        bottom: Cfg.bottom ? Cfg.height + Cfg.marginY * 2 : 0
        right: Cfg.marginX
    }

    implicitWidth: popupWidth + shadowRoom * 2
    implicitHeight: Math.max(1, stack.implicitHeight + shadowRoom * 2)

    readonly property int popupWidth: BarConfig.numOf("notify", "width", 380)
    // Room for the panel's shadow to fall outside the cards. A layer surface
    // clips to its own size, so a shadow with no margin is a shadow cut off
    // square down its edge.
    readonly property int shadowRoom:
        Cfg.panelShadow ? Cfg.panelShadowSize + Math.ceil(Cfg.panelShadowBlur) : 0

    Column {
        id: stack
        x: root.shadowRoom
        y: root.shadowRoom
        width: root.popupWidth
        spacing: 8

        Repeater {
            model: NotificationService.popups

            delegate: NotificationCard {
                required property var modelData
                notification: modelData
                width: stack.width
                onDismissed: NotificationService.dismiss(modelData)
                onExpired: NotificationService.expire(modelData)
                onActivated: act => NotificationService.invoke(act)
            }
        }
    }
}
