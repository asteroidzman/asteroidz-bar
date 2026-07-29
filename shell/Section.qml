// One of the three module groups, and its backing panel.
//
// Factored out of Bar.qml because the three differ only in which list they
// draw, where they anchor, and which output they are confined to -- and
// because each needed to know its own list to work out the gap before each
// module, which three copy-pasted Repeaters made easy to get subtly wrong.

import QtQuick
import "."
import "modules"

Panel {
    id: root

    property string list: ""
    property string monitorFilter: ""
    property string screenName: ""
    property var bar: null

    readonly property var names: Cfg.modules(list)

    visible: !empty && Cfg.sectionOnScreen(monitorFilter, screenName)

    // Zero, because the space between two modules is not a constant: it is
    // measured ink to ink and each module contributes its own padding to it.
    // ModuleLoader draws its own leading gap.
    spacing: 0

    // The end modules decide what the panel trims. Bound through the repeater
    // rather than computed from the names, because the reserve of a pinned
    // pill is a runtime measurement -- the clock's changes with the month.
    leadTrim: {
        for (let i = 0; i < repeater.count; i++) {
            const it = repeater.itemAt(i);
            if (it && it.visible)
                return it.leadTrim;
        }
        return 0;
    }
    trailTrim: {
        for (let i = repeater.count - 1; i >= 0; i--) {
            const it = repeater.itemAt(i);
            if (it && it.visible)
                return it.trailTrim;
        }
        return 0;
    }

    // The module before this one THAT IS ON SCREEN, which is what decides the
    // gap in front of it -- not simply the one before it in the config.
    //
    // Reading `it.visible` here is what makes this re-evaluate: a binding
    // captures every property read during its evaluation, function calls
    // included, so a module appearing or disappearing re-runs the gaps around
    // it. Without this a hidden media module still handed the clock a
    // media-sized gap, and the centre panel opened with 12px of nothing.
    function previousVisible(i) {
        for (let j = i - 1; j >= 0; j--) {
            const it = repeater.itemAt(j);
            if (it && it.visible)
                return root.names[j];
        }
        return "";
    }

    Repeater {
        id: repeater
        model: root.names

        delegate: ModuleLoader {
            required property string modelData
            required property int index

            module: modelData
            previous: root.previousVisible(index)
            screenName: root.screenName
            bar: root.bar
        }
    }
}
