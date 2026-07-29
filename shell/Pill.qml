// One module's tile.
//
// The native bar draws a pill as a single scene node: rounded rect, optional
// artwork, one Pango line. That is deliberate -- hit testing is per node, so
// nothing is drawn that cannot be clicked -- and it is worth keeping even
// though a QML item could hold arbitrary sub-widgets. A pill is one target.
//
// Geometry mirrors bar.h exactly: the pill is inset vertically inside the
// panel (`pill-inset`, 6px of a 48px bar => 36px pills), padded horizontally
// by `pill-padding`, and floored at `pill-min-width` so a single glyph does
// not produce a sliver.

import QtQuick
import "."

Item {
    id: root

    property string text: ""
    // Artwork names, resolved by Icon: asset paths or icon-theme names.
    property var icons: []
    // Recolours every icon in this pill. See Icon.tint.
    property color iconTint: "transparent"
    // Tag pills put the number first and what is running on it after, because
    // the icons then read as belonging to the number they follow.
    property bool iconsAfterText: false
    property color fg: Cfg.fg
    property color bg: "transparent"
    property int paddingX: Cfg.pillPadding
    // A width to pin to, so a clock does not resize the bar every second as
    // its digits change width. 0 sizes to content.
    property int fixedWidth: 0
    // A cap rather than a pin: a short title should occupy a short pill.
    property int maxWidth: 0
    // Reserved at the head of the pill for artwork the module draws itself
    // (the media spectrum). Counted in the width like anything else in the
    // row, so the label starts after it instead of underneath it.
    property int leadingSpace: 0
    property bool interactive: true
    // A chip is a filled tile whose own background is the edge you see, so its
    // padding is not slack and must not be trimmed away by the panel.
    property bool chip: false

    signal clicked(int button)
    signal wheel(int delta)

    // "Has this got anything to show?" -- asked by ModuleLoader, which owns
    // the slot this pill sits in and hides it when the answer is no.
    //
    // A separate property from `visible` because Item.visible is EFFECTIVE
    // visibility: it reads false whenever an ancestor is hidden, so a module
    // that answered with it would latch itself off the moment its slot was
    // hidden, and never come back.
    property bool shown: true

    // What the panel should trim from this pill when it is the first or last
    // thing in a section, so `panel.padding` is the distance to what you can
    // SEE rather than to a pill's box.
    //
    // Two parts: the pill's own horizontal padding (nothing for a chip), and
    // the unused reserve of a pinned pill -- a clock pinned to the width of
    // its widest month is mostly empty at the start of a month, and a panel
    // that padded to its box read 14px on one side and 6px on the other.
    readonly property int inkInset: chip ? 0 : paddingX
    readonly property int slack:
        fixedWidth > 0 ? Math.max(0, fixedWidth - naturalWidth) : 0
    readonly property int leadTrim: Math.floor(slack / 2) + inkInset
    readonly property int trailTrim: Math.ceil(slack / 2) + inkInset

    // Icons fill the pill's TEXT AREA, which is the pill inset by its border
    // and its vertical padding -- not the pill height (text-node.c:
    // `box_logical_h = height - 2 * border_width`, then `icon_px =
    // text_area_h * icon_scale`).
    //
    // Eight pixels of border is the difference between a 36px icon and a 28px
    // one, and since the icon's advance is part of the pill's width, getting
    // it wrong moved every pill after it. `iconScale` is the per-module
    // override the media transport controls use, for SVGs that fill their
    // viewBox edge to edge.
    property real iconScale: 1.0
    // The label's font, so a module that has to MEASURE text (a pinned clock,
    // a volume level) measures it in the font it will actually be drawn in.
    readonly property font textFont: label.font

    readonly property int iconSize:
        Math.round((implicitHeight - 2 * Cfg.borderWidth
                    - 2 * Cfg.themePaddingY) * iconScale)
    readonly property int contentWidth: layout.implicitWidth

    // The native formula, verbatim (text-node.c):
    //
    //     width = 2*pad_x + icon_w + text_w  +  2*border_width  +  1
    //
    // Both tails matter. The border sits OUTSIDE the padding, and Qt draws a
    // Rectangle's border inside its own width -- so without the 2*border term
    // every pill comes out eight pixels narrow and the whole section creeps
    // left, a pill at a time. The +1 is deliberate slack: the measurement is
    // logical and the text is laid out in physical pixels, and at a fractional
    // scale the two roundings disagree just often enough to ellipsise a label
    // that was pinned to its own width.
    readonly property int naturalWidth:
        contentWidth + 2 * paddingX + 2 * Cfg.borderWidth + 1

    // What this pill would be if its LABEL were `w` wide instead of what it
    // currently is. This is how a pill pins itself -- a clock to its widest
    // month, a volume level to its digit count, a temperature to its widest
    // reading -- and it exists because every module that did the arithmetic
    // itself got it wrong the same way.
    //
    // Pinning is about the label. Everything else the pill contains still
    // costs what it costs: the icon still takes its advance, the padding is
    // still on both sides, the border still sits outside it. Three modules
    // wrote `text_width + 2*padding` and lost the icon entirely -- about 28px
    // each. That truncates nothing, because the content simply overflows the
    // pill's box, so it reads as the NEXT module having no space before it:
    // reported as a spacing bug in the volume pill, actually a width bug in
    // three of them.
    readonly property real labelWidth: label.visible ? label.implicitWidth : 0
    function widthForText(w) {
        return Math.ceil(naturalWidth - labelWidth + w);
    }

    implicitWidth: {
        if (fixedWidth > 0)
            return fixedWidth;
        const natural = Math.max(Cfg.pillMinWidth, naturalWidth);
        return maxWidth > 0 ? Math.min(natural, maxWidth) : natural;
    }
    implicitHeight: Cfg.height - 2 * Cfg.pillInset

    Rectangle {
        anchors.fill: parent
        radius: Cfg.themeRadius
        color: root.bg
        // The shared theme's border, which every native pill carries -- the
        // tab-bar node applies the whole theme, border included, and the bar
        // only overrides the colour pair on top of it.
        border.width: Cfg.borderWidth
        border.color: Cfg.border
    }

    Row {
        id: layout
        anchors.centerIn: parent
        // Between the artwork and the label: the same 6px the native node puts
        // there, and only when there IS text -- a Row spaces only its visible
        // children, so an icon-only pill gets no trailing gap.
        spacing: 6

        // Room at the head of the pill for something a module draws itself.
        //
        // The media pill's spectrum is positioned absolutely, so it is not in
        // this Row and the label does not know it is there: while a track was
        // playing the visualiser was drawn straight over the first few
        // characters of the title.
        Item {
            visible: root.leadingSpace > 0
            width: root.leadingSpace
            height: 1
            anchors.verticalCenter: parent.verticalCenter
        }

        Row {
            id: iconsBefore
            visible: root.icons.length > 0 && !root.iconsAfterText
            spacing: 6
            anchors.verticalCenter: parent.verticalCenter
            Repeater {
                model: root.iconsAfterText ? [] : root.icons
                delegate: Icon {
                    required property string modelData
                    name: modelData
                    size: root.iconSize
                    tint: root.iconTint
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        Text {
            id: label
            visible: root.text !== ""
            text: root.text
            color: root.fg
            font.family: Cfg.fontFamily
            font.weight: Cfg.fontWeight
            font.italic: Cfg.fontItalic
            // Points, because Qt's pixelSize is an INTEGER property.
            //
            // 16pt at 96dpi is 21.33px, and pixelSize truncates that to 21 --
            // which measured "1: t1" three pixels narrower than Pango did and
            // shifted every pill after it. Pango keeps the fraction, so the
            // only way to agree is to hand Qt the points and let it do the
            // same arithmetic. That is safe here ONLY because the launcher
            // pins QT_FONT_DPI=96, the resolution the compositor renders at.
            font.pointSize: Cfg.fontSize
            // Integer glyph advances, the way cairo lays text out.
            //
            // Qt's default is unhinted, fractional advances: it measured
            // "1: t1" at 62.97px where Pango measured 65, and that two-pixel
            // disagreement per label pushed every pill after it out of place.
            // Cairo rounds each advance to a whole pixel (metric hinting is on
            // even at HINT_STYLE_SLIGHT, which the compositor sets), so asking
            // Qt to hint makes the two agree instead of merely being close.
            font.hintingPreference: Font.PreferFullHinting
            renderType: Text.NativeRendering
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            // Capped by maxWidth ONLY, never by fixedWidth.
            //
            // Taking fixedWidth into account here reads better and does not
            // work: fixedWidth is usually derived from the pill's content
            // width, which is this label's width, which would then depend on
            // fixedWidth. Qt breaks that loop wherever it likes, and what came
            // out was a clock pinned to the width of "00:38" that then
            // ellipsised itself to "00:38:...". A pinned width is always
            // derived from a measurement of the widest possible text, so the
            // label fits by construction and needs no second opinion.
            width: {
                if (root.maxWidth <= 0)
                    return implicitWidth;
                const art = root.icons.length > 0
                    ? root.icons.length * root.iconSize
                      + (root.icons.length - 1) * 6 + 6
                    : 0;
                const room = root.maxWidth - 2 * root.paddingX
                    - 2 * Cfg.borderWidth - 1 - art
                    - (root.leadingSpace > 0 ? root.leadingSpace + 6 : 0);
                return Math.min(implicitWidth, Math.max(0, room));
            }
        }

        Row {
            id: iconsAfter
            visible: root.icons.length > 0 && root.iconsAfterText
            spacing: 6
            anchors.verticalCenter: parent.verticalCenter
            Repeater {
                model: root.iconsAfterText ? root.icons : []
                delegate: Icon {
                    required property string modelData
                    name: modelData
                    size: root.iconSize
                    tint: root.iconTint
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.interactive
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: mouse => root.clicked(mouse.button)
        onWheel: ev => root.wheel(ev.angleDelta.y)
    }
}
