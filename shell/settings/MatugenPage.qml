// The palette: which Material role each generated colour comes from.
//
// One Apply for the whole page rather than per row, unlike the rule and bind
// editors. The reason is the opposite of theirs: these nine are rendered from a
// single template by a single matugen run, so applying one is applying all of
// them — a per-row Save would re-render the entire desktop nine times and mean
// exactly the same thing as one.

import QtQuick
import "."
import ".."

Item {
    id: page

    property var draft: ({})
    property bool dirty: false

    function value(key, field) {
        void Matugen.generation;
        const d = draft[key];
        if (d && d[field] !== undefined)
            return d[field];
        return Matugen.entry(key)[field];
    }

    function set(key, field, v) {
        const all = Object.assign({}, draft);
        const one = Object.assign({}, all[key] || {});
        one[field] = v;
        all[key] = one;
        draft = all;
        dirty = true;
    }

    function applyAll() {
        for (const k in draft)
            for (const f in draft[k])
                Matugen.set(k, f, draft[k][f]);
        draft = ({});
        dirty = false;
        // Wallpaper.PATH. There is no `Wallpaper.wallpaper` -- the singleton
        // calls it `path` -- and reading the wrong name yields undefined rather
        // than an error, so Apply wrote the template and then quietly skipped the
        // render. The palette test caught it by asserting matugen was invoked.
        Matugen.apply(Wallpaper.path);
    }

    Component.onCompleted: Matugen.load()

    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: Cfg.spacing

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "matugen turns the wallpaper into a Material palette and these "
                  + "nine colours are generated from it. Turning one off hands it "
                  + "back to your config, where the Appearance page can edit it."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.55)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        Text {
            width: parent.width
            visible: Matugen.status !== ""
            wrapMode: Text.WordWrap
            text: Matugen.status
            color: Matugen.statusBad ? Cfg.urgent : Cfg.focusBg
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.82)
            font.hintingPreference: Font.PreferFullHinting
        }

        Repeater {
            model: Matugen.keys

            delegate: Rectangle {
                required property var modelData
                readonly property bool owned: page.value(modelData.key, "owned")

                width: col.width
                implicitHeight: rowBody.implicitHeight + 2 * Cfg.spacing
                radius: Cfg.themeRadius
                color: Qt.rgba(1, 1, 1, 0.04)
                z: 100 - index
                required property int index

                Column {
                    id: rowBody
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Cfg.spacing
                    spacing: 2

                    Item {
                        width: parent.width
                        height: Math.max(26, Math.round(Cfg.fontPixelSize * 1.5))

                        // What the colour is right now, straight from the
                        // compositor. The point of the page is choosing a role,
                        // and a role name means nothing without the colour it
                        // currently produces beside it.
                        Rectangle {
                            id: swatch
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round(Cfg.fontPixelSize * 1.2)
                            height: width
                            radius: Cfg.themeRadius
                            color: Schema.colorOf(modelData.key, "transparent")
                            border.width: 1
                            border.color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, 0.25)
                        }

                        Text {
                            anchors.left: swatch.right
                            anchors.leftMargin: Cfg.spacing
                            anchors.right: ownToggle.left
                            anchors.rightMargin: Cfg.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: modelData.label + "   "
                                  + Schema.valueOf(modelData.key)
                            color: Cfg.fg
                            font.family: Cfg.fontFamily
                            font.pointSize: Cfg.fontSize
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Toggle {
                            id: ownToggle
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            on: parent.parent.parent.owned
                            onToggled: v => page.set(modelData.key, "owned", v)
                        }
                    }

                    // The role, and whether to drain the colour out of it.
                    Item {
                        width: parent.width
                        height: visible ? rolePicker.implicitHeight : 0
                        visible: parent.parent.owned

                        Picker {
                            id: rolePicker
                            anchors.left: parent.left
                            anchors.right: grayLabel.left
                            anchors.rightMargin: Cfg.spacing
                            maxRows: 8
                            values: Matugen.roles.length ? Matugen.roles
                                                         : [page.value(modelData.key, "role")]
                            current: page.value(modelData.key, "role")
                            onPicked: v => page.set(modelData.key, "role", v)
                        }

                        Text {
                            id: grayLabel
                            anchors.right: grayToggle.left
                            anchors.rightMargin: Cfg.spacing
                            anchors.top: parent.top
                            anchors.topMargin: Math.round(Cfg.fontPixelSize * 0.35)
                            text: "grayscale"
                            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b,
                                           Cfg.fg.a * 0.7)
                            font.family: Cfg.fontFamily
                            font.pointSize: Math.max(7, Cfg.fontSize * 0.8)
                            font.hintingPreference: Font.PreferFullHinting
                        }

                        Toggle {
                            id: grayToggle
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.topMargin: Math.round(Cfg.fontPixelSize * 0.25)
                            on: page.value(modelData.key, "gray")
                            onToggled: v => page.set(modelData.key, "gray", v)
                        }
                    }

                    Text {
                        width: parent.width
                        visible: !parent.parent.owned
                        wrapMode: Text.WordWrap
                        text: "Set by hand. This colour is left out of the "
                              + "template, so your own config decides it."
                        color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.5)
                        font.family: Cfg.fontFamily
                        font.pointSize: Math.max(7, Cfg.fontSize * 0.78)
                        font.hintingPreference: Font.PreferFullHinting
                    }
                }
            }
        }

        Item { width: 1; height: Cfg.spacing }

        Row {
            spacing: Cfg.spacing

            SmallButton {
                label: Matugen.busy ? "Applying…" : "Apply palette"
                active: page.dirty
                onClicked: if (page.dirty && !Matugen.busy) page.applyAll()
            }
            SmallButton {
                label: "Revert"
                onClicked: { page.draft = ({}); page.dirty = false; }
            }
        }

        // What Apply actually does, said before you press it.
        //
        // It is not a small action: it rewrites the template, re-runs matugen
        // against the current wallpaper, and that renders EVERY template this
        // desktop has and fires every post-hook -- waybar, kitty, the compositor
        // reload. Which is exactly what changing the wallpaper does, but a button
        // on a settings page does not look like changing the wallpaper.
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Apply rewrites the matugen template and re-renders the palette "
                  + "from the current wallpaper — the same work a wallpaper change "
                  + "does, so every other themed application reloads too. The "
                  + "previous template is kept beside it as .bak."
            color: Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.45)
            font.family: Cfg.fontFamily
            font.pointSize: Math.max(7, Cfg.fontSize * 0.78)
            font.hintingPreference: Font.PreferFullHinting
        }
    }
}
