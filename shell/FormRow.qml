// A labelled control, at a fixed label width so a column of them lines up.
import QtQuick
import "."

Item {
    id: root
    property string label: ""
    property Item control: null
    // Wide enough for the longest label at whatever size the theme is using.
    readonly property int labelWidth: Math.round(Cfg.fontPixelSize * 8)

    // Tall enough for its control, not a constant: a Picker with its list open
    // is taller than a row, and a fixed 28 would have the list drawn over
    // whatever setting comes next instead of pushing it down.
    readonly property int rowHeight: Math.max(28, Math.round(Cfg.fontPixelSize * 1.6))
    implicitHeight: Math.max(rowHeight, control ? control.implicitHeight + 4 : 0)
    visible: true

    onControlChanged: if (control) {
        control.parent = root;
        control.anchors.left = undefined;
        control.x = Qt.binding(() => root.labelWidth);
        // Pinned to the TOP once the control is taller than a row: a control
        // that grows downwards (a list opening) must not drift upwards as it
        // does, or the thing under the pointer moves out from under it.
        control.y = Qt.binding(() => control.implicitHeight > root.rowHeight
            ? 2 : (root.height - control.height) / 2);
        // Stretched only if it has no width of its own.
        //
        // Filling was unconditional, which is right for a Picker or a text
        // field -- they are as wide as the row allows and nothing about their
        // content decides otherwise -- and wrong for a switch. A Toggle is 44px
        // of switch, and stretching it gave VRR and HDR a control as wide as the
        // whole section: it read as a bar rather than as the small thing you
        // flip, and it put the hit target as far from its label as the row is
        // wide.
        //
        // Decided by the CONTROL rather than by a flag at each call site.
        // Toggle declares implicitWidth: 44 and Picker and Field declare none,
        // so "has a natural width" is already the distinction, and a row added
        // later has nothing to remember to set.
        control.width = Qt.binding(() => {
            const avail = root.width - root.labelWidth;
            return control.implicitWidth > 0
                ? Math.min(control.implicitWidth, avail)
                : avail;
        });
    }

    Text {
        font.weight: Cfg.fontWeight
        anchors.left: parent.left
        // Level with the control, on the control's terms: once a Picker opens
        // its list the row is several times a row tall, and a label centred in
        // THAT sits halfway down the open list with nothing beside it.
        y: root.control && root.control.implicitHeight > root.rowHeight
            ? Math.round((root.rowHeight - height) / 2)
            : Math.round((root.height - height) / 2)
        // Stops at the label column. labelWidth is generous but it is still a
        // fixed reservation, and a label that outgrows it used to run straight
        // under the control sitting at x == labelWidth.
        width: Math.min(implicitWidth, root.labelWidth - 8)
        elide: Text.ElideRight
        text: root.label
        color: Cfg.fg
        font.family: Cfg.fontFamily
        font.pointSize: Cfg.fontSize
        font.hintingPreference: Font.PreferFullHinting
    }
}
