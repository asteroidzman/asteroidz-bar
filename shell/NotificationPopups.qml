// The toasts: what a notification looks like when it arrives.
//
// One of these per screen, alongside the bar. Layer-shell overlays rather than
// a popup anchored to the bell, because a notification is not a menu -- it
// arrives without anybody clicking anything, it must not take the keyboard
// away from what the person is doing, and it has to be visible when the bar's
// own popover is not.
//
// This is a SCOPE, not a window: each toast is its own surface now (see
// ToastWindow), because the compositor shadows a surface and the toasts used
// to share one. What is left here is the part that is a property of the STACK
// rather than of any toast -- which of them are shown, and where each one sits
// under the one above it.

import Quickshell
import Quickshell.Services.Notifications
import QtQuick
// Instantiator, not Repeater: a window is not an Item, and a Repeater can only
// make Items.
import QtQml
import "."

Scope {
    id: root

    required property var modelData

    readonly property string screenName: modelData ? modelData.name : ""

    // Never over a fullscreen window. These surfaces are on the OVERLAY layer,
    // so they draw above everything including a fullscreen client -- a toast
    // across a film or a game is the one place a notification is unambiguously
    // an intrusion, and there is no way to dismiss it without leaving what you
    // are doing.
    //
    // The notification is not lost. This hides the POPUP and nothing else, so
    // it still lands in the centre and the bell still counts it: the same
    // contract quiet has.
    //
    // Per screen, because this scope is per screen. A film on one monitor
    // leaves the other one alone.
    readonly property bool shown:
        !(Cfg.notifyHideOverFullscreen && Compositor.fullscreenOn(root.screenName))

    // The gap between two toasts.
    //
    // It used to be derived from the bar's own shadow settings, because a
    // Qt-drawn shadow was painted INSIDE the shared surface and a card's shadow
    // would otherwise land twenty-odd pixels into the card below it. The
    // compositor draws its shadows outside these surfaces now and the bar has
    // no idea how far they reach -- that is `effects/shadow/size` on the
    // desktop, not a bar setting -- so this is back to being what it looks
    // like: the space between two cards.
    readonly property int gap: Math.max(8, Cfg.marginY)

    // Where toast `i` sits: everything above it, plus a gap each.
    //
    // `count` is read first because objectAt() is a method -- nothing else in
    // here would re-evaluate when a notification arrives or goes. The heights
    // are read through the surfaces themselves, which is what makes a toast
    // growing (a long body, an action row) push the ones below it down.
    function offsetFor(i) {
        void toasts.count;
        let y = 0;
        for (let j = 0; j < i; j++) {
            const w = toasts.objectAt(j);
            if (w)
                y += w.implicitHeight + root.gap;
        }
        return y;
    }

    Instantiator {
        id: toasts
        model: NotificationService.popups

        delegate: ToastWindow {
            required property var modelData
            required property int index

            screen: root.modelData
            notification: modelData
            stackOffset: root.offsetFor(index)
            visible: root.shown

            onDismissed: NotificationService.dismiss(modelData)
            onExpired: NotificationService.expire(modelData)
            onActivated: act => NotificationService.invoke(act)
        }
    }
}
