// The media visualiser: cava's output, drawn as bars.
//
// cava does the FFT and we draw the answer. It is configured for `raw` ASCII
// output on stdout, which is one line of N numbers per frame -- so the whole
// integration is a Process and a split on whitespace.
//
// The config goes in a FILE. It used to be handed to `cava -p /dev/stdin` and
// written down the process's stdin, which avoided putting a file anywhere --
// and silently never arrived: the live cava processes sat blocked on their
// config read with zero CPU time for as long as the bar was up, so the
// visualiser never drew a single frame and the pill quietly showed its
// fallback glyph instead. A path in XDG_RUNTIME_DIR is not elegant, but it is
// there before cava looks for it.
//
// The cost here is NOT the FFT (measured at about half a percent of one core);
// it is the redraw, because every frame damages the bar's region on every
// monitor and forces a recomposite. That is why the frame rate is a config
// knob and why a frame that has not visibly changed is dropped on the floor
// rather than drawn.

import Quickshell
import Quickshell.Io
import QtQuick
import ".."

Item {
    id: root

    property bool running: false
    // Whether there is anything worth showing. cava keeps running while
    // silent -- it costs nothing and it is how we notice the signal coming
    // back -- but a flat line is not a visualisation, so the pill falls back
    // to its glyph.
    readonly property bool showing: running && !silent

    property var levels: []
    property bool silent: true

    // One config file per visualiser instance -- there is one per output, and
    // two bars writing the same path would race on every config reload.
    readonly property string confPath:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp")
        + "/asteroidz-bar-cava-" + instanceKey + ".conf"
    readonly property string instanceKey:
        Math.random().toString(36).slice(2, 10)

    readonly property string confText:
        "[general]\n"
        + "bars = " + Cfg.mediaBars + "\n"
        + "framerate = " + Cfg.mediaFps + "\n"
        // autosens so a quiet podcast still fills the bars instead of sitting
        // on the floor; mono because the pill is far too small for stereo to
        // read.
        + "autosens = 1\nsensitivity = 100\n"
        // 50-4000, not 50-12000. Measured against real audio, the wider
        // range put everything in the top band and left the rest flat: six
        // bars over 50-12000 read 3;2;1;1;2;9 up to 27;38;50;19;19;117,
        // never above an eighth of the scale except the last. Over 50-4000
        // the same audio spreads across all six and uses the whole range.
        // Six bars is simply too few to spend any of them above 4kHz.
        + "lower_cutoff_freq = 50\nhigher_cutoff_freq = 4000\n"
        + "[input]\nmethod = pipewire\nsource = auto\n"
        + "[output]\nmethod = raw\nraw_target = /dev/stdout\n"
        + "data_format = ascii\nascii_max_range = 1000\n"
        + "channels = mono\n"
        + "[smoothing]\nnoise_reduction = 35\n"

    // cava is only started once its config is on disk: it reads the path once,
    // at startup, and a missing file means it runs with defaults that do not
    // match what this pill draws.
    property bool confReady: false

    FileView {
        id: conf
        path: root.confPath
        printErrors: true
    }

    function writeConf() {
        conf.setText(root.confText);
        root.confReady = true;
    }

    Component.onCompleted: writeConf()
    onConfTextChanged: writeConf()

    // The box sizes itself from the bars, not the bars from the box.
    //
    // It used to be given the icon's square -- 28px -- and six bars were
    // divided into it, which came out under four pixels each with a pixel
    // between them: technically a spectrum, visually a texture.
    readonly property int barWidth: Math.max(5, Math.round(Cfg.height * 0.19))
    readonly property int barGap: Math.max(2, Math.round(barWidth * 0.35))
    implicitWidth: Cfg.mediaBars * barWidth + (Cfg.mediaBars - 1) * barGap

    // A frame whose bars have all moved less than this is not redrawn. Without
    // it the bar recomposites at the full frame rate on every monitor for
    // motion nobody can see.
    readonly property real redrawEps: 0.02

    Process {
        id: cava
        running: root.running && root.confReady
        command: ["cava", "-p", root.confPath]

        onRunningChanged: {
            if (!running) {
                root.levels = [];
                root.silent = true;
            }
        }

        stderr: SplitParser {
            // A cava that cannot open its input says so here and then produces
            // nothing at all, which otherwise looks exactly like silence.
            onRead: line => {
                if (line.trim())
                    console.warn("asteroidz-bar: cava:", line);
            }
        }

        stdout: SplitParser {
            onRead: line => {
                const parts = line.trim().split(";").filter(s => s.length > 0);
                if (parts.length === 0)
                    return;

                const next = parts.map(v => Math.min(1, Number(v) / 1000));
                let peak = 0;
                let moved = 0;
                for (let i = 0; i < next.length; i++) {
                    peak = Math.max(peak, next[i]);
                    const was = root.levels[i] !== undefined ? root.levels[i] : 0;
                    moved = Math.max(moved, Math.abs(next[i] - was));
                }

                root.silent = peak < 0.02;
                if (moved >= root.redrawEps || root.silent !== (peak < 0.02))
                    root.levels = next;
            }
        }
    }

    // `shown`, not `visible` -- see ModuleLoader.
    property bool shown: showing

    Row {
        // Centred, not filled: the bars are a fixed width now, so whatever
        // room is left over belongs on both sides rather than all on one.
        anchors.centerIn: parent
        height: parent.height
        spacing: root.barGap

        Repeater {
            model: root.levels

            delegate: Rectangle {
                required property real modelData
                required property int index

                width: root.barWidth
                // A floor, so a silent-but-present spectrum still reads as a
                // row of bars rather than as nothing at all.
                height: Math.max(2, modelData * root.height)
                // Grown from the middle, both ways. Anchored to the bottom it
                // read as a graph sitting on a baseline, which is not what a
                // level meter beside a track title should look like.
                anchors.verticalCenter: parent.verticalCenter
                radius: 1
                color: Cfg.focusBg
            }
        }
    }
}
