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

    readonly property bool isCustom: module.startsWith("custom/")
    readonly property string customName:
        isCustom ? module.slice("custom/".length) : ""

    // The `custom "<name>" { }` block, matched by name out of what the
    // compositor served. A name with no block is a typo in modules-* and
    // loads nothing.
    readonly property var plugin: {
        for (const c of Cfg.custom)
            if (c.name === customName)
                return c;
        return null;
    }

    // A module that has nothing to show takes NO space, including the gap
    // before it.
    //
    // The Loader being Ready is not the same as the module being on screen:
    // Media hides itself when no player exists, but a Loader still reports the
    // width of the item it holds, so an idle media module reserved 390px --
    // its transport controls, its pinned title and its visualiser -- inside a
    // centre panel that then drew as a slab three times wider than the clock
    // sitting at the right-hand end of it.
    //
    // The module answers with `shown`, NOT with `visible`. Item.visible is
    // effective visibility -- it is false whenever an ancestor is hidden -- so
    // hiding this slot would make the module report itself hidden, which would
    // keep the slot hidden: every module on the bar disappeared at once, and
    // stayed gone. A module with no opinion is shown.
    visible: loader.status === Loader.Ready
             && (loader.item === null || loader.item.shown !== false)
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
        active: !root.isCustom || root.plugin !== null

        sourceComponent: {
            if (root.isCustom)
                return root.plugin ? customComponent : null;
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
            case "display":
                return displayComponent;
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
        Metric { kind: root.module; bar: root.bar }
    }

    Component {
        id: networkComponent
        Network { bar: root.bar }
    }

    Component {
        id: volumeComponent
        Volume { bar: root.bar }
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
        Weather { bar: root.bar }
    }

    Component {
        id: mediaComponent
        Media {}
    }

    Component {
        id: trayComponent
        Tray { bar: root.bar }
    }

    Component {
        id: displayComponent
        Display { bar: root.bar }
    }

    Component {
        id: customComponent
        Custom { plugin: root.plugin; bar: root.bar }
    }

    // Warned about only once the config has actually ARRIVED.
    //
    // Component.onCompleted runs while the bar is being built, which is before
    // the compositor has answered `watch bar-config` -- so every plugin was
    // reported missing at startup and then loaded a moment later, which is the
    // worst kind of log line: alarming and wrong.
    property bool complained: false

    function checkName() {
        if (complained || !Cfg.loaded)
            return;
        if (isCustom && !plugin) {
            console.warn("asteroidz-bar: no custom block named", customName);
            complained = true;
        } else if (!isCustom && loader.sourceComponent === null) {
            console.warn("asteroidz-bar: unknown module:", module);
            complained = true;
        }
    }

    Component.onCompleted: checkName()
    Connections {
        target: Cfg
        function onLoadedChanged() { root.checkName(); }
        function onCustomChanged() { root.checkName(); }
    }
}
