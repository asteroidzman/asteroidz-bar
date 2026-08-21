// One module group's own layer surface.
//
// The three groups used to be three items inside one full-width surface. They
// are three SURFACES now, and the reason is the shadow: asteroidz draws a layer
// shadow around the surface's own box (layer_draw_shadow in animation/layer.h),
// so sharing one surface means one shadow drawn around the whole strip --
// around the transparent gaps between the groups as well as the groups. A slab
// that should cast a shadow needs to BE a surface for the compositor to have
// anything to cast it from.
//
// What that buys, beyond deleting the bar's own approximation of a shadow:
// the mask is the surface (a click in the gap between two groups is not this
// surface's to swallow), the blur region is the surface, and the shadow is the
// same code path, with the same parameters, that shadows every window on the
// desktop -- so the bar tracks `effects/shadow` in the compositor's config
// instead of describing a shadow of its own that had to be kept in step by
// hand.
//
// The compositor only shadows a layer surface it has been told to: the rule is
// `(exclusive_zone == 0 || forceshadow) && !noshadow`, and these reserve
// nothing while sitting INSIDE the strip the bar reserves, which is
// exclusion-zone -1 rather than 0. So a `layerrule` naming this namespace is
// what turns the shadow on -- see README, and contrib/lib/barconf.sh, which
// writes one for the tests.

import Quickshell
import Quickshell.Wayland
import QtQuick
import "."

PanelWindow {
    id: root

    // Which end of the bar this is: "left", "center" or "right".
    required property string place
    required property var bar
    property alias section: section

    WlrLayershell.namespace: "asteroidz-bar-panel"
    WlrLayershell.layer: WlrLayer.Top
    // Never. The popover is its own surface and takes the keyboard itself; a
    // panel is pointer-only, and a bar that takes focus while idle steals keys
    // from whatever you were typing into.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Reserve nothing, and ignore what others reserve.
    //
    // The strip these sit in is reserved once, by the bar's own surface. A
    // second surface reserving the same band would push windows down twice; a
    // surface merely reserving NOTHING (zone 0) would still be positioned
    // clear of the band the bar reserves, which puts the panels underneath the
    // bar instead of in it. Ignore is the only mode that means "place me where
    // I ask, and take no space" -- and it is why these need a forceshadow rule
    // rather than getting a shadow from the zone == 0 default.
    exclusionMode: ExclusionMode.Ignore

    // No surface for a place the config puts nothing in -- and decided from
    // the CONFIG, never from what is inside this window.
    //
    // `visible: section.visible` is the obvious binding and it is a trap. The
    // section is a CHILD of this window, so unmapping the window is what
    // decides whether the section is ever in a position to say it wants to
    // come back. One module failing to load emptied its section, the window
    // unmapped, and it never returned -- restoring a working module did not
    // bring it back, because nothing inside an unmapped window was being
    // asked. With all three sections in that state the entire bar was gone,
    // the shell still running and nothing in the log to say so.
    //
    // ModuleLoader.wantsShown and Section.empty are both written the awkward
    // way they are to dodge this same latch one level down -- "a module with
    // nothing to show must not report that through `visible`, because an
    // ancestor can switch that off". A surface is the same hazard again, and
    // worse, because a surface that is gone takes its own evidence with it.
    //
    // What this gives up: a section configured with modules that ALL hide
    // themselves keeps a surface, where a section configured with nothing at
    // all has none. That surface is a sliver -- see implicitWidth -- and a
    // sliver is a far better failure than a bar that disappears.
    visible: BarConfig.itemsOf(root.place).length > 0
        && Cfg.sectionOnScreen(BarConfig.monitorOf(root.place),
                               root.bar ? root.bar.screenName : "")

    color: "transparent"

    anchors {
        top: !Cfg.bottom
        bottom: Cfg.bottom
        left: root.place === "left"
        right: root.place === "right"
    }

    margins {
        top: Cfg.bottom ? 0 : Cfg.marginY
        bottom: Cfg.bottom ? Cfg.marginY : 0
        left: root.place === "left" ? Cfg.marginX : 0
        right: root.place === "right" ? Cfg.marginX : 0
    }

    // Never zero. A layer surface committed at zero size is a protocol error,
    // and a section whose modules have all hidden themselves measures exactly
    // that -- a Row lays out only the children that are effectively visible.
    // One pixel is the smallest thing that is still a surface.
    implicitWidth: Math.max(1, section.implicitWidth)
    implicitHeight: Math.max(1, section.implicitHeight)

    // Where this surface sits on the output, in the output's own coordinates.
    //
    // Needed because the popover is a surface too and has to be placed under
    // the pill that opened it, which is an item in THIS surface: the pill's
    // position is surface-local, and only this knows what to add to it. The
    // centre panel is the one case the compositor decides (a layer surface
    // anchored to neither side is centred), so the same arithmetic is repeated
    // here rather than read back from anywhere.
    readonly property int originX:
        root.place === "left" ? Cfg.marginX
        : root.place === "right"
            ? (root.screen ? root.screen.width : 0) - Cfg.marginX - root.width
            : Math.round(((root.screen ? root.screen.width : 0) - root.width) / 2)

    readonly property int originY: Cfg.bottom
        ? (root.screen ? root.screen.height : 0) - Cfg.marginY - root.height
        : Cfg.marginY

    // The frost. Asked for with the panel's corner radius so the blur ends
    // exactly where the rounded slab does, and expressed as a region with no
    // area when it is off: the compositor reads an empty client region as an
    // explicit opt-out and a missing one as "fall back to the global
    // effects/blur/layer", which would leave `panel { blur #false }` unable to
    // turn the frost off on a desktop that has layer blur on.
    // Keyed on `visible` as well as the setting, so the region is re-sent when
    // the surface maps. These are built at startup and map later -- a section
    // is empty until its modules have loaded -- unlike the popover and the
    // toasts, which are created already-populated and get their region once,
    // late, with nothing to race.
    WlrLayershell.BackgroundEffect.blurRegion: Region {
        item: (Cfg.panelBlur && root.visible) ? section : null
        radius: Cfg.panelRadius
    }

    Section {
        id: section
        anchors.fill: parent
        bar: root.bar
        list: BarConfig.itemsOf(root.place).join(",")
        monitorFilter: BarConfig.monitorOf(root.place)
        screenName: root.bar ? root.bar.screenName : ""
    }
}
