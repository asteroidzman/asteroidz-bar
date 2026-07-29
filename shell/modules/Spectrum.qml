// The media visualiser: cava's output, drawn as bars.
//
// cava does the FFT and we draw the answer. It is configured for `raw` ASCII
// output on stdout, which is one line of N numbers per frame -- so the whole
// integration is a Process and a split on whitespace.
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

    // A frame whose bars have all moved less than this is not redrawn. Without
    // it the bar recomposites at the full frame rate on every monitor for
    // motion nobody can see.
    readonly property real redrawEps: 0.02

    Process {
        id: cava
        running: root.running
        command: ["cava", "-p", "/dev/stdin"]
        stdinEnabled: true

        onRunningChanged: {
            if (!running) {
                root.levels = [];
                root.silent = true;
                return;
            }
            // cava reads its config from the path given to -p, and /dev/stdin
            // means we can hand it one without writing a file into the user's
            // home or racing another instance over a fixed temp path.
            //
            // autosens so a quiet podcast still fills the bars instead of
            // sitting on the floor; mono because the pill is far too small for
            // stereo to read.
            write("[general]\n"
                  + "bars = " + Cfg.mediaBars + "\n"
                  + "framerate = " + Cfg.mediaFps + "\n"
                  + "autosens = 1\nsensitivity = 100\n"
                  + "lower_cutoff_freq = 50\nhigher_cutoff_freq = 12000\n"
                  + "[input]\nmethod = pipewire\nsource = auto\n"
                  + "[output]\nmethod = raw\nraw_target = /dev/stdout\n"
                  + "data_format = ascii\nascii_max_range = 1000\n"
                  + "channels = mono\n"
                  + "[smoothing]\nnoise_reduction = 35\n");
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

    visible: showing

    Row {
        anchors.fill: parent
        spacing: Math.max(1, Math.floor(root.width / (Cfg.mediaBars * 4)))

        Repeater {
            model: root.levels

            delegate: Rectangle {
                required property real modelData
                required property int index

                width: Math.max(1, (root.width
                        - (Cfg.mediaBars - 1) * parent.spacing) / Cfg.mediaBars)
                // A floor, so a silent-but-present spectrum still reads as a
                // row of bars rather than as nothing at all.
                height: Math.max(2, modelData * root.height)
                anchors.bottom: parent.bottom
                radius: 1
                color: Cfg.focusBg
            }
        }
    }
}
