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

## Settings

`All settings…`, at the top right of the display panel, opens a real window with
every configuration option the compositor accepts: 95 of them, each with the
compositor's own one-line explanation, grouped, searchable, and showing which
file the current value came from.

**Nothing about any individual option lives in this repo.** asteroidz publishes a
machine-readable schema — type, range, enum members, default, group, label,
description — and the window is generated from it:

| the schema says | the window does |
|---|---|
| `type: bool` | a toggle |
| `type: enum` + `enum: [...]` | a picker over the members, aliases dropped |
| `type: color` | a swatch over a checkerboard, plus the `0xRRGGBBAA` |
| a number with `min` and `max` | a slider, stepped and bounded |
| a number without both | a text field — a range must not be invented |
| `desc` | the second line of the row |
| `source` | the third line: file, line, and the path it is actually at |
| `source.writable: false` | greyed out, with an **Override** offered |

So an option added to `src/config/config-schema.h` appears here, explained and
bounded, with no change to any QML file. The alternative — a settings UI with its
own table of options — is a second description of the config that agrees with the
compositor's until one of them gains an option.

### Two stages, and why

| | what it does |
|---|---|
| **preview** | memory only, sent as you drag (`set-config` with `persist:false`) |
| **Apply** | the staged set, written to the config file, all or nothing |

Preview exists because a blur radius or a shadow colour is otherwise
unadjustable: you would have to write to disk to see what a value looks like.
Drags are coalesced on a 60 ms timer, so a gesture costs a handful of requests
rather than one per frame.

A preview that is never applied is undone when the window closes — by
`reload_config`, not by writing the old values back. Those are not the same
thing: writing `4` back over a preview of `8` leaves the value right and the
provenance wrong, so a key that *is* saved in `config.kdl` reads back as "changed
in memory, not saved" from then on.

### Values matugen owns

Nine colours are generated from the wallpaper. The window greys them out and says
so, because writing to `colors.kdl` is not refused — it is silently reverted the
next time the wallpaper changes, which looks like the compositor forgetting things
at random.

**Override** is the escape hatch. `source` in KDL is applied in place and later
declarations win, so the compositor can append the key at the end of the main
config and shadow the generated file. It refuses to do that unless asked:
refusing forever is a dead end, and doing it silently means matugen and this
window quietly fight over the palette.

### Palette

A third page, over matugen. It maps each of the nine generated colours to a
Material role — `primary`, `surface_container_high`, `error` — with an optional
grayscale filter, and a switch per colour for whether matugen owns it at all.
Turning one off drops it from the template, and your own `config.kdl` decides it
from then on.

**The role list comes from the installed matugen**, asked for at runtime with
`--dry-run`, not from a table here. A hardcoded list is a second description of
somebody else's software that is correct until they add a role.

**The mapping is the source of truth and the template is the render target.** The
template could be parsed back instead, and that would be one file rather than two,
but a template is arbitrary text with an arbitrary filter chain — a parser that
mostly works would silently drop whatever it did not understand the next time the
file was written. The exception is the first run, where the template is all there
is: it is parsed then, best-effort, so opening the page and pressing Apply does
not replace a tuned template with defaults. The previous one is kept as `.bak`.

Apply is one button for the whole page, unlike the rule and bind editors. The
reason is the opposite of theirs: all nine are rendered from one template by one
matugen run, so applying one *is* applying all of them.

Apply also **wires the template into matugen's config** if nothing there points at
it yet — a template matugen has not been told about renders nothing, so without
this the page would write a file, run matugen, report success, and change nothing.
It appends and keeps a `.bak`: that file themes every other application on the
machine, and regenerating it would make this a settings window that can lose your
whole desktop theme.

`matugen/` in this repo holds the template and is installed to
`/usr/share/asteroidz-bar/matugen/` — it used to live only in one person's
`~/.config`, which meant the palette the whole desktop is themed from existed on
exactly one machine and no installation produced it. The package does not copy it
into `~/.config`: that would overwrite a tuned template on every upgrade. The
Palette page seeds the user copy the first time it is opened and the file is
absent, which is the one moment where copying cannot destroy anything.

### Window rules and keybinds

Two more pages in the sidebar, built the same way — from
`get window-rule-schema`, `get window-rules`, `get binds` and
`get dispatch-actions`. Nothing about any individual rule field or dispatch lives
in this repo.

