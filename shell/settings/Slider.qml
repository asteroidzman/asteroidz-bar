// A bounded number, dragged.
//
// Written rather than taken from QtQuick.Controls for the same reason Toggle and
// Picker are: Controls brings a style with its own palette and its own metrics,
// and every other control in this shell is drawn from Cfg. One Controls widget
// in the middle of them is visibly a different application.
//
// Only for options the schema gives BOTH bounds for. A slider needs a range to
// be a slider at all, and inventing one -- "0 to 100 looks about right" -- would
// silently cap a value the compositor accepts, which is the same class of bug as
// a UI that clamps and does not say so. The nine unbounded numbers get a text
// field instead; see OptionRow.

import QtQuick
import ".."

Item {
    id: root

    property real from: 0
    property real to: 100

    // What the knob is drawn at. Assigned by the drag, so it must NOT be bound to
    // anything from outside -- the first assignment would break that binding and
    // the slider would stop tracking the value it is supposed to be showing.
    property real value: 0

    // The value from outside. Copied into `value` when it changes, and never
    // while the knob is being dragged: an external update mid-gesture would yank
    // the handle out from under the pointer, and a preview echoed back from the
    // compositor is exactly such an update.
    property real target: 0
    onTargetChanged: if (!drag.active) value = target
    Component.onCompleted: value = target
    // 0 for an integer option, else the granularity of the drag. Floats get a
    // sensible fraction of their range rather than a fixed 0.01: `0 .. 1` and
    // `0 .. 4096` are both float ranges here and one step cannot serve both.
    property real stepSize: 0
    property int decimals: 0

    // Continuous, for the readout and for a throttled preview upstream.
    signal moved(real v)
    // The drag ended. One of these is worth persisting; a hundred `moved` are
    // not.
    signal released(real v)

    readonly property int barHeight: 6
    readonly property int knob: Math.max(14, Math.round(Cfg.fontPixelSize * 0.8))
    implicitHeight: Math.max(24, Math.round(Cfg.fontPixelSize * 1.35))

    // Room for the readout, which is right-aligned and sized to the widest
    // string the range can produce -- not to the CURRENT string, or the track
    // would change length as you drag it and the knob would slide out from
    // under the pointer.
    TextMetrics {
        id: widest
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        text: root.fmt(root.to).length >= root.fmt(root.from).length
            ? root.fmt(root.to) : root.fmt(root.from)
    }

    function fmt(v) {
        return decimals > 0 ? v.toFixed(decimals) : String(Math.round(v));
    }

    function clampv(v) {
        const lo = Math.min(from, to);
        const hi = Math.max(from, to);
        v = Math.max(lo, Math.min(hi, v));
        if (stepSize > 0)
            v = lo + Math.round((v - lo) / stepSize) * stepSize;
        // Rounding to the step can land a hair outside after floating-point
        // arithmetic, and a value one ulp over the maximum is rejected by the
        // compositor with out-of-range -- an Apply that fails for a slider you
        // dragged to the end.
        return Math.max(lo, Math.min(hi, v));
    }

    Item {
        id: track
        anchors.left: parent.left
        anchors.right: readout.left
        anchors.rightMargin: Cfg.spacing
        anchors.verticalCenter: parent.verticalCenter
        height: root.knob
        opacity: root.enabled ? 1.0 : 0.4

        readonly property real span: Math.max(1, Math.abs(root.to - root.from))
        readonly property real frac:
            Math.max(0, Math.min(1, (root.value - Math.min(root.from, root.to))
                                    / span))
        readonly property real travel: Math.max(1, width - root.knob)

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: root.barHeight
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.10)
        }

        // The filled part. Reaching to the knob's CENTRE rather than its left
        // edge, so the fill and the knob read as one object at both ends
        // instead of leaving a gap at zero.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: track.frac * track.travel + root.knob / 2
            height: root.barHeight
            radius: height / 2
            color: Cfg.focusBg
        }

        Rectangle {
            id: handle
            width: root.knob
            height: root.knob
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            x: track.frac * track.travel
            color: Cfg.fg
            border.width: drag.active || hover.hovered ? 2 : 0
            border.color: Cfg.focusBg
        }

        // No `enabled` passthrough: an input handler is inert while its item is
        // disabled, and Item.enabled propagates from the root of this component.
        HoverHandler { id: hover }

        // Drag on the WHOLE track, not on the handle: a 14px circle is a hard
        // target, and every slider in every toolkit lets you grab the bar.
        DragHandler {
            id: drag
            target: null
            onCentroidChanged: if (active) root.seek(centroid.position.x)
            onActiveChanged: if (!active) root.released(root.value)
        }

        // A tap jumps there. Same arithmetic, so a tap at the far right lands
        // exactly on the maximum rather than one step short of it.
        TapHandler {
            onTapped: eventPoint => {
                root.seek(eventPoint.position.x);
                root.released(root.value);
            }
        }
    }

    function seek(px) {
        const f = Math.max(0, Math.min(1, (px - knob / 2) / track.travel));
        const lo = Math.min(from, to);
        const v = clampv(lo + f * Math.abs(to - from));
        if (v !== value) {
            value = v;
            moved(v);
        }
    }

    Text {
        id: readout
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Math.ceil(widest.width) + 2
        horizontalAlignment: Text.AlignRight
        text: root.fmt(root.value)
        color: Cfg.fg
        opacity: root.enabled ? 1.0 : 0.4
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
    }
}
