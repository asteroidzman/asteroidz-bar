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
// Instantiator, for the per-card blur regions below. Region is not an Item, so
// a Repeater cannot make them.
import QtQml
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
    // All zero, and in particular NOT the bar's height.
    //
    // `exclusiveZone: 0` does not mean "ignore the bar". It means this surface
    // reserves nothing of its own while still respecting what everyone else
    // reserved -- so the compositor has already placed it below the bar's
    // strip, and adding the bar's height on top of that put the toasts a
    // second bar's worth down the screen. Measured on a 1080p output whose bar
    // panel ends at y=57: the toast surface began at y=131.
    //
    // The right margin goes for the same reason it arrived: the card's own
    // inset is `Cfg.marginX` below, so putting it here as well left the toasts
    // a shadow's width further from the edge than the bar's panels, visibly
    // out of line with them.
    margins {
        top: 0
        bottom: 0
        right: 0
    }

    implicitWidth: popupWidth + shadowRoom + Cfg.marginX
    implicitHeight: Math.max(1, stack.implicitHeight + barGap + shadowRoom)

    readonly property int popupWidth: Cfg.notifyWidth
    // Room for the panel's shadow to fall outside the cards. A layer surface
    // clips to its own size, so a shadow with no margin is a shadow cut off
    // square down its edge.
    readonly property int shadowRoom:
        Cfg.panelShadow ? Cfg.panelShadowSize + Math.ceil(Cfg.panelShadowBlur) : 0

    // The side facing the bar gets the bar's own margin instead of the full
    // shadow room, which is what puts the first toast just under the bar
    // rather than a shadow's reach below it.
    //
    // The shadow on that edge is clipped, and that is the trade accepted: it
    // is the edge nearest the bar, where the bar's own shadow already falls,
    // and the alternative is a permanent 28px gap holding a shadow nobody can
    // pick out against it.
    readonly property int barGap: Math.min(shadowRoom, Cfg.marginY)

    // ── the frost ───────────────────────────────────────────────────────────
    //
    // Asked for exactly the way the bar and the popover ask: the compositor
    // blurs the region reported here, and the region carries the corner
    // RADIUS, so the blur ends where the rounded card does instead of leaving
    // square ears at its corners.
    //
    // One region per card rather than one around the stack. The cards are 8px
    // apart and the surface is taller than all of them together, so a single
    // region would frost the gaps between them and the empty space below --
    // the wallpaper has to show through there.
    //
    // Built through an Instantiator because `Region` is not an Item and a
    // Repeater cannot produce one. The Instantiator owns their lifetime, which
    // matters here: a Region outliving the card it points at is a dangling
    // item, and this list changes every time a notification arrives or goes.
    WlrLayershell.BackgroundEffect.blurRegion: Region {
        regions: {
            // An empty list is an area-less region, which the compositor reads
            // as an explicit opt-out -- see the note in Bar.qml.
            if (!Cfg.panelBlur)
                return [];
            // `count` is the dependency that rebuilds this. objectAt() is a
            // method, so nothing else here would re-evaluate when the set of
            // cards changes.
            const out = [];
            for (let i = 0; i < cardRegions.count; i++) {
                const r = cardRegions.objectAt(i);
                if (r)
                    out.push(r);
            }
            return out;
        }
    }

    Instantiator {
        id: cardRegions
        model: NotificationService.popups

        delegate: Region {
            required property int index
            // Repeater.itemAt is a method too, and the delegate for this index
            // may not exist yet when this object is built. Reading `count`
            // first makes the binding re-run once the Repeater has caught up.
            item: {
                void cards.count;
                return cards.itemAt(index);
            }
            radius: Cfg.panelRadius
        }
    }

    Column {
        id: stack
        // The shadow's room is on the left and on the far side; the near side
        // gets the bar's margin. See `barGap`.
        x: root.shadowRoom
        y: Cfg.bottom ? root.shadowRoom : root.barGap
        width: root.popupWidth
        spacing: 8

        Repeater {
            id: cards
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
