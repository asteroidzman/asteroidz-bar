// Name -> module, the way `modules-left "tags,layout,title"` means it.
//
// A Loader rather than a switch that builds everything and hides the unused:
// a module is a process's worth of work (a socket, a timer, a subscription),
// and the whole point of the config listing them is that the ones you did not
// list cost nothing.
//
// The leading gap lives here rather than in the panel's Row, because it is not
// a constant: the space between two modules is measured ink to ink, so it
// depends on what is on either side of it. A Row has one spacing for every
// child, which is exactly the "constant box gap, inconsistent visible gap"
// the native bar goes out of its way to avoid.
//
// An unknown name loads nothing and says so once. The native bar warns and
// carries on for the same reason -- a typo in one module name should not cost
// you the other eleven.

import QtQuick
import "."
import ".."

Row {
    id: root

    property string module: ""
    property string previous: ""
    property string screenName: ""
    property var bar: null

    // `custom/<name>` is a plugin. Phase 5; recognised here so the name does
    // not warn as unknown in the meantime.
    readonly property bool isCustom: module.startsWith("custom/")

    visible: loader.status === Loader.Ready
    spacing: 0

    // Forwarded from the loaded module so the panel can trim its ends. A
    // module that does not say gets the kind's own padding, which is what a
    // single unpinned pill would have reported anyway.
    readonly property int leadTrim: loader.item && loader.item.leadTrim !== undefined
        ? loader.item.leadTrim : Cfg.inkInset(module)
    readonly property int trailTrim: loader.item && loader.item.trailTrim !== undefined
        ? loader.item.trailTrim : Cfg.inkInset(module)

    Item {
        width: Cfg.moduleGap(root.previous, root.module)
        height: 1
    }

    Loader {
        id: loader
        active: !root.isCustom

        sourceComponent: {
            switch (root.module) {
            case "clock":
                return clockComponent;
            case "tags":
                return tagsComponent;
            case "layout":
                return layoutComponent;
            case "title":
                return titleComponent;
            case "cpu":
            case "memory":
                return metricComponent;
            case "network":
                return networkComponent;
            case "volume":
                return volumeComponent;
            case "idle":
                return idleComponent;
            case "notify":
                return notifyComponent;
            case "weather":
                return weatherComponent;
            case "media":
                return mediaComponent;
            case "tray":
                return trayComponent;
            default:
                return null;
            }
        }
    }

    Component {
        id: clockComponent
        Clock {}
    }

    Component {
        id: tagsComponent
        Tags { screenName: root.screenName }
    }

    Component {
        id: layoutComponent
        Layout { screenName: root.screenName }
    }

    Component {
        id: titleComponent
        Title { screenName: root.screenName }
    }

    Component {
        id: metricComponent
        Metric { kind: root.module }
    }

    Component {
        id: networkComponent
        Network {}
    }

    Component {
        id: volumeComponent
        Volume {}
    }

    Component {
        id: idleComponent
        Idle {}
    }

    Component {
        id: notifyComponent
        Notify {}
    }

    Component {
        id: weatherComponent
        Weather {}
    }

    Component {
        id: mediaComponent
        Media {}
    }

    Component {
        id: trayComponent
        Tray { bar: root.bar }
    }

    Component.onCompleted: {
        if (!isCustom && loader.sourceComponent === null)
            console.warn("asteroidz-bar: unknown module:", module);
    }
}
