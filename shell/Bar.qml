// One output's bar.
//
// A layer-shell surface spanning the output's width, transparent, with three
// panels floating on it. The surface is full-width rather than three separate
// windows because the exclusive zone is a property of a surface: three windows
// would either reserve three overlapping strips or none at all.

import Quickshell
import Quickshell.Wayland
import QtQuick
import "."
import "modules"

PanelWindow {
    id: root

    required property var modelData
    screen: modelData
    readonly property string screenName: modelData ? modelData.name : ""

    WlrLayershell.namespace: "asteroidz-bar"
    WlrLayershell.layer: WlrLayer.Top
    // No keyboard until something asks for it. A bar that takes focus while
    // idle steals keys from whatever you were typing into, and the popovers
    // that DO need keys (phase 4) can raise this per-window.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        top: !Cfg.bottom
        bottom: Cfg.bottom
        left: true
        right: true
    }

    implicitHeight: Cfg.height + 2 * Cfg.marginY
    // Windows are kept clear of the bar AND of the gap it floats in: the
    // margin is part of the bar's footprint, not free space a maximised window
    // may use, or the panel would sit on top of window content.
    exclusiveZone: Cfg.height + 2 * Cfg.marginY

    color: "transparent"

    // The frosted look, preserved across the move out of the compositor.
    //
    // scenefx blurs what is behind a layer surface, and asteroidz will mask
    // that by the surface's own alpha -- but the region below is better than a
    // mask: it carries the panels' CORNER RADII, so the blur ends exactly
    // where the rounded slab does instead of leaving square ears at the
    // corners. Only non-empty sections contribute, so the gaps between groups
    // stay genuinely transparent.
    WlrLayershell.BackgroundEffect.blurRegion: Region {
        regions: [
            Region {
                item: leftPanel
                radius: Cfg.panelRadius
            },
            Region {
                item: centerPanel
                radius: Cfg.panelRadius
            },
            Region {
                item: rightPanel
                radius: Cfg.panelRadius
            }
        ]
    }

    // The strip itself: exactly `height` tall, `margin_y` from the screen
    // edge it is anchored to.
    //
    // NOT the whole surface. The surface is height + 2*margin tall because
    // that is what the compositor reserves (bar_reserve: `height + 2 *
    // margin_y`) -- the second margin is breathing room below the bar, not
    // part of it. Filling the surface and centring the panels inside it put
    // them 4.5px low, which is the sort of error that looks like nothing and
    // fails a pixel diff.
    Item {
        height: Cfg.height
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: Cfg.bottom ? undefined : parent.top
        anchors.bottom: Cfg.bottom ? parent.bottom : undefined
        anchors.topMargin: Cfg.bottom ? 0 : Cfg.marginY
        anchors.bottomMargin: Cfg.bottom ? Cfg.marginY : 0
        anchors.leftMargin: Cfg.marginX
        anchors.rightMargin: Cfg.marginX

        Panel {
            id: leftPanel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: !empty && Cfg.sectionOnScreen(Cfg.leftMonitor, root.screenName)

            Repeater {
                model: Cfg.modules(Cfg.modulesLeft)
                delegate: ModuleLoader {
                    required property string modelData
                    module: modelData
                    screenName: root.screenName
                }
            }
        }

        Panel {
            id: centerPanel
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            visible: !empty && Cfg.sectionOnScreen(Cfg.centerMonitor, root.screenName)

            Repeater {
                model: Cfg.modules(Cfg.modulesCenter)
                delegate: ModuleLoader {
                    required property string modelData
                    module: modelData
                    screenName: root.screenName
                }
            }
        }

        Panel {
            id: rightPanel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !empty && Cfg.sectionOnScreen(Cfg.rightMonitor, root.screenName)

            Repeater {
                model: Cfg.modules(Cfg.modulesRight)
                delegate: ModuleLoader {
                    required property string modelData
                    module: modelData
                    screenName: root.screenName
                }
            }
        }
    }
}
