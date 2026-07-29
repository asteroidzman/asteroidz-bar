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

## Plugins

`custom "<name>" { exec "..."; continuous true }` in the compositor's `bar {}`
block, then `custom/<name>` in a module list. The protocol is unchanged from
the compositor's own: one JSON object per line on stdout, events back on stdin.

```json
{"text":"Idle","icon":"waybar-discord-voice/discord.svg","tint":"accent"}
{"menu":{"item":"","rows":[{"text":"Mute","value":"do:mute"}]}}
```

Three ship with this package — `asteroidz-bar-nordvpn`, `-discord`,
`-medication` — and they run untouched, which was the test that mattered: a
better schema would have bought nothing and broken all of them.

## Testing

```sh
contrib/look-test.sh       # panel geometry: hidden modules, pinned pills, the shadow
contrib/wallpaper-test.sh  # the wallpaper, drawn in-process, HDR path included
contrib/tray-test.sh       # the tray, on a private D-Bus session
contrib/click-test.sh      # what the bar DOES when clicked: popovers, dropdowns, plugin menus
contrib/parity.sh          # native bar vs this one (historical; see the header)
```

`look-test.sh` exists because of three bugs that were reported as one
complaint about spacing and none of which are visible in the QML — they only
exist once it is drawn. A module that hides itself still had its slot measured
(an idle media module reserved 390px), a pill pinned to its label's width lost
its icon's advance and overflowed into its neighbour, and the panel's shadow
was drawn by a `MultiEffect` whose source was a plain `Rectangle` — not a
texture provider, so it drew nothing at all. So the test draws the bar on a
light wallpaper and measures pixels.

`click-test.sh` drives the bar with a real pointer (`zwlr_virtual_pointer_v1`)
because every interaction bug so far was "verified" by reading the QML and
every one of those readings was wrong. Its sharpest check is that the panel
**repaints** rather than stretches. A popover that resizes while it is mapped
can hang the client outright: Qt and quickshell each send an
`xdg_popup.reposition` with its own token, xdg-shell lets the compositor "skip
all but the last one", and Qt never paints again once its token goes
unanswered — it just leaves the previous frame stretched over the new surface
size. The panel still grows, so a size assertion alone passes on the broken
build; only the glyph height gives it away. `Popover.qml` now keeps the surface
a fixed box and moves the panel inside it, which is why a dropdown can open
without touching the window size at all.

It also drives a **stub plugin** over the real stdin/stdout protocol, because
the bar's half of that protocol was never wired up: the popover raised
`activated`, the bar looked the row up as a PipeWire node and as a tray entry,
found neither, and closed the panel. Every row in every plugin menu looked
live, dismissed itself and told the plugin nothing. A stub rather than a real
plugin, so the test does not depend on a medication schedule existing on the
machine running it.

`parity.sh` gates on **geometry** — panel extents and every pill border
position — not on pixels. Pango and Qt never agree to the last subpixel, so a
pixel gate strict enough to catch a layout bug would fail forever on
antialiasing. Pixels are still compared, loosely, to catch a blank section or
artwork that failed to load.

`tray-test.sh` runs on its own bus deliberately: quickshell hosts
StatusNotifierItem on whatever bus it finds, so a test against the real one
would pick up Steam and Discord and pass whether or not the code works.

## Layout

```
shell/          the QML: one bar per output, one file per module
plugin/         the C++ QML module, imported as `Asteroidz.Bar`
subprojects/
  asteroidzbg/  the wallpaper, as a static library
plugins/        the status plugins (the compositor's protocol, unchanged)
bin/            the launcher
```

One process draws all of it. The bar and the wallpaper share a Wayland
connection, a config and a lifetime: starting `asteroidz-bar` puts both up,
stopping it takes both down, and there is no second binary to launch or
supervise.

`plugin/` is what QML cannot express:

- **`Backdrop`** — the wallpaper. It drives `asteroidzbg`, vendored from
  `~/asteroidzbg` and now built as a static library rather than a program.
  That code stays C because of one thing: it tags its surface through
  `wp_color_manager_v1` with BT.2020 primaries and the PQ transfer function
  and decodes 10-bit AVIF and JPEG XL to match. Qt exposes no way to reach
  either, so drawing the wallpaper with QML's `Image` would silently flatten
  every HDR wallpaper to SDR read as plain gamma — the exact bug asteroidzbg
  was forked from swaybg to fix. Decoding runs on a worker thread; only the
  attach and commit touch the GUI thread.
- **`Paths`** — does this file exist? The icon search is a list of roots tried
  in order, so misses are the normal case; with no existence check the only
  way to implement it was to let an `Image` fail, which logged a warning per
  miss for artwork that was found a candidate later.

The module is loaded from an import path the launcher sets, not installed into
`/usr/lib/qt6/qml`: this package does not write into Qt's tree, and does not
break when Qt is rebuilt.
