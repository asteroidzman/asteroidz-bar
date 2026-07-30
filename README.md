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
contrib/media-test.sh      # the media module, with a player and no sound
contrib/notify-test.sh     # the bell, against a stubbed swaync
contrib/click-test.sh      # what the bar DOES when clicked: popovers, dropdowns,
                           #   plugin menus, and staged-vs-applied display edits
contrib/panel-layout-test.sh # the display panel's boxes fit the text in them,
                           #   at three font sizes
contrib/plugin-lifecycle-test.sh # a plugin dies with the bar that started it
                           #   (no compositor needed; runs in seconds)
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

`panel-layout-test.sh` checks the other half: not what the panel does, but
whether its boxes fit the text in them. The display tabs were `width: 100` with
a centred `Text` carrying no width, no elide and no clip, so at the shipped
theme "Wallpaper" overflowed its pill on both sides, ate the gap to the tab
beside it, and was painted over by that tab's fill — reported as two bugs, text
cut off and tabs touching, from one cause.

It runs at **three font sizes on purpose**, and that is the whole design. Every
bug of this kind is a fixed pixel constant meeting a theme-sized glyph, so a
test at one font size tests the one case that happened to fit: run against the
old code it passes cleanly at `Ubuntu 11`, where "Wallpaper" really does fit
inside 100px, and fails at 16 and 24. Anything sized from a constant now comes
from `Cfg.fontPixelSize` instead, which is what `FormRow` and `Picker` were
already doing.

It also checks that the arrangement canvas does not sit on its own
"drag to arrange" hint. `zoom` is `min(width/bounds, height/bounds)`, so
whenever the layout's bounding box is proportionally narrower than the canvas
the zoom is height-limited and the tiles use every vertical pixel there is —
the 15% breathing room came to ~11px at the bottom while the hint needs ~17px
with its margin. `Arrange` now reserves a band for the hint and lays the tiles
out in what is left.

Three things about how it measures, all learned the hard way.

The accent tolerance is tight (14, not 30) because white text on a dark tab is
subpixel antialiased and its blue fringe lands within 30 of the accent on every
channel — a loose match reported the far edge of the *next* tab's label as this
tab's right edge.

The pill is measured on the row carrying the **most** accent, not the middle
row: the middle row runs straight through the label, so the fill is interrupted
by every glyph and the longest unbroken run is the space between two letters.

The hint is found **geometrically, not by colour**. The obvious approach — the
hint is dim, the monitor name is bright — ignores that the name is antialiased,
so its glyph edges pass any "dim" test you can write; a luminance window duly
reported the hint as starting mid-tile, where the name is, and failed on the
fixed build as loudly as on the broken one. The hint is left-aligned and the
tiles are centred, so the strip between the canvas edge and the tile's left edge
holds hint ink and nothing else.

A related trap, for anything that adds an output: `hl_start` sets the virtual
pointer's coordinate extent from the single output it created, and
`zwlr_virtual_pointer_v1.motion_absolute` maps coordinates onto the layout's
bounding box — so an extent that no longer matches scales every click. Call
`hl_sync_pointer_extent` (in `contrib/lib/headless.sh`) after creating,
destroying or moving an output. It went unnoticed because `multimonitor.sh`
places its second output *beside* the first, leaving the layout height alone;
stacking one below doubled it, and a click aimed at a pill 33px down arrived at
66px, which fails as "the panel did not open".

It also drives a **stub plugin** over the real stdin/stdout protocol, because
the bar's half of that protocol was never wired up: the popover raised
`activated`, the bar looked the row up as a PipeWire node and as a tray entry,
found neither, and closed the panel. Every row in every plugin menu looked
live, dismissed itself and told the plugin nothing. A stub rather than a real
plugin, so the test does not depend on a medication schedule existing on the
machine running it.

`media-test.sh` exists because the media module draws nothing at all without
an MPRIS player, so every question about how it LOOKS was unanswerable on a
test machine -- which is how the visualiser vanishing on silence went unnoticed
until it was reported. contrib/mprisstub supplies one, on a private bus, and it
is deliberately silent: something is playing, there is nothing to hear, and the
meter has to read zero rather than disappear.

`notify-test.sh` fakes swaync with a stub `swaync-client` early on PATH, and
has it CHANGE its answer partway through: the bell was reading a subscription
that never updated, and a stub that only ever reports one count would pass
while being just as broken.

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

### Plugins have to die with the bar

A continuous plugin's stdin is a pipe from the bar, so EOF on it means one
thing. Each plugin calls `exit_with_the_bar()` when its reader loop ends, and
`Custom.qml` stops its children on destruction as well.

This was a real leak and a completely silent one. 27 plugin processes were found
running across five previous bar sessions, the oldest a day old, still polling
`nordvpn` and Discord every few seconds. Two things that look like they would
have caught it, and don't:

- The reader thread **does** see stdin close — `for line in sys.stdin` ends. But
  it is a daemon thread, so its return means nothing, and `main()`'s
  `while True: poll; emit; sleep` carried on regardless. `sys.exit` would not
  help either: it raises `SystemExit` only in the calling thread. Hence
  `os._exit`.
- Writing to the closed stdout should raise `BrokenPipeError`. It never fires,
  because `emit()` **deduplicates** — a plugin whose state has not changed
  writes nothing at all, so it never touches the broken pipe and never finds
  out. A plugin with a stable VPN state can poll for a day without emitting a
  byte.

There was a second-order leak behind it. `asteroidz-bar-discord` spawns
`discord-voiced` when it cannot reach the socket, deliberately detached
(`start_new_session=True`) so it outlives the plugin — right, because it holds a
live voice connection. But it spawned one even when a socket **file** was
already present, and a second daemon cannot bind a path that is taken, so it sat
there doing nothing. 16 were found, the socket dated to the first one and never
replaced. `spawn_daemon` now declines when a socket exists unless forced, so
"Start daemon" in the menu still works. The plugin does **not** kill the daemon
on exit: taking someone off a call because their bar restarted would be far
worse than a stray process.

`contrib/plugin-lifecycle-test.sh` pins all of it with a pipe and no compositor.
It asserts each plugin *stays up while stdin is open* as well as exiting when it
closes — a plugin that died immediately would pass a naive "did it die" check.
Against the old code all three survive stdin closing, and the daemon count goes
up by one.
