// The tag pills.
//
// Not one pill: a row of them, one per visible tag, which is why this is a Row
// of Pills rather than a Pill. Which tags are visible, how they are labelled
// and how they are tinted all live in Compositor.visibleTags() so that the
// rules stay in one place and read the same as bar_module_refresh_tags().
//
// The looks come from bar_pill_style(): an active tag takes the theme's focus
// pair, urgent takes the urgent colour with a foreground chosen to be readable
// ON it, an occupied tag is a soft black wash and an empty one is a barely
// there white. Those last two are literals in the compositor too -- they are
// tints applied over whatever the panel is, not theme colours.

import QtQuick
import ".."

Row {
    id: root

    property string screenName: ""
    spacing: Cfg.spacing

    // A run of chips: the trims are the outermost pill's, and a chip trims
    // nothing (its background IS the edge you see).
    readonly property int leadTrim: 0
    readonly property int trailTrim: 0

    // The asteroidz ship, leading the group.
    Pill {
        visible: Cfg.showLogo
        // Recoloured at runtime so the exhaust burns in the theme's accent --
        // see Logo.qml, and the note in the SVG itself.
        icons: [Logo.source]
        // No horizontal padding at all. A tag's padding is room for a number
        // to sit in; this pill draws no background of its own, so its padding
        // is not a margin around anything -- it is just empty bar. The gap to
        // the first tag comes from the row's spacing either way.
        paddingX: 0
        // ...and the artwork itself was small in the middle of all that. This
        // fills the chip the way a logo should.
        iconScale: 1.25
        chip: true
        interactive: false
    }

    Repeater {
        model: {
            void Compositor.generation;
            return Compositor.visibleTags(root.screenName);
        }

        delegate: Pill {
            required property var modelData

            text: modelData.label
            icons: modelData.icons
            iconsAfterText: true
            paddingX: Cfg.tagPadding
            chip: true

            // An urgent colour is chosen to read against the BAR, so it
            // cannot also be constrained to contrast with its own label --
            // the label gives. Cfg.readableOn is that rule, shared now with
            // the plugin pills, which had no version of it at all.
            fg: modelData.active ? Cfg.focusFg
              : modelData.urgent ? Cfg.readableOn(Cfg.urgent)
              : modelData.occupied ? Cfg.fg
              : Qt.rgba(Cfg.fg.r, Cfg.fg.g, Cfg.fg.b, Cfg.fg.a * 0.35)

            bg: modelData.active ? Cfg.focusBg
              : modelData.urgent ? Cfg.urgent
              : modelData.occupied ? Qt.rgba(0, 0, 0, 0.44)
              : Qt.rgba(1, 1, 1, 0.06)

            // `view` acts on the FOCUSED output, so clicking a tag on any
            // other one has to move focus there first or the click switches
            // tags on the wrong screen. The native module does the same thing
            // by hand (bar.h: "view acts on selmon, so clicking a tag on an
            // unfocused output has to move focus there first"); from out here
            // it is one more dispatch.
            onClicked: button => {
                if (root.screenName !== "" &&
                    Compositor.focusedMonitor !== root.screenName)
                    Ipc.dispatch("dispatch focus_monitor," + root.screenName);

                if (button === Qt.LeftButton)
                    Ipc.dispatch("dispatch view," + modelData.index);
                else if (button === Qt.RightButton)
                    Ipc.dispatch("dispatch toggle_view," + modelData.index);
            }
        }
    }
}