Both read from records the compositor captures **while it reads the config**, not
from its parsed structures, because that parse is lossy in exactly the place an
editor needs:

```
focus_stack next   →   func = focusstack, arg.i = NEXT
tag_silent 3       →   func = tagsilent,  arg.ui = 1<<2
```

Two things follow from the data model rather than from taste:

- **A rule card shows only the fields that rule sets**, and adding one is a
  deliberate act with its own picker. A rule holds only what it sets — that is
  what distinguishes "says nothing about blur" from "turns blur off" — so
  offering all 53 with unset controls would mean a Save could not tell them
  apart. The × beside a field is how you say "stop mentioning this".
- **Rules and binds save per card**, not behind the window's Apply bar, which is
  hidden on those pages. They are addressed by *index*, and a write renumbers
  everything after a removal — so batching a delete and an edit from two cards
  would send the second against an index the first invalidated, applied to the
  wrong rule, silently, because both rules are plausible.

The action is a picker over the 94 dispatch names, not a text field: a typo
writes a config that fails to reload, and that surfaces at the *next login*. The
compositor refuses an unknown action too; the picker is so you never reach that
refusal. Argument boxes carry the argument's kind (`tag-index`, `direction`) as
their placeholder, from the same schema.

**Capture** beside the chord field presses the keys for you. It goes through the
compositor's `capture-chord`, not through Qt key events, and that is not an
implementation detail: the compositor takes bindings *before* the focused surface
sees them, so a window reading its own keys would receive everything except the
combinations already bound — which is exactly what you press when rebinding. The
captured chord is swallowed, so capturing `Super+Q` does not also close this
window, and the card says so while it waits. If the chord is already bound
elsewhere the card says that too, because the compositor will not: bindings are
scanned in order and the last match wins, so a duplicate does not fail, the older
one just quietly stops working.

**Matchers offer the windows that are open.** An app id is not shown anywhere in
a normal desktop and is `org.mozilla.firefox` rather than "Firefox", so the rule
editor lists what `get all-clients` reports. Picked values are **anchored and
escaped** — `^kitty$`, not `kitty` — because these are regexes: bare `kitty` would
also match `kitty-dropdown`, and an unescaped `.` in an app id is a wildcard.

Binds that cannot be rewritten — the legacy `bind=` line form — are listed and
greyed rather than hidden. And `axisbind`, `switchbind` and `gesturebind` have no
KDL block form at all, so they are named at the foot of the list: a bind list with
no note would be quietly claiming they do not exist, and someone tidying their
binds through this window would lose them.

### Push-to-talk

