# asteroidz-bar

The asteroidz shell: the status bar and the wallpaper, out of the compositor.

asteroidz grew a native bar because a bar client that forks `wpctl` on its main
loop is a stutter in a bar and a dropped frame in a compositor. Drawing it in
the compositor fixed that by making every module the compositor's problem
instead — a plugin that hangs, a tray icon that decodes a 4096×4096 pixmap, a
menu that needs a text field. This project takes the drawing back out while
keeping what the move bought: the modules that read `/proc` stay cheap, and
nothing a status module does can drop a frame any more, because a client that
misses a frame only misses its own.

Built on [quickshell](https://quickshell.outfoxxed.me) (QML/Qt6).

## Running

```sh
asteroidz-bar
```

The launcher is not optional decoration — it pins Qt's DPI handling to the
compositor's fixed 96 dpi. Running `qs -p .../shell.qml` directly on a desktop
with `Xft.dpi: 168` renders the bar 1.75× too large.

Point it at a working tree instead of the installed copy with
`ASTEROIDZ_BAR_SHELL=/path/to/shell/shell.qml asteroidz-bar`.

## How it talks to the compositor

One unix socket, newline-delimited JSON, the same one `amsg` uses
(`$ASTEROIDZ_INSTANCE_SIGNATURE`). State is pushed, not polled:

| subscription | what it carries |
|---|---|
| `watch bar-config` | the resolved geometry, palette and module lists |
| `watch all-tags` | per-output tag occupancy and selection |
| `watch focused-client` | the focused window's title and app id |
| `watch all-monitors` | layout, geometry, per-output state |

`watch bar-config` is the interesting one. The compositor resolves `bar {}` and
`theme {}` — defaults, clamping, and the matugen palette that is rewritten
whenever the wallpaper changes — and serves the **result**. The shell never
parses KDL: a second reader would agree with the first until one of them gained
a default, and it would still not see a palette written after startup.

## Blur and shadows

Blur is the compositor's (`ext-background-effect-v1`): the shell reports the
exact region its panels occupy, corner radii included, and asteroidz blurs
behind it. A transparent surface with three rounded slabs on it therefore gets
blur under the slabs and nothing between them.

Shadows are the shell's own. asteroidz will put a layer shadow behind the whole
surface, but the surface spans the output — that would be one shadow around all
three sections including the gaps between them.

## Layout

```
shell/          the QML: one bar per output, one file per module
subprojects/
  asteroidzbg/  the wallpaper (C)
bin/            the launcher
```

`asteroidzbg` is vendored from `~/asteroidzbg` and stays C. It tags its surface
through `wp_color_manager_v1` with BT.2020 primaries and the PQ transfer
function, and decodes 10-bit sources to match; QML has no way to do that, so
rewriting it would mean quietly dropping HDR wallpapers on an HDR desktop.
