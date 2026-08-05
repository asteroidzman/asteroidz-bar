pragma Singleton

// How big things are, per monitor.
//
// Every size in this shell was one number for the whole desktop, which is
// right only while every output is the same shape. On a 3840x2160 output at
// scale 1 beside a 1920x1080 at scale 0.75 — logical 2560x1440 — a 48px bar is
// 2.2% of the first screen's height and 3.3% of the second's. The same pixels,
// half again as much screen, and it reads as a bar that is simply too big on
// the smaller monitor.
//
// So a size is a FRACTION OF THE SCREEN rather than a constant. The factor is
// this output's logical height over the tallest output's, which has two
// properties worth having: a single-monitor desktop is completely unchanged,
// because its own height is the tallest; and adding a monitor never makes an
// existing bar bigger.
//
// ── why not Qt's own per-screen scaling ─────────────────────────────────────
//
// Because it does not reach here. QT_SCREEN_SCALE_FACTORS was tried first and
// measured: with `HDMI-A-1=0.6667` the bar's panel still spanned the same 48
// logical rows. A quickshell PanelWindow is sized in Wayland logical
// coordinates, so Qt's device pixel ratio never enters into it.
//
// An Item.scale transform was the other shortcut and is worse: it rasterises
// text and then resamples it, and this shell pins DPI and asks for full
// hinting precisely so that text is not resampled.

import Quickshell
import QtQuick
import "."

Singleton {
    id: root

    // The tallest output, in logical pixels. Recomputed whenever the set of
    // monitors changes -- plugging one in must not leave the others measuring
    // against a screen that is no longer there.
    readonly property real reference: {
        void Compositor.generation;
        let tallest = 0;
        for (const name in Compositor.monitors) {
            const m = Compositor.monitors[name];
            if (m && m.height > tallest)
                tallest = m.height;
        }
        return tallest > 0 ? tallest : 1080;
    }

    // What to multiply a size by on a given screen.
    //
    // Clamped at half. A monitor turned portrait, or a very small panel, would
    // otherwise shrink its bar past readable; and a factor above 1 would mean
    // the reference is wrong rather than that this screen has earned a bigger
    // bar.
    function factor(screenName) {
        void Compositor.generation;
        const m = Compositor.monitors[screenName];
        if (!m || !m.height || reference <= 0)
            return 1;
        return Math.max(0.5, Math.min(1, m.height / reference));
    }

    // A size, in this screen's terms. Rounded, because a bar 32.4px tall puts
    // every pill on a half pixel and the text goes soft.
    function px(value, screenName) {
        return Math.round(value * factor(screenName));
    }

    // The font, which matters most: nearly every other size in this shell is
    // derived from it, so scaling the font carries most of the layout with it.
    function fontPx(screenName) {
        return Cfg.fontPixelSize * factor(screenName);
    }

    function fontPt(screenName) {
        return Cfg.fontSize * factor(screenName);
    }
}