The last page in the sidebar, and the only one that edits a file the compositor
knows nothing about: `~/.config/asteroidz-bar/discord-ptt.conf`, which the Discord
bridge watches. See [Push-to-talk for Discord](#push-to-talk-for-discord) for what
the bridge is and why it has to exist.

It exists as a page because the thing it configures is two keys that are easy to
confuse — the one you *press* and the one Discord *hears* — and getting them
backwards is the entire failure mode. Text at the point of use is worth more here
than a smaller page.

**No Apply bar.** Nothing to batch: two independent values, and the bridge applies
either the moment it lands. **Rebind…** hands over to asteroidz's own interactive
picker rather than asking for a keysym name — the picker is already there, it is
what the portal falls back to when an app binds with no usable trigger, and it
cannot produce a name X does not know.

The request reaches the bridge as a **file** in `XDG_RUNTIME_DIR`, not down its
stdin, because the bar runs one plugin instance per monitor and only one of them
holds the portal session. The others are mirrors, and the menu opens on whichever
screen was clicked — so a request that only worked from the bridge's own instance
would work on one monitor and silently do nothing on the other.

### Its icon

The window carries the asteroidz ship through `xdg-toplevel-icon-v1`, so anything
that lists windows shows it rather than a generic square.

That protocol carries an icon **name** and a set of pixel buffers, and asteroidz
records only the name — so the icon has to be a *theme* entry, which is why the
package installs the ship a second time as
`share/icons/hicolor/scalable/apps/asteroidz-settings.svg`. Building a `QIcon`
from a file path instead sends buffers, looks entirely correct from this side, and
leaves `get all-clients` reporting `"icon": ""`. That is how the first version
behaved.

It is therefore the packaged ship in its own colours, not the accent-recoloured
copy `Logo.qml` writes for the bar: recolouring produces a *file*, and a file
cannot travel down a channel that carries a name.

QML cannot set a window icon at all — QtQuick's `Window` has no `icon` property
and quickshell's window types do not add one — so this goes through a
`WindowIcon` singleton in the C++ plugin, alongside `Backdrop` and `Paths`.

### Opening it floating

It is an ordinary xdg toplevel (`FloatingWindow`), so asteroidz tiles it by
default. In `~/.config/asteroidz/config.kdl`:

```kdl
window-rule {
	match title="asteroidz settings"
	open-floating
	width 1100
	height 800
}
```

`match`, not bare properties: matchers live in a `match` child node, and
everything beside it is an action. `title`, not `app-id`, because the app id is
`org.quickshell` and every quickshell toplevel shares it — and it is a **regex**,
so it matches as a substring unless you anchor it.

`asteroidz -R` lists every field a rule accepts, and `amsg get window-rule-schema`
serves the same table with an explanation per field.

## Blur and shadows

Blur is the compositor's (`ext-background-effect-v1`): the shell reports the
exact region its panels occupy, corner radii included, and asteroidz blurs
behind it. A transparent surface with three rounded slabs on it therefore gets
blur under the slabs and nothing between them.

Shadows are the shell's own. asteroidz will put a layer shadow behind the whole
surface, but the surface spans the output — that would be one shadow around all
three sections including the gaps between them.

## The power menu

`power` in a module list. Lock, log out, suspend, hibernate, restart, power off.

**The destructive entries take two clicks, and the second one is in the same
panel.** Picking Restart replaces the list with the question, and the question is
what runs it — Cancel goes *back* to the list rather than closing, so landing
there by misclick costs one more click instead of the whole menu. A modal
dialogue would have been a second mechanism for a question this popover can
already ask, and a menu that closes and reopens elsewhere is how a misclick
becomes a shutdown.

Lock is one click: locking loses nothing, and a "really lock?" step would make
the one safe entry the slowest one.

**Log out is one click here too, and that is not an oversight** — it dispatches
`quit`, which the compositor confirms with its own full-screen prompt. That
prompt is not a duplicate of this one; it is the one that catches a `quit` from a
keybind or a script as well, so this menu hands over rather than asking twice.

The transitions are plain `systemctl`, without `--user`: they are system
transitions and polkit decides whether this session may make them. Where it may
not, systemctl says so rather than this module guessing.

## Idle

`swayidle` is gone: the bar does idle itself. asteroidz implements
`ext-idle-notify-v1` and owns DPMS, and the bar is a Wayland client that can
hold an idle timer and dispatch to it — a daemon in between was only ever
translating one into the other, with its own config file and timeouts nothing
else in the desktop could read.

The settings live in the compositor's config (`bar { idle { … } }`) and arrive
over `watch bar-config`, so changing one is a reload. `IdleService.qml` gives
each action its own `IdleMonitor` rather than chaining stages: they are
independent timeouts — screen off at ten minutes and suspend at thirty means
suspend at thirty, not forty — which is also why the protocol gives each
notification its own timeout.

`contrib/idle-test.sh` drives the whole chain headlessly with no daemon running:
idle notify → bar → `dpms_off_monitor` → the monitor reporting itself asleep,
then input and the same in reverse, then a reload that turns it off. Activity
there is a KEYPRESS, not pointer motion: a virtual pointer sends `time_msec 0`,
and asteroidz's `motionnotify` does its idle-activity notify inside `if (time)`,
so synthetic pointer motion neither wakes an output nor counts as activity.
Real hardware sends real timestamps and is unaffected.

See [the idle documentation](https://github.com/asteroidzman/asteroidz/blob/main/docs/configuration/idle.md)
for every setting.

## Plugins

`custom "<name>" { exec "..."; continuous true }` in the compositor's `bar {}`
block, then `custom/<name>` in a module list. The protocol is unchanged from
the compositor's own: one JSON object per line on stdout, events back on stdin.

```json
{"text":"Idle","icon":"waybar-discord-voice/discord.svg","tint":"accent"}
{"menu":{"item":"","rows":[{"text":"Mute","value":"do:mute"}]}}
```

Three ship with this package — `asteroidz-bar-nordvpn`, `-discord`,
`-reminders` — and they run untouched, which was the test that mattered: a
better schema would have bought nothing and broken all of them.

### Rows that take input

A menu row is normally a thing to pick. Two kinds of row are things to fill in
instead, and both hand their contents back in `fields` — keyed by the row's
`value` — with every pick, so a `Save` row is an ordinary row that happens to
receive the whole form:

```json
{"text":"Name",  "value":"name",  "input":true, "edit":"Vitamin D"}
{"text":"Hour",  "value":"hour",  "spin":{"min":0,"max":23,"pad":2}, "edit":"8"}
{"text":"Minute","value":"minute","spin":{"min":0,"max":55,"step":5,"pad":2}}
```

`input` is a text field: the row shows what has been typed, with a caret.
`spin` is a bounded number chosen with `‹ ›` arrows, by clicking them or with
Left/Right while the row is focused — `{min, max, step, wrap, pad}`, wrapping
unless `wrap: false`, `pad` zero-filling the display. A number that can only be
chosen cannot be entered wrongly, which matters here because a menu row is a
poor text field: no selection, no cursor, and a mistyped `8:0` is only found
when the form is submitted and refused.

`edit` prefills either kind. Anything the form must survive — a list being
built up, a name typed before a row was picked — belongs to the PLUGIN: picking
a row rebuilds every row from whatever the plugin sends next, so the plugin
holds the draft and prefills from it. `asteroidz-bar-reminders` does exactly
that for the times it collects.

### Push-to-talk for Discord

`asteroidz-bar-discord` is not a status pill that happens to mention Discord; it
is a bridge, and the pill is how it reports. Discord's push-to-talk cannot work
on Wayland — its keybinds live in a native module (`discord_utils.node`) that
links libX11 and listens with XInput2, so it hears the key only while an X
surface has focus. `--enable-features=GlobalShortcutsPortal` does nothing for it:
that flag belongs to the bundled Chromium, which carries it whether Discord calls
it or not.

So the key is taken globally by asteroidz and replayed into the X server, where
Discord is listening:

```
you press it  ──▶  asteroidz  ──(GlobalShortcuts portal)──▶  the bridge
the bridge    ──(XTEST fake key)──▶  XWayland  ──▶  Discord
```

XTEST injection happens *inside* the X server, so an XInput2 raw-event listener
sees it whatever Wayland surface has focus. Nothing here touches Discord's API:
no token, no gateway, no voice code, and no account credential in the process.

**Two keys, and keeping them straight is the whole thing.**

| | what it is | changing it |
|---|---|---|
| `trigger` | what you **press**. asteroidz grabs and consumes it, so no application ever sees it | free — any key, or a chord |
| `key` | what is **injected** for Discord to hear | must match Discord's own keybind, and everything focused in X sees it |

Leave `key` at the default, set Discord once, and rebind `trigger` as often as
you like. That asymmetry is why there are two.

Three ways to change it, all writing the same file
(`~/.config/asteroidz-bar/discord-ptt.conf`), which the bridge watches:

- **the pill** — click it; "press a key to rebind" hands over to asteroidz's
  own interactive picker, and the injected key opens a submenu of keys this
  keyboard actually has.
- **the settings window** — the *Push-to-talk* page, which also explains the
  distinction above at the point of use.
- **an editor** — it is a documented `key = value` file and stays one.

Neither UI asks you to *type* a key. What belongs in `key` is an X keysym name —
`Scroll_Lock`, not "scroll lock" — and there was no way to discover the spelling
from inside a text box: a wrong one resolves to nothing, is injected as keycode
0, is discarded by the server, and looks exactly like Discord ignoring
push-to-talk. So the pill offers a list and the settings page captures a real
press.

The list is filtered against the live keymap, which is not belt-and-braces:
F13–F24 are the obvious choices for a key you never otherwise use, and most
keyboards do not map them. On this machine F13–F18 and F20–F22 are absent while
F19, F23, F24, `Pause`, `Scroll_Lock`, `Break` and `Sys_Req` are present.

The settings page goes through the compositor's `capture-chord` rather than Qt
key events, for the reason the bind editor does: the compositor takes bindings
*before* the focused surface sees them, so a window reading its own keys would
receive everything except the combinations already bound. It refuses a chord —
XTEST sends one keycode with no modifier state, so `Super+V` would reach Discord
as a bare `V`, which is worse than refusing because it would appear to work.

An edit applies where it lands: a new `key` is retargeted in place, a new
`trigger` rebinds through the portal. Nothing restarts.

One gotcha worth knowing, because it is silent: asteroidz records interactively
picked bindings in `~/.config/asteroidz/global-shortcuts`, and a recorded pick
**outranks** the `preferred_trigger` an app asks for — deliberately, so a key you
chose is not undone by the next release of the app that asked. The bridge
therefore clears its own line there whenever a `trigger` is set from the conf.
Without that, writing a new trigger would appear to work and change nothing.

Discord must be running under XWayland or its keybind service is not listening
at all; `~/.local/bin/discord-xwayland` starts it with `--ozone-platform=x11`.
The portal also refuses `GlobalShortcuts` to a caller it cannot identify, which
is why `org.asteroidzman.DiscordPTT.desktop` is installed beside the bridge — the
app id must resolve to a desktop file glib can load *whose `Exec` binary exists*,
or the portal answers "App info not found" and push-to-talk never binds.

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
contrib/palette-test.sh    # the matugen palette page, fully sandboxed: its
                           #   template, mapping file and matugen binary are all
                           #   redirected, so it cannot re-theme the desktop it
                           #   runs beside
contrib/settings-test.sh   # the settings window: it opens, it is populated,
                           #   search narrows it, a click previews, Apply persists,
                           #   closing undoes an unapplied preview, the rule and
                           #   bind editors add through to the config file, and
                           #   Rebind… reaches the push-to-talk bridge
contrib/plugin-lifecycle-test.sh # a plugin dies with the bar that started it
                           #   (no compositor needed; runs in seconds)
contrib/discord-ptt-test.sh # the push-to-talk bridge: the app id resolves, the
                           #   portal offers the signals, and the rebind path
                           #   writes what it claims to (sandboxed XDG, no
                           #   compositor, no Discord)
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

`click-test.sh` also covers the thing that made **every text field in a panel
inert**: Folder and Cycle on the Wallpaper tab, and the Display tab's ICC path.
Keys go to whatever holds keyboard focus, which is the *bar's* layer surface
(`Bar.qml` raises `WlrKeyboardFocus.Exclusive` while a popover is up). The popup
deliberately never grabs focus — Qt refuses to create a grabbing popup here and
falls back silently — and `Bar.qml` routed every key to `Popover.handleKey`,
which only ever knew about the **menu rows** model. For a panel `rows` is empty,
so `focusedRow` stayed `-1` and every keystroke past Escape was dropped.

`Bar.qml` now forwards to `Popover.keyTarget`, which a `Field` claims for itself
when clicked — forwarding to a real `TextInput` rather than reimplementing
editing, because `Field` exists so that selection, the clipboard and IME stay
Qt's problem.

The interesting part is how a `Field` reaches the popover: **`QsWindow.window`,
not a walk up `parent`.** The visual parent chain does not reach the window at
all — a `Loader`'s item is parented to the `Loader`, the `Loader` to the window's
`contentItem`, and a `PopupWindow` is not an `Item`, so the chain dead-ends one
step short. Walking it looked right, compiled, ran, and set nothing: the keys
arrived at the bar with `keyTarget` still `null`. Only instrumenting both ends
showed it, and it is why the first attempted fix changed no behaviour at all.

A field also has to **look** focused, which is a separate bug from the keys not
arriving and was reported separately: "you can type stuff in but it is not clear
that you're actually focused on the field". `TextInput` draws its own caret from
`activeFocus`, which here depends on whether the *popup's* window is active — so
it appeared and vanished for reasons having nothing to do with where the keys
were going. `Field` now draws an accent outline, brightens its fill, and forces
the caret on, all keyed to `keysHere` — being the popover's `keyTarget`, which is
the one signal that actually decides. A `⏎` appears at the right edge while the
field is focused *and* changed, so the instruction shows up exactly when it is
actionable.

And the two tabs are in **opposite models**, which nothing used to say. The
Display tab stages everything behind Apply/Revert — it has to, because passing
*through* a resolution on the way to the one you wanted would mode-set to each,
and a mode set is a black screen for a moment. The Wallpaper tab applies as you
go, which is the only way picking a wallpaper can work: you choose it by seeing
it. So each tab now states its own model — "Changes wait for Apply" against
"Applied as you change them · ⏎ in a field to apply it" — because two opposite
models in one panel is fine and two opposite models with nothing saying which is
which is not.

Two things about the test. It finds the second tab **by colour** — the selected
tab is the topmost accent block, so the other one is just past its right edge —
because guessing an offset from `panel_box` put the click above the panel in one
harness and inside the tab row in another, and the tab silently never switched.
And its real assertion is that **`wallpaper.conf` changed**, not that pixels moved:
nothing else in the panel writes `folder=`, so a mis-aimed click can only make it
fail, never falsely pass.

`settings-test.sh` drives the settings window the same way, and every assertion
in it is a fact from **outside** the bar: a toplevel in the compositor's client
list, a value in `get config`, a line in the config file, `asteroidz -p` accepting
the result. Screenshots are used only where the claim is about layout.

Deliberately so, because the three bugs this window could plausibly ship with are
a control that shows a value it cannot write, a preview that is never undone, and
an Apply that writes a file the parser then rejects — none of them visible in QML,
all three visible here. It caught the second one on the first green run: the value
came back correct and the provenance did not, so the assertion now checks the
source as well (`0 -> 1/file`, not `0 -> 1`).

Two things about how it measures.

"Ink" is counted against the background found **in the shot**, not against a
brightness threshold. A constant said 458684 of 459000 sampled pixels were text in
every shot — the headless theme happens to set the surface to a bright colour —
and both the "is it populated" and the "does search narrow it" assertions were
comparing noise.

The toggle is located as the widest contiguous run of one flat non-background
colour **between 20 and 90 pixels wide**, below the header. Unbounded, the widest
such run is the search field, and the first version of this clicked into that
instead. A toggle is 44px of one colour; a glyph stroke is three.

The sidebar is measured from one accent pill rather than from assumed row
heights — but the **largest** run of accent rows, not the first. The window is
tiled and the compositor draws a focused border in the same accent, so the first
run is two pixels of frame, and a 2px "row height" put every computed sidebar
position off the end of the list.

A throwaway keypress precedes the real ones, because wlvkbd is one-shot and the
first press is lost while the client binds `wl_keyboard`. Whether it is lost is a
**race**, so sometimes it landed and the search became `asmartgaps`, which matches
nothing — six assertions failing together, about one run in three. A `BACKSPACE`
after it is a no-op on an empty field and undoes the stray character otherwise,
which makes the starting state the same either way.

`palette-test.sh` is sandboxed, and that is the first thing to know about it.
Applying on that page rewrites a template in `~/.config/matugen` and then runs
matugen for real — which re-renders every template on the machine and fires every
post-hook, including a compositor reload. So all three of the page's outside
connections are redirected: `ASTEROIDZ_MATUGEN_CONF`, `ASTEROIDZ_MATUGEN_TEMPLATE`
and `ASTEROIDZ_MATUGEN_BIN`, the last at a stub that records its arguments. That
stub is what makes "Apply re-renders the palette" checkable at all — the assertion
is a line in a file, not something on screen.

It found two real bugs. `applyAll()` read `Wallpaper.wallpaper`, which
does not exist — the singleton calls it `path` — so Apply wrote the template and
then silently skipped the render. Reading a wrong property name yields `undefined`
rather than an error, so nothing anywhere said so.

And the matugen-config wiring never ran: it set a flag and called `reload()`,
meaning to act in `onLoaded`, but a `FileView` with `preload: false` does not
re-emit for a reload the way a preloaded one does. Apply wrote the template, ran
matugen, reported success, and skipped the one step that makes matugen render the
template at all. It reads the file synchronously now.

Three of its own bugs are worth recording, all the same shape — a click that
misses looks exactly like a control that refused:

- a speculative "Apply does nothing when nothing has changed" click landed on a
  role **picker** and opened its dropdown, displacing every position measured
  afterwards. It could never have failed usefully either, so it is gone; the
  gating is asserted through the button's colour instead.
- turning a colour off hides its role picker, so the page gets shorter and Apply
  **moves**. It has to be re-located after the change, not before.
- Apply is accent-coloured when there is something to apply — and so is every
  ownership toggle that is on. "The lowest accent block" finds a toggle; the
  button row is left-aligned and the toggles are hard right, so the side is what
  tells them apart.

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
plugin, so the test does not depend on a reminder schedule existing on the
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
shell/settings/ the settings window, generated from the compositor's schema
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

### `Field.value`, never `Field.text`

Two properties, and binding the wrong one is a bug that looks like a rendering
glitch:

```qml
Field { value: Wallpaper.folder }        // right
Field { text: Wallpaper.folder }         // wrong
```

`text` is an alias to the `TextInput`, so typing assigns to it — which **breaks
any binding on it**, and the field silently stops tracking the value it is
supposed to be showing. Until it breaks, every external update resets the cursor
to the end of the line, so a value typed in comes out scrambled. `value` is copied
in only while the field is not being edited, and put back when it loses focus
without an Enter — which is the honest reading of a commit-on-Enter field: the
edit did not take.

`Slider` has the same split for the same reason: `value` is what the drag writes,
`target` is what you bind.

### A card's draft is seeded by being open, not by being tapped

`RuleCard` and `BindCard` copy the rule into an editable draft when they open. That
copy used to happen in the `TapHandler`, which is wrong because **a tap is one of
three ways a card ends up expanded**:

- you tap it;
- the page expands a newly added one itself;
- **every save rebuilds the delegates** — the page re-reads, the model array is
  replaced, and a card whose index is still the expanded one is *constructed*
  already open.

The last is the one that bites, because it happens every time you press Save. The
card came back with an empty draft and printed "This rule has no fields" under a
header listing them. Binding to `expanded` instead means there is one path and it
cannot be forgotten on another.

### `FormRow` reparents, so not inside a `Repeater`

`FormRow` does `control.parent = root`, which is fine at the top level and a trap
in a delegate: the control outlives the delegate that created it, so when the
model is re-evaluated the object survives with a dead JS context and every binding
on it starts failing with `Cannot read property 'round' of undefined` — `Math`
itself resolving to nothing. Anchor the label and the control directly instead;
`RuleFieldRow` and `BindCard.LabeledRow` both do.

### One `Ipc` call per shape of question

| | |
|---|---|
| `Ipc.watch(cmd, fn)` | a subscription; `fn` per update, starting with the initial state |
| `Ipc.request(cmd, fn)` | one command, one reply, then hang up |
| `Ipc.dispatch(cmd)` | fire and forget; no reply is read |

`request` exists because neither of the others fits a `get`: `dispatch` throws the
answer away, and `watch` holds the connection open forever for a reply that
already arrived. The compositor's end already behaves this way — a non-watch
command queues its reply, sets `closing`, and closes the fd once the queue drains
— so hanging up on the first line is agreeing with the contract, not guessing at
it.

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

A correction worth keeping, because the wrong version of it was committed
first. 16 `discord-voiced` daemons were also found, and read as a second-order
leak: `asteroidz-bar-discord` spawns the daemon and detaches it
(`start_new_session=True`, deliberately -- it holds a live voice connection), so
every orphaned plugin looked like it had left one behind. A guard was added
declining to spawn when a socket file already existed.

Both halves of that were wrong. **Thirteen of the 16 were bound to
`/tmp/asteroidz-hl-*/xdg/discord-voiced.sock`** -- litter from headless test
runs, each with its own `XDG_RUNTIME_DIR`, nothing to do with the bar. One more
was left by the lifecycle test's own pre-fix run. And `discord-voiced` **unlinks
a stale socket and rebinds it**: the stray was listening on exactly the path a
test had `bind()`ed and abandoned. So "a socket file exists" is the case where
spawning is the correct *recovery*, and the guard broke it. Reverted; see
`spawn_daemon()`, which now says so at length.

The transferable lesson is about measurement, not about Discord: **a process
census on a machine that has been running headless tests all day is mostly a
census of the tests.** Socket paths distinguished them; process names did not.

`contrib/plugin-lifecycle-test.sh` pins all of it with a pipe and no compositor.
It asserts each plugin *stays up while stdin is open* as well as exiting when it
closes — a plugin that died immediately would pass a naive "did it die" check.
Against the old code all three survive stdin closing; with the fix all three are
gone within 200ms.
