// One toast, and its own layer surface.
//
// A toast is a translucent rounded card floating over the desktop, which is
// exactly the thing the compositor draws shadows for -- and the compositor
// draws them around a SURFACE (layer_draw_shadow). All the toasts used to
// share one tall surface, so the only shadow available was one drawn around
// the whole column, gaps and empty space included. One surface per toast makes
// the box that gets shadowed the box that should cast one.
//
// It also makes the surface honest about what it covers: the old one was as
// tall as every toast together plus room for a shadow to fall outside the
// cards, all of it transparent and all of it on the overlay layer.
//
// The shadow needs a `layerrule` naming this namespace -- see SectionWindow.qml
// for why an exclusion zone of 0 is not enough on its own here (the compositor
// wants `layer_shadows` or `forceshadow`, and the desktop turns layer shadows
// off globally).

import Quickshell
import Quickshell.Wayland
import QtQuick
import "."

PanelWindow {
    id: root

    required property var notification
    // How far down the stack this one sits: the heights of the toasts above
    // it, plus the gaps. Computed by NotificationPopups, which is the only
    // thing that can see all of them.
    property int stackOffset: 0

    signal dismissed()
    signal expired()
    signal activated(var action)

    WlrLayershell.namespace: "asteroidz-bar-toast"
    WlrLayershell.layer: WlrLayer.Overlay
    // Nothing here is typed into, and taking the keyboard from a full-screen
    // application to show it a toast would be worse than not showing it.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Reserves nothing, but respects what everyone else reserved -- which is
    // what puts the first toast below the bar's strip without this having to
    // know the bar's height. Adding that height on top of it once put the
    // toasts a second bar's worth down the screen.
    exclusiveZone: 0

    color: "transparent"

    // Under the bar and against the same edge it is on, so a notification
    // appears to come out of the bell rather than from an unrelated corner.
    anchors {
        top: !Cfg.bottom
        bottom: Cfg.bottom
        right: true
    }

    margins {
        top: Cfg.bottom ? 0 : Cfg.marginY + root.stackOffset
        bottom: Cfg.bottom ? Cfg.marginY + root.stackOffset : 0
        right: Cfg.marginX
    }

    implicitWidth: Cfg.notifyWidth
    implicitHeight: card.implicitHeight

    // The frost, asked for the way every other panel in the shell asks: the
    // region carries the corner radius, so the blur ends where the rounded
    // card does instead of leaving square ears at its corners. An area-less
    // region is an explicit opt-out -- see the note in SectionWindow.qml.
    WlrLayershell.BackgroundEffect.blurRegion: Region {
        item: Cfg.panelBlur ? card : null
        radius: Cfg.panelRadius
    }

    NotificationCard {
        id: card
        anchors.fill: parent
        notification: root.notification
        onDismissed: root.dismissed()
        onExpired: root.expired()
        onActivated: act => root.activated(act)
    }
}
