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

### Restarting it

Find the running instances through quickshell's own registry, never by matching
a command line:

```sh
qs list --all
```

**A crashed-and-restarted bar has a different `argv` from the one you launched.**
Quickshell supervises its own shell: when the shell faults, the supervisor
writes a crash report and re-execs, and the replacement's command line is a bare
`/usr/bin/quickshell` with no arguments at all — no `-p`, no shell path. So
anything that selects processes by `qs -p .../asteroidz-bar/shell.qml` sees a
clean slate while a fully live bar is still drawing, still holding
`org.freedesktop.Notifications`, and still spawning plugins. That is how you end
up looking at two bars and a restart that reported success. `qs list --all`
shows both, keyed by instance id and shell id.

Two follow-on traps once you have the ids:

- **`qs kill -i <id>` kills the shell, not the supervisor.** The supervisor
  treats that exactly like a crash: it writes a report, pops the "Quickshell has
  crashed" dialog, and restarts the shell under a *new* instance id with the
  same pid. To actually stop a bar, signal the process itself.
- **A crash leaks the shell's children.** Graceful exit reaps them
  (see [Plugins have to die with the bar](#plugins-have-to-die-with-the-bar)),
  but a `SIGKILL`ed shell cannot, so every crash-restart cycle strands another
  generation of `asteroidz-bar-*` plugins and one `inotifywait` on `~/Pictures`.
  Four crashes left four watchers and some twenty unreaped zombies. Sweep them
  by explicit pid afterwards.

## How it talks to the compositor

One unix socket, newline-delimited JSON, the same one `amsg` uses
(`$ASTEROIDZ_INSTANCE_SIGNATURE`). State is pushed, not polled:

| subscription | what it carries |
|---|---|
| `watch bar-config` | the resolved theme: the palette, the font, border and corner metrics |
| `watch all-tags` | per-output tag occupancy and selection |
| `watch focused-client` | the focused window's title and app id |
| `watch all-monitors` | layout, geometry, per-output state |

`watch bar-config` used to carry this bar's whole appearance — sixty-two values
the compositor stored, clamped, described and served, and never once read. They
were there because the compositor used to *draw* the bar. They live in [the
bar's own config](#its-own-config) now.

What is left is the part that is genuinely the compositor's. The theme is
shared — titlebars, the overview and this bar all draw from it — and the
compositor is the only process that knows what it currently *is*, because
matugen rewrites it whenever the wallpaper changes. Being handed the file path
instead would mean two KDL readers that agree until one of them gains a
default, and it still would not see a palette written after startup.

## Its own config

`~/.config/asteroidz-bar/config.kdl` (or `$ASTEROIDZ_BAR_CONFIG`) — which
modules the bar draws, in which section, in what order, and on which output:

```kdl
modules {
	left   items="tags,layout,title" monitor=""
	center items="media,clock"       monitor="DP-1"
	right  items="volume,power"      monitor=""
}
```

That is the **bar's** business, not the compositor's — it draws none of it and
cannot. It used to arrive over `bar-config` for one historical reason: the
compositor used to draw the bar itself, so its config described one. What still
comes across the socket is what is genuinely compositor state — the palette, the
tags, the layout, the focused window — plus the geometry the compositor has to
agree with because it reserves the space.

KDL, so there is one config language on this desktop rather than two, but a
deliberately narrow slice of it: one node per section carrying properties.
There is no KDL parser in QML, and writing a general one to store three lists
and three strings would be a parser to maintain forever. What it writes is
valid KDL that the compositor's own parser reads back. Anything else in the
file is ignored rather than rejected, and a line it cannot make sense of leaves
that section at its default — a config file is not worth a bar that refuses to
draw.

Edit it by hand, or use the settings window's **Modules** page, which applies
as you change it. `monitor=""` is every screen.

## How big everything is

Two numbers, and neither of them lives in this file.

**`theme { font }`, in the compositor's config, sets the size of the bar.**
Every default in the shell — the bar's height, its margins, the padding inside
a pill, the panel's corner radius, a notification's width — is a multiple of
that font's pixel height, so raising the font grows the boxes around the text
instead of putting bigger text into boxes that stay where they are. One knob,
and it is the one you would reach for anyway. The multipliers live in
`Cfg.qml`; each is still overridable per key in `config.kdl` if you want a
taller bar than its type.

**The output's `scale` sets how big that is in real pixels.** Sizes here are
Wayland *logical* pixels, and the compositor multiplies a layer surface by the
scale of the output it is on — so a bar 48 logical pixels tall is 84 real
pixels on a display at `scale 1.75` and 36 on one at `0.75`, with nothing
configured per monitor. It is the same multiplication the compositor applies to
its own titlebars, which is why the two stay the size of each other.

The shell used to carry a *second* scale factor, in `Sizes.qml`: each output's
height over the tallest output's, so the bar was a fixed fraction of every
screen. It measured logical heights, which already contain the scale, so it
partly undid the scaling it sat on top of; and its reference was the whole
desktop's, so changing one monitor's scale resized the bar on all the others —
putting DP-1 on 1.75 made the bar on an untouched HDMI-A-1 half again as big.
It is gone. `contrib/bar-scale-test.sh` holds the ground it lost.

## Notifications

The shell is the notification daemon. It owns `org.freedesktop.Notifications`
itself — there is no swaync, no `swaync-client --subscribe`, and nothing extra
to install or supervise.

That subscription was the whole reason to change it. A notification reached the
bar third-hand — the sender told the daemon, the daemon told a long-lived
client process, the client wrote a JSON line to a pill — with a second process
spawned for every toggle and a retry timer for when the daemon was restarted
underneath it. The daemon also owned the history, the do-not-disturb flag and
what a notification looked like, three things that are this shell's business.

| | |
|---|---|
| **toast** | a card per notification, top-right just under the bar, on every screen — frosted and shadowed like every other panel, and carrying the sender's icon |
| **bell** | tinted with the accent while anything is waiting, and carrying the count — but not while quiet, where the crossed-out bell is the whole message |
| **centre** | left-click the bell: everything waiting, with **clear all** |
| **quiet** | right-click the bell, or the button in the centre |

Hovering a toast stops its clock — reading something is the clearest possible
signal that it should not be taken away mid-sentence — and it resumes when the
pointer leaves.

The toasts are frosted, one blurred region per card rather than one behind the
stack: the cards are 8px apart on a surface taller than all of them together,
and the wallpaper has to show through the gaps. They cast the same shadow the
bar's panels do — the space for it was always reserved and nothing drew one,
so they sat flat on the desktop while every other panel had depth.

**Every toast carries an icon**, resolved most-specific-first: the
`image-data`/`image-path` hint (artwork chosen for *this* notification — an
album cover, a contact's photo), then `app_icon`, then the `desktop-entry`
hint, then the application's own name as a theme lookup, and finally the
bundled bell. The theme lookups are *checked* rather than assumed, because a
miss has to fall through to the next candidate instead of drawing an empty box
— `Discord` finds `discord`, `notify-send` finds nothing. The box is a fixed
square with the artwork centred in it, since an icon's width is its advance and
a portrait one would otherwise change the text column's width.

`exclusiveZone: 0` on that surface does **not** mean "ignore the bar": it
reserves nothing of its own while still respecting what the bar reserved, so
the compositor has already placed it below the bar. Adding the bar's height to
the margin as well put the toasts a second bar's worth down the screen — 131px
on a 48px bar, when they should start at 75.

This works on a desktop with `effects { blur { layer #false } }`, which is the
common case. asteroidz treats a client-supplied region as an explicit opt-in
that overrides the global layer switch — *"a client region is an explicit
opt-in, an empty one an opt-out"* — and that is also how `panel { blur }` turns
the frost off: an empty region rather than no region, since an absent one would
fall back to the global switch. That setting had been read into `Cfg.panelBlur`
and used by nothing at all, so until now it did nothing anywhere.

**Quiet suppresses the popup, never the notification.** What arrives still
arrives and still lands in the centre.

The bell drops its count while quiet, though. The crossed-out bell already says
the state you chose, and a number beside it turns "I have silenced these" back
into "you have fourteen waiting" — the interruption in another form. The centre
still holds them and its header still counts them, which is where you go when
you want the number. A
notification dropped instead of quieted is one the person never finds out
about, and "do not disturb" is a statement about interruption rather than about
whether the thing happened. It persists across a restart, because someone who
silenced their notifications before a meeting does not expect a shell reload to
start shouting again.

The sender's own `expire_timeout` is honoured, including `0`, which the spec
defines as "until dismissed" — a failed backup or a password prompt should
still be there when you come back to the desk. Critical notifications default
to that too, and get a border in the urgent colour.

The capability flags the server advertises are a **contract**: an application
asks `GetCapabilities` and formats for the answer, so claiming `body-markup`
and then rendering the tags literally is how `<b>` ends up in front of someone.
Each one claimed is one the card honours.

Settings live under `notify` in [the bar's own config](#its-own-config):

```kdl
notify {
	timeout 5000        // ms, when the sender does not say
	max-popups 4        // oldest first out
	width 427           // unset: 20 ems of the theme's font
	icon-size 38        // unset: 1.8 ems
	centre-height 427   // the centre scrolls past this; unset: 20 ems
	dnd #false
	hide-over-fullscreen #true
	sound #false        // audible notifications, off unless asked for
	sound-name "message-new-instant"
	sound-theme "freedesktop"
}
```

or through **Settings → Notifications**, which writes the same keys and takes
effect as you move the sliders.

The three sizes are **font-derived when unset** — the card is about 45
characters of body text wide whatever size the theme is. Every other box in
this shell that holds text is sized that way (`FormRow`, `Picker`, `Pill`);
these were the exceptions, fixed at 380px against a smaller default font, so
raising the theme's size grew the text inside a box that stayed put. That is
also why *Reset sizes* **removes** the keys rather than writing today's numbers
back: a number equal to the current default is still a pinned number, and it
would stop following the font the moment the theme changed.

### Not over a fullscreen window

Toasts are on the **overlay** layer, so they draw above everything — a
fullscreen film or game included, where there is no way to dismiss one without
leaving what you are doing. So they are withheld there, per screen: a film on
one monitor leaves the other alone.

The notification is not lost. This hides the *popup* and nothing else, so it
still lands in the centre and the bell still counts it — the same contract
quiet has.

`is_fullscreen` only, never `is_fakefullscreen`: a fake-fullscreen window has
merely been *told* it is fullscreen and is still tiled with the bar above it,
so treating it as fullscreen would withhold notifications over an ordinary
window.

### Audible notifications

Off unless asked for — a desktop that starts making noise because it was
updated is worse than one that never made any. `sound #true`, or the toggle on
the settings page.

**A name, not a path.** `sound-name` is from the freedesktop sound-naming spec,
looked up through the installed sound theme and falling back to freedesktop's,
so it follows whatever theme is on the machine instead of hardcoding one
distribution's file layout. The lookup walks `XDG_DATA_HOME` and
`XDG_DATA_DIRS` for `sounds/<theme>/stereo/<name>.{oga,ogg,wav}`.

The spec's hints are honoured, in its own order of specificity:

| | |
|---|---|
| `suppress-sound` | the sender says stay silent — it has usually just made its own noise |
| `sound-file` | an exact file, played as given |
| `sound-name` | a themed name, looked up like any other |

and only failing all three is the configured default used.

**Quiet silences it too**, which is the point of quiet: a notification that is
quieted but still audible is not quieted.

Played with `pw-play`, which ships in **pipewire-audio** — anything with
working desktop audio already has it, so this adds no dependency. One
short-lived process per notification, which is the right trade for something
that happens a few times an hour, and fire-and-forget, so a missing player or a
busy sink cannot block the D-Bus call it is reached from.

Note that an application playing its *own* sound is beyond a notification
daemon's reach — it never goes near the notification protocol, and quiet cannot
silence it. That is a setting inside the application.

### From a keybind

swaync had `swaync-client -t`, so dropping swaync without an equivalent would
leave every existing `Super+n` binding silently doing nothing. The bind calls
the shell directly instead — no client process in between:

```kdl
Super+n { spawn "qs -p /usr/share/asteroidz-bar/shell.qml ipc call notify toggle"; }
```

| | |
|---|---|
| `toggle` | opens the centre, or closes it if it is already up; returns the monitor that answered |
| `quiet` | do not disturb, both ways; returns `quiet` or `audible` |
| `clear` | dismisses everything waiting; returns how many there were |
| `state` | the unread count, plus `quiet` when silenced |

`toggle` resolves the monitor itself, the same way `wallpaper nextFocused`
does: a key press does not know which screen you are looking at and the
compositor cannot pass it, since the bind spawns a command line and that
process has no notion of focus by the time it runs. The shell knows already.

The resolution happens once, in the service, rather than in each bar comparing
itself against `Compositor.focusedMonitor` — with every bar deciding for
itself, a moment when focus is unknown opens the centre on every screen at
once.

## Settings

The **asteroidz ship** on the bar — the chip leading the tags — opens a real
window with every configuration option the compositor accepts: 95 of them, each with the compositor's own
one-line explanation, grouped, searchable, and showing which file the current
value came from — plus the monitors, the wallpaper, the modules, the window
rules, the keybinds, the palette and push-to-talk.

There used to be a separate `display` pill for this, opening a popover that held
the monitors and the wallpaper with a button in its corner leading here. Both of
those are pages in this window now, the pill is gone, and the shell's own emblem
is the way in — where people look for a shell's own settings, the way a start
button works, and one fewer module competing for bar width. `display` in a module
list resolves to nothing now, which `ModuleLoader` says once and loudly.

A popover is dismissed by the first click outside it, and
every way of judging a display change — looking at another window, dragging
something onto the second screen, reading a frame rate off a game — is a click
outside it; the panel that let you change a mode could not survive you looking at
the result. It was also capped at 700px with nothing to scroll, so the wallpaper
browser was a 220px box inside a surface that could not grow.

Left click opens the window as such, on whatever page you left it on — All
settings the first time. Right click goes straight to Displays, which is what the
retired pill used to be.

### Displays and Wallpaper

These two are not schema-driven and do not go through `set-config`, which is why
they are hand-written pages rather than option groups. An output is hardware
state: it is applied by a dispatch (`set_output_mode`, `set_output_scale`,
`set_output_position`, `set_output_vrr`, `set_output_hdr`, `set_output_icc`) and
the compositor persists it itself, rewriting the `output` block in whichever file
already declares that monitor.

They also sit in **opposite apply models**, and each page says which it is in.
Displays stages everything behind its own Apply — it has to, because passing
*through* a resolution on the way to the one you wanted would mode-set to each,
and a mode set is a black screen for a moment. Wallpaper applies as you go, which
is the only way picking a wallpaper can work: you choose it by seeing it. The
window's global apply bar is hidden on both, because it promises "preview live,
Apply writes to disk" and neither page does that.

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

### One wallpaper, or one per monitor

The Wallpaper page has an **Applies to** choice: *One for all monitors* or *One
per monitor*. With the second, a strip of monitor names appears and whichever is
selected is what the browser below sets.

That is a switch, not something inferred from whether any override happens to
exist. Inferring it would mean the only way back to a single wallpaper is to
delete every per-monitor setting you have — which is exactly what you want kept.
So *One for all monitors* stops the overrides applying and **leaves them on
disk**, and switching back restores them.

**A monitor that is not plugged in keeps its setting.** The overrides live in
`wallpaper.conf` as `wallpaper.DP-1=…`, and the page lists any remembered
monitor that is currently absent, marked `(away)`, so it can still be seen and
changed while undocked. Nothing prunes them: an entry for a screen that is not
here is inert, not gone, and takes effect again by itself when that screen comes
back. For anyone who docks and undocks, that is the whole feature.

A prefixed key rather than a section or a second file, because `wallpaper.conf`
is a flat `key=value` that several other things also write — the cycle daemon, a
hotkey, `set-wallpaper.sh` — and a new shape would mean teaching all of them. A
key they do not recognise is one they leave alone.

Underneath, the surfaces were already per-output: each has its own size, scale
and colour-management object, so a different image per output costs nothing
structurally. What it does cost is a decode per *distinct* image, so outputs are
grouped by path and each file is decoded once however many monitors share it.
The shared wallpaper is drawn first, on everything, before the overrides go on
top — one redundant draw per overridden monitor at startup, in exchange for a
monitor whose name has not arrived from the compositor yet still having a
wallpaper instead of being black until `xdg-output` answers.

### The wallpaper stack is the shell, not five scripts

Cycling, applying and re-theming used to be `set-wallpaper.sh`,
`cycle-wallpaper.sh`, `wallpaper-cycle-daemon.sh`, `hdr-proxy.sh` and
`wallust-theme.py` — around 700 lines reading the same `wallpaper.conf` this
shell reads, to do work this shell was already doing. It draws the wallpaper in
its own process, keeps the folder listing current with an inotify watcher, and
runs matugen for the Palette page.

They were not merely redundant, they **disagreed**: the script passed
`scheme-fidelity` and the Palette page passed nothing, which means
`scheme-tonal-spot`, and 39 of matugen's 50 roles differ between the two — so
whichever ran last retoned the whole desktop. Duplicated state in a second
process is the cost, not the line count.

| was | is |
|---|---|
| `wallpaper-cycle-daemon.sh` + `cycle-wallpaper.sh` | a `Timer` over `Wallpaper.available` |
| `set-wallpaper.sh`'s matugen half | `Matugen.retheme()` on a wallpaper change |
| `set-wallpaper.sh`'s asteroidzbg half | already dead — the shell draws it in-process |
| `hdr-proxy.sh` | the convert-and-retry the Palette page already does |
| `wallust-theme.py` | gone; matugen is the themer |

`Super+y` no longer spawns anything:

```
Super+y { spawn "qs -p /usr/share/asteroidz-bar/shell.qml ipc call wallpaper nextFocused"; }
```

`nextFocused` rather than `next`, because a wallpaper is a per-monitor thing.
`next` advances the *shared* wallpaper, which a monitor carrying an override of
its own then ignores — so on a two-monitor setup with one overridden, `next`
looks like the keybind does nothing at all. `nextFocused` advances whichever
monitor has the focus, which is the one the person pressing the key is looking
at.

`wallpaper` exposes `next`, `nextFocused`, `nextOn <monitor>`, `set <file>`,
`setOn <monitor> <file>`, `current`, `currentOn <monitor>` and `monitors`.

Note the argument order in that keybind: `-p` is a top-level option *and* an
option of the `ipc` subcommand, so both `qs -p <shell> ipc call …` and
`qs ipc -p <shell> call …` reach a running instance, and neither launches a
second shell.

**Two things were deliberately dropped.** The script kept a *theme cache* keyed
by image identity, so revisiting a wallpaper restored the generated files
instead of re-running matugen — worth a second or two on a revisit, and not
worth reimplementing. And `themer=wallust` is gone entirely.

One trap this hit: matugen's scheme flags live in a mapping file the Palette
page loads *lazily*, so a re-theme fired by the cycle timer before anybody
opened that page would have used the built-in defaults — the same
retone-the-desktop bug, from the other direction. A re-theme that arrives early
now waits for the mapping and runs after it.

### Changing on its own, or not

**Change** is `random`, `sequential` or `static`, and **Every (min)** is only
shown for the first two — a period is meaningless when nothing cycles, and a
control that does nothing is worse than an absent one because it invites you to
set it and then ignores you.

`static` is a first-class choice rather than "set the interval to zero". Leaving
a wallpaper alone is an ordinary thing to want, and expressing it as an interval
made the way to say it "type a number into a field that then sits there claiming
to mean something".

The cycling itself is not done here — `wallpaper-cycle-daemon.sh` and
`cycle-wallpaper.sh` do it, reading the same `wallpaper.conf` — so both honour
`order=static`. In the daemon so it idles rather than waking, advancing and
being refused; in the cycler as well because that script is also what a hotkey
or a menu entry runs, and "next wallpaper" on a wallpaper set never to change
should do nothing rather than something.

### Dynamic wallpapers

An Apple dynamic wallpaper is one HEIC holding several images plus a timetable
saying which belongs to the time of day. Setting one picks the right frame and
switches it on a timer; the Wallpaper page says which frame is up and when the
next change is due.

Every ordinary decoder — gdk-pixbuf included — hands back the file's **primary**
image and nothing else, which is why such a file otherwise looks like a still.
So this reads the container with libheif: the schedule is a base64 binary plist
in an XMP property, `apple_desktop:h24` or `apple_desktop:solar`.

```
{ ti: [ {t: 0.0, i: 1}, {t: 0.2708, i: 2}, {t: 0.7292, i: 0} ], ap: {l: 2, d: 1} }
```

**`t` counts from local midnight.** That is what every other implementation
assumes, and the files bear it out: `0.2708` and `0.7292` are 06:30 and 17:30 —
sunrise and sunset. Read as fractions from noon they would be 18:30 and 05:30,
putting the daylight frame on all night.

Worth knowing: **the timetables in the wild are not all sane.** One of the two
files this was developed against schedules its *light* frame at midnight and its
dark one at midday, which is the file being authored wrong rather than anything
here. No attempt is made to detect or "fix" that — second-guessing a file's own
schedule would break every correctly authored one — which is exactly why the
page states the frame and the countdown, so a wallpaper that looks wrong is
diagnosable instead of mysterious.

`apple_desktop:solar` keys its table by the sun's altitude and azimuth instead
of the clock. That needs to know where on Earth the machine is — and the shell
does, from the shared location above, so such a file is read as written: the
sun's position is computed for here and now and the nearest entry wins.
Azimuth breaks the tie, because a solar table passes through every altitude
twice and altitude alone would run the sunset frame at dawn. Re-checked every
15 minutes rather than at a boundary, since the sun moves continuously.

If no location is known — nothing has asked for one, or the lookup failed — a
solar file falls back to the light/dark pair it also carries: light through the
middle of the day, dark otherwise. Said on the page, because an approximation
nobody mentions is indistinguishable from a bug.

Frames are extracted once into `$XDG_CACHE_HOME/asteroidz-bar/dynamic-wallpaper/`
and keyed by path, size, mtime and index, so replacing a wallpaper with a
different file of the same name does not keep showing the old one. Extraction
happens on the decode thread, never the GUI one — these are 6016×6016 images.

**The HDR path stops at the frame.** The extracted image goes through a PNG,
and the tagging that carries BT.2020/PQ to the compositor rides on AVIF/JXL CICP
boxes that PNG has nowhere to put. Apple's own dynamic wallpapers are 8-bit, so
nothing is lost on those; a 10-bit one would be drawn as SDR.

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

**A wallpaper matugen cannot read is converted and retried.** matugen decodes
what the Rust `image` crate decodes; the wallpaper browser offers what
gdk-pixbuf decodes, which is a strictly wider set. So once the browser stopped
hiding HEIC, a wallpaper you could see on screen became one this page died on —
`matugen failed (exit 101)`, a panic inside its colour extraction, with the
reason on a stderr nobody read.

The shell has a decoder that reads the file, because it is *drawing* the file.
So a failed run is followed by one conversion to PNG through that decoder and
one retry. Deliberately in that order, rather than checking the format first:
checking first means a list here of matugen's supported formats, which is the
same mistake the extension list was just fixed for — somebody else's
capabilities, copied, correct until they change. This way the first attempt is
byte-identical to a bare `matugen image <file>`, the conversion only happens on
a run that already failed, and if matugen gains HEIC the path stops being taken
with nothing to update. The decode failure happens before any template is
rendered or any post-hook fires, so the attempt that fails has changed nothing.

matugen's stderr is captured either way, so a failure that is *not* about the
format says what it was instead of only naming an exit code.

### Modules

Which modules the bar draws, in which section, in what order, and on which
screen. **Drag** a row to move it — within a section to reorder, or into
another section in one motion. The **▲▼** arrows nudge one place, the
**section** box sends a module elsewhere without dragging, and anything not
currently placed sits under **Not shown** to be added back.

Applied as you change it, like the Wallpaper page and for the same reason: the
only way to arrange a bar is to see it. There is no Apply here.

It writes the bar's own config file, not the compositor's — see
[Its own config](#its-own-config). A module can only be in one section at a
time, which is why the unplaced list is a difference rather than a full list
with some entries greyed out.

Two axes are stacked on this page and it is worth being explicit about which is
which: **Shown on** is the output the whole *section* is drawn on, and the
`left`/`center`/`right` box on each row is which *section* that module is in.
The second is captioned **section** because without a word over it, a box
reading `center` directly under a row reading `DP-1` is genuinely ambiguous.

The dragged row deliberately does not move. It dims in place and a line marks
where it would land, because moving the item reflows the column under the
pointer — which shifts the drop target while you are aiming at it. The drop
point flips at a row's *midpoint* rather than its edge, since the last few
pixels of a row already belong to the next slot, and an empty section grows to
a row's height and offers **Drop here** while a drag is in progress: a one-line
"Empty." label is far too small a target to be the only way into an empty
section.

The arrows stay alongside it. They move exactly one place, they are
unambiguous about what they did, and they are the only way to do any of this
from a keyboard.

### Layouts

Which layout a tag opens in, on which monitor, with the master factor, the master
count and the scroller proportions that layout reads. These are `tag` blocks in
the config, and until this page existed they were reachable only by editing the
file by hand: `set-config` writes *options*, and a tag rule is not one — it is a
block with an identity, addressed by index, exactly like a window rule.

So the page is built like the window-rule page rather than like an option group:
from `get tag-rule-schema` and `get tag-rules`, one collapsed card per rule,
showing only the fields that rule sets, saved per card. The reasoning under both
of those is the same and is written out below.

The list is in **file order, not tag order**, and the page says so. Rules apply in
order and a later one wins, so sorting the nine cards by tag number would produce
a list in which a rule's position no longer explains the layout a tag ends up in.

A card reuses `RuleFieldRow` unchanged: a tag rule and a window rule are different
vocabularies over the same shape, and the tag schema names its types with the same
words (`enum`, `tristate`, `int`, `float`). Nothing in the card knows what `mfact`
means.

If the compositor predates `get tag-rule-schema` — the bar and the compositor are
separate packages, and one can be upgraded without the other — the page says that
outright. An empty list would read as "you have no tag rules", which is a
different and much more alarming statement.

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

## The cursor

Anything that acts on a click asks for the pointer cursor: pills, popover rows
and their steppers, toggles, pickers, sliders, buttons, card headers, wallpaper
tiles. Text fields ask for the caret instead, because `selectByMouse` means
there is text to drag across as well and `TextInput` sets no cursor of its own.

Two of those are worth writing down.

**`interactive` is what a Pill knows about whether pressing it does anything**,
and it defaults to true — so the clock, which has no `onClicked` at all, was
claiming to be a button. It now says `interactive: false`, which also stops it
swallowing clicks meant for the menu-dismissal catcher underneath.

**A disabled MouseArea still applies its `cursorShape`.** `enabled: false` stops
it reacting to a press, and it looks as though the cursor should follow, but Qt
sets the item's cursor regardless — the clock kept turning the pointer into a
hand. So the shape is written out as a condition rather than left to `enabled`:

```qml
cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
```

Everywhere else the shape goes on a `HoverHandler`, not the `TapHandler` beside
it: a `PointerHandler` applies its `cursorShape` while it is **active**, and a
TapHandler is active only while the button is held — a cursor that changes after
you have already committed to pressing.

## Blur and shadows

Blur is the compositor's (`ext-background-effect-v1`): the shell reports the
exact region its panels occupy, corner radii included, and asteroidz blurs
behind it. A transparent surface with three rounded slabs on it therefore gets
blur under the slabs and nothing between them.

Shadows are the shell's own. asteroidz will put a layer shadow behind the whole
surface, but the surface spans the output — that would be one shadow around all
three sections including the gaps between them.

## Sound

`volume` in a module list. The pill shows the level and takes a wheel; a middle
click mutes; a left click opens a panel.

The panel is **DankMaterialShell's audio panel, ported** — their
`AudioSliderRow.qml`, `InputAudioSliderRow.qml` and the two
`ControlCenter/Details/Audio*Detail.qml` — in this shell's colours, fonts and
radii. A master row whose icon is the mute button and whose slider carries the
reading, the outputs as cards with the active one outlined, the microphone with
its own row and its own device list, and every stream that is actually playing
with a slider of its own. Picking a device sets the **default** rather than
moving what is already playing, which is what `pactl set-default-sink` does and
what people mean by choosing an output.

**Input is in the same panel, not behind a tab.** DankMaterialShell keeps
output and input in two detail views because its control centre is a
full-height surface with room for both; this is a popover with a height cap.
A tab would also hide the one control here that is reached in a hurry — muting
a microphone is not something you go looking for a second click to do. The
whole microphone section is absent on a machine with no input at all, rather
than present and dead.

It replaces a menu that listed the sinks and stopped there: the level was
readable only off the pill, setting it meant a wheel gesture with no visible
target, and what an individual application was playing at was not shown at all.

Two things in their panel are deliberately not here. **Device pinning** is a
preference stored in their cache for choosing a default automatically, and
nothing in this shell would read it. **Per-device artwork** — a headset, a
television, a speaker — is a symbol font in their shell and illustrated SVGs in
this one, so there is no glyph to draw; the outline and the word *Active* carry
it instead.

Everything comes from PipeWire directly. `Quickshell.Services.Pipewire` binds
the node graph, so a volume is a property to watch rather than a `pactl` to
fork — but a node reports whatever it held when it was first seen until
something binds it, so the panel tracks every sink and stream it draws. An
untracked row is a slider that never moves, which looks exactly like a slider
that does not work.

The slider itself is `shell/Slider.qml`, which the settings window already had:
it moved up out of `shell/settings/` rather than being written twice, and gained
a unit suffix and an optional wheel. The wheel is off by default because a
settings page scrolls, and a slider that changed a value instead of scrolling
past it would edit settings you were only trying to read.

`contrib/audio-test.sh` covers the frame of it. The headless compositor has its
own `XDG_RUNTIME_DIR` and therefore no PipeWire, so there are no sinks to list:
what it checks is that the click opens a panel with a **slider track** in it,
measured as a rule at least four pixels thick. Width alone proved nothing — the
menu this replaced drew a separator the full width of the panel, one pixel
thick, and the first version of the test called that a slider and passed on a
build that had no slider in it.

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

## The clipboard

`clipboard` in a module list. The last hundred things you copied, searchable,
with Enter to put one back.

**There is no `cliphist`, no `wl-paste --watch`, and no daemon.** The history is
read directly off `ext-data-control-v1` by the C++ plugin, on the shell's own
Wayland connection — that protocol exists precisely so a privileged client can
watch every selection *without* holding keyboard focus, which is what rules out
the ordinary `wl_data_device` route for a bar that never has focus. The history
is a list in this process; the backend is a listener, not a second program to
install and supervise.

It records text and images. Anything else — a file list, an application's
private format — is passed over rather than stored as bytes nobody could paste
back usefully. The **primary** selection is deliberately not recorded: it
changes on every drag of the mouse across text, so a history of it is noise.

**Pausing stops recording and nothing else.** What is already there stays, and
the clipboard itself keeps working — the distinction that matters when you are
about to paste a password. Right-click the pill, or `ipc call clipboard pause`.
The pill dims while paused, because that is the state you turned on for a
reason and will forget.

Copying the same thing twice moves it to the top rather than adding a second
row. Putting an entry back is itself a copy, so the compositor echoes it
straight back at us — dedupe against what we last set is what stops that
becoming a duplicate.

```kdl
clipboard {
	width  24    // ems; wider than the notification centre on purpose
	height 22    // ems of list before it scrolls
	limit  100   // entries kept. Each is held whole, images included
}
```

Bound to a key, which is how it will actually be used:

```kdl
Super+v { spawn "qs -p /usr/share/asteroidz-bar/shell.qml ipc call clipboard toggle"; }
```

`toggle` opens it on the focused monitor only — every bar sees the signal and
compares, or the panel opens on all of them at once. `pause` and `clear` are
there too.

## The calendar

Click the clock. A month you can page through, and the day you picked written
out underneath — that is the whole panel.

There is no `calendar` module: the clock *is* the calendar's pill. A bar that
shows you the date and a bar that shows you what is on that date are the same
button, and two of them side by side would be one too many.

**It replaced `dcal`, and does not need it.** Google Calendar is spoken
directly by the C++ plugin — credentials out of the Secret Service, token
refresh and the API over `QNetworkAccessManager`. dcal's login was *migrated*
once into this shell's own keyring items rather than copied by hand, so
uninstalling dcal cannot take the account with it.

What it deliberately is **not** is a sync engine. No local store, no
incremental sync tokens, no write access. It fetches a window and holds it,
because a bar answers "what is on today" and not "let me reorganise December".
The single line doing the most work is `singleEvents=true`: Google expands
recurrences server-side and returns concrete instances, which is the difference
between this and a calendar library.

The scope asked for is **read-only** (`calendar.readonly`). Nothing here
creates or edits an event, and asking for write access to display a fortnight
is a permission you would be right to refuse.

Paging past the fetched window widens it rather than showing you an empty
month. That distinction matters more here than anywhere else in this shell: a
month with no dots has to mean "nothing on", never "not fetched".

```kdl
calendar {
	width         21    // ems; the month grid drives this, not taste
	agenda-height 11    // ems of agenda before it scrolls
	horizon-days  60    // how far ahead to fetch before you page
}
```

### When the login expires

It will. Google expires or revokes a refresh token eventually — it happened to
dcal, which is how this project started.

When it does, the panel says so and grows a **Reauthorise** button. Pressing it
opens your browser at Google's consent screen; the shell listens on an
ephemeral loopback port, checks `state`, exchanges the code with PKCE and
stores the new token. There is no other program to run.

The button is hidden while the login works, which is right — one sitting in
your face when nothing is wrong is noise — but it also means the path cannot be
rehearsed. So it can be summoned:

```sh
qs -p /usr/share/asteroidz-bar/shell.qml ipc call calendar showAuth   # reveal it, until restart
qs -p /usr/share/asteroidz-bar/shell.qml ipc call calendar authorize  # skip the button
qs -p /usr/share/asteroidz-bar/shell.qml ipc call calendar sync
qs -p /usr/share/asteroidz-bar/shell.qml ipc call calendar status
```

`showAuth` is session-only and deliberately not a config key: it is a way to
test a button, not a preference. While revealed on a healthy account the button
reads **Reauthorise (test)**, because calling it anything else would be a label
lying about the state.

Running `authorize` while the login is *healthy* is safe, and worth doing once:
Google issues a new refresh token and the old one keeps working until it does,
so a failure mid-flow leaves you exactly where you were. Far better to find out
it works on a Tuesday than the morning the token dies.

`status` reports counts and flags only, never event contents — it is meant to
be safe to paste into a bug report.

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

### Where the machine is

Plugins are told, unasked, as an ordinary event:

```json
{"event":"location","lat":52.52,"lon":13.405,"place":"Berlin, Germany"}
```

Sent when a continuous plugin starts and again whenever the answer changes. A
plugin that does not care ignores an `event` it does not recognise, which they
all already do.

It exists because more than one thing needs it: the weather module has always
wanted a latitude, and a `solar` dynamic wallpaper cannot be placed without one.
Three consumers geolocating separately would be three IP lookups a session and
three chances to disagree about where you are — so the shell resolves it once
(`Location.qml`) and hands it out. A plugin wanting sunrise, a tide table or a
local forecast no longer has to do it for itself.

Resolved from `bar { weather-location "..." }` if it is set, because a stated
answer beats a guessed one, and by IP otherwise. Cached to
`$XDG_CACHE_HOME/asteroidz-bar/location.json` so a cold start knows where it is
without waiting on the network; the lookup still runs and overwrites it, since
the one thing worse than not knowing where you are is being certain of
somewhere you left.

Nothing here triggers a lookup on a wallpaper's account — the wallpaper uses the
location only if something already asked for it.

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
contrib/look-test.sh       # panel geometry: hidden modules, pinned pills, the
                           #   shadow, the ship, and a section drawn only on the
                           #   output it names
contrib/battery-test.sh    # the battery module, against a fake sysfs: absent on a
                           #   machine with no cell, present and tracking on one
contrib/wallpaper-test.sh  # the wallpaper, drawn in-process, HDR path included,
                           #   and one per monitor against a second output the
                           #   compositor is asked to create mid-test
contrib/tray-test.sh       # the tray, on a private D-Bus session, against
                           #   contrib/snitem -- a stand-in StatusNotifierItem,
                           #   so the answer does not depend on whether Steam
                           #   happened to be running. Build it first:
                           #   `cd contrib/snitem && make`
contrib/media-test.sh      # the media module, with a player and no sound
contrib/notify-test.sh     # notifications end to end: the shell takes the bus
                           #   name, a real Notify call tints the bell and puts a
                           #   popup on screen, and each one gets its own card
contrib/notify-blur-test.sh # the toasts are frosted, measured over a STRIPED
                           #   wallpaper as the loss of that contrast, with the
                           #   same shot at `panel { blur #false }` as the
                           #   control. Separate from notify-test because blur
                           #   is invisible on the flat backdrop that test uses
contrib/click-test.sh      # what the bar DOES when clicked: popovers open and
                           #   dismiss, plugin menus, plugin forms and their
                           #   fields, the power menu's confirmation, and the
                           #   cursor shape over a pill that acts against one
                           #   that only reads out
contrib/panel-layout-test.sh # the settings window's boxes fit the text in them,
                           #   at three font sizes
contrib/toast-shadow-test.sh # a toast's shadow fades out rather than being cut
                           #   off square at the layer surface's own edge,
                           #   measured as the biggest single-pixel step across
                           #   the shadow (1 when it fits, 4 when it is clipped)
contrib/picker-test.sh     # an open dropdown is inside the window it belongs
                           #   to. Run at output scale 1.75, which is the shape
                           #   that made the Displays page's Scale list fall off
                           #   the bottom entirely
contrib/bar-scale-test.sh  # sizing: two outputs running the same mode at
                           #   different scales draw bars whose REAL heights
                           #   differ by exactly that scale, changing one
                           #   output's scale leaves the other's bar alone, and
                           #   the theme font is what resizes it
contrib/audio-test.sh      # the volume pill opens the sound panel, with a
                           #   slider track in it rather than the old menu's
                           #   one-pixel separator
contrib/palette-test.sh    # the matugen palette page, fully sandboxed: its
                           #   template, mapping file and matugen binary are all
                           #   redirected, so it cannot re-theme the desktop it
                           #   runs beside. The stub can be told to refuse a
                           #   format, which is how the convert-and-retry path
                           #   is reachable without a HEIC encoder
contrib/settings-test.sh   # the settings window: the pill opens it on Displays,
                           #   it is populated, search narrows it, a click
                           #   previews, Apply persists, closing undoes an
                           #   unapplied preview, the Displays page stages and
                           #   its Apply commits, the Wallpaper page writes as
                           #   you type, the rule, bind and tag editors add
                           #   through to the config file, the Modules page
                           #   builds, every module it offers can actually be
                           #   drawn, a click writes the config and a SECOND
                           #   click still does, dragging reorders and crosses
                           #   sections, and Rebind… reaches the push-to-talk
                           #   bridge
contrib/plugin-lifecycle-test.sh # a plugin dies with the bar that started it
contrib/dynwall-test.sh    # Apple dynamic wallpapers: the schedule parser
                           #   against synthesised plists, and frame extraction
                           #   against a HEIC built by the test. No compositor,
                           #   and pinned to no particular wallpaper
contrib/reminders-test.sh  # the reminders plugin's scheduling, as pure logic:
                           #   no Wayland, no bar. An interval read under the
                           #   wrong key made every reminder daily, and nothing
                           #   that clicks on things could see it
                           #   (no compositor needed; runs in seconds)
contrib/discord-ptt-test.sh # the push-to-talk bridge: the app id resolves, the
                           #   portal offers the signals, and the rebind path
                           #   writes what it claims to (sandboxed XDG, no
                           #   compositor, no Discord)
```

### The wallpaper browser

The folder is scanned at startup, whenever it changes, and every time the page
opens — and **watched** in between, through `inotifywait`. A poll would be a
`find` over the directory every few seconds forever, for an event that happens a
handful of times a day, and would still be late by up to its own interval; this
is idle until the kernel says something changed. A burst is debounced into one
rescan, because copying fifty files in emits fifty events while the directory is
still being written to.

`inotify-tools` is an *optdepend*: without it the watcher process simply fails to
start and the scan-on-open path carries on, so the browser is merely less
immediate rather than broken.

The scan used to run **only** from `onFolderChanged`, and `folder` starts at
`~/Pictures`. A `wallpaper.conf` with no `folder=` line — the common case, since
nothing else writes one — never changed it, so the browser was empty forever
rather than stale. Setting `folder` by hand to the value it already held did not
help either, which is the give-away: assigning a property its current value is
not a change.

### The battery

`battery` reads `capacity` and `status` straight from
`/sys/class/power_supply`, polled on the bar's own tick. No upower, no D-Bus: a
daemon in between would be a dependency, a service that has to be running, and a
second description of what those two files already say.

There is no directory listing in QML, so the battery's name is asked for rather
than discovered — `BAT0`–`BAT2`, `CMB0`, `macsmc-battery`, which is what Linux
actually uses. Anything else reports no battery, which is the same outcome as
having none: **the pill is absent**, not drawn empty and not drawn at zero. A
desktop showing a permanently full cell is saying something false about hardware
it does not have, and one showing 0% is saying something alarming. The idle cup
hides itself on the same principle.

`Paths.resolve` caches misses as well as hits, so a machine that *gains* a
battery after the bar starts keeps saying it has none until the bar restarts.
That is a laptop having its cell replaced, not a case worth a filesystem scan
every tick.

`Charging`, `Discharging`, `Full` and **`Not charging`** are four states, not
three: the last is a plugged-in laptop holding at its charge limit, and calling
it discharging would put a draining icon on a machine sitting on mains. The
popover shows the kernel's own word rather than a translation of it.

The reading lives in a `BatteryService` singleton, named that way for the reason
`IdleService` is: a singleton and a module of the same name are ambiguous to
anything importing both directories, and `ModuleLoader` imports both. QML reports
that as *"Type ModuleLoader unavailable"* — the whole bar simply absent, four
levels from the cause.

**It is tested on a machine with no battery**, which is the only reason it is
tested at all: `BatteryService` takes its root from `ASTEROIDZ_BAR_BATTERY_DIR`
and `contrib/battery-test.sh` writes a directory of real `capacity`/`status`
files into it. Nothing there fakes an interface the kernel does not have — sysfs
is two small files and the module re-reads them on a timer.

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
every one of those readings was wrong.

It used to open the display pill's popover and drive the form inside it. That
popover is gone, so those assertions went with it rather than being pointed at
something else, and the ones that were never about displays moved: the
open/Escape/toggle/click-away group now drives the **power** pill, which is a
pill with a menu on it and nothing more, and the staged-vs-applied and
wallpaper-field checks are in `settings-test.sh` against the pages that inherited
them.

One deleted check is worth recording, because the bug it guarded is still real
and is simply no longer reachable from the bar. A popover that resizes while it
is mapped can hang the client outright: Qt and quickshell each send an
`xdg_popup.reposition` with its own token, xdg-shell lets the compositor "skip
all but the last one", and Qt never paints again once its token goes
unanswered — it just leaves the previous frame stretched over the new surface
size. The panel still grows, so a size assertion alone passes on the broken
build; only the glyph height gives it away. `Popover.qml` keeps the surface a
fixed box and moves the panel inside it. The only control that grew a popover
while mapped was the display panel's `Picker`, and no popover has one now — a
`Picker` in the settings window is in a toplevel, where resizing is free.

`click-test.sh` still covers the thing that made **every text field in a panel
inert** — at the time, Folder and Cycle on the Wallpaper tab and the Display
tab's ICC path; today, a plugin's form fields, which is where that keyboard path
still runs.
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
`activeFocus`, which in a popover depends on whether the *popup's* window is
active — so it appeared and vanished for reasons having nothing to do with where
the keys were going. `Field` draws an accent outline, brightens its fill, and
forces the caret on, all keyed to `keysHere`, which answers with the popover's
`keyTarget` in a popover and with Qt's own focus in an ordinary window. A `⏎`
appears at the right edge while the field is focused *and* changed, so the
instruction shows up exactly when it is actionable.

That assertion lives in `settings-test.sh`, not here, and the move is a fact
about the shell rather than a preference: **every `Field` in it is now in the
settings window.** A plugin form row is not one — it is a label and a value
`Text` with a `▌` appended, because a row is a plain object a module hands the
popover — so measuring the outline on a focused plugin row reported four pixels
of accent, which is the caret.

The two pages that came out of those tabs are in **opposite models**, which
nothing used to say, and each states its own — "Changes wait for Apply" against
"Applied as you change them · press Enter in a field to apply it". Two opposite
models in one window is fine; two opposite models with nothing saying which is
which is not, and it was reported as "there is no apply button so it's not clear
how to apply the settings".

The Wallpaper page's real assertion is that **`wallpaper.conf` changed**, not
that pixels moved: nothing else writes `folder=`, so a mis-aimed click can only
make it fail, never falsely pass.

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

`panel-layout-test.sh` checks the other half: not what the window does, but
whether its boxes fit the text in them. The display tabs were `width: 100` with
a centred `Text` carrying no width, no elide and no clip, so at the shipped
theme "Wallpaper" overflowed its pill on both sides, ate the gap to the tab
beside it, and was painted over by that tab's fill — reported as two bugs, text
cut off and tabs touching, from one cause.

Those tabs are gone; the bug they were made of is not, because it is not about
tabs. So the test follows the UI rather than the widget: it opens the settings
window and measures the header's **Close** button, which `SmallButton` sizes from
its label — the component exists for this, and its header comment names the
`width: 84` buttons it replaced. The tab-row assertions are deleted rather than
reworded, because a test kept alive by pointing it at something else is how a
suite ends up reporting on pixels nobody chose.

It runs at **three font sizes on purpose**, and that is the whole design. Every
bug of this kind is a fixed pixel constant meeting a theme-sized glyph, so a
test at one font size tests the one case that happened to fit: run against the
old code it passed cleanly at `Ubuntu 11`, where "Wallpaper" really does fit
inside 100px, and failed at 16 and 24. Anything sized from a constant now comes
from `Cfg.fontPixelSize` instead, which is what `FormRow` and `Picker` were
already doing. The window is re-themed with itself open, so this is also the
assertion that it relays out rather than keeping the metrics it was built with.

It also checks that the arrangement canvas does not sit on its own
"drag to arrange" hint. `zoom` is `min(width/bounds, height/bounds)`, so
whenever the layout's bounding box is proportionally narrower than the canvas
the zoom is height-limited and the tiles use every vertical pixel there is —
the 15% breathing room came to ~11px at the bottom while the hint needs ~17px
with its margin. `Arrange` now reserves a band for the hint and lays the tiles
out in what is left.

Three things about how it measures, all learned the hard way.

The accent tolerance is tight (14, not 30) because white text on a dark fill is
subpixel antialiased and its blue fringe lands within 30 of the accent on every
channel — a loose match reported the far edge of the *next* label as this box's
right edge.

A box is measured on the row carrying the **widest** run, not the middle row:
the middle row runs straight through the label, so the fill is interrupted by
every glyph and the longest unbroken run is the space between two letters.

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

`notify-test.sh` sends a REAL notification over D-Bus, on the harness's private
bus, because the shell is the daemon now -- there is nothing left to stub, and
a call that reaches the bus name is the only thing that proves it was taken.
The bell was once reading a subscription that never updated, and a stub that
only ever reports one count would pass
while being just as broken.

`parity.sh` gates on **geometry** — panel extents and every pill border
position — not on pixels. Pango and Qt never agree to the last subpixel, so a
pixel gate strict enough to catch a layout bug would fail forever on
antialiasing. Pixels are still compared, loosely, to catch a blank section or
artwork that failed to load.

`tray-test.sh` runs on its own bus deliberately: quickshell hosts
StatusNotifierItem on whatever bus it finds, so a test against the real one
would pick up Steam and Discord and pass whether or not the code works.

### Tray icons are normalised by weight, not by box

Every icon in the tray is fitted into the same square, and they still do not
read as the same size. Measured on a live bar: 15x15 and 17x14 inside an
identical advance, and the smaller one looked bigger — because it was a solid
filled block covering 72% of its canvas next to a sparse logo covering 63%, and
a box is not what the eye measures. That difference is in the artwork, which is
supplied by arbitrary applications, so no layout arithmetic in QML can reach it.

So `image://opticalicon/<box>/<url>` measures the ink and scales by
`sqrt(target / coverage)` — the factor that equalises AREA rather than extent,
which is the correction a designer applies by hand when a set mixes solid and
open shapes. It brought those two from 15% apart in ink to 1.6%. Shrink only:
growing an icon past the advance the pill already reserved would push the bar's
layout around as tray items come and go.

Two things about it are worth keeping in mind.

The target coverage is **measured, not reasoned**. The first value was 0.75,
picked from what a well-drawn 16px-grid icon ought to cover — and it sat above
every icon in a real tray, so each one scored "already fine", the provider
returned its input untouched, and a correctly wired feature was
indistinguishable from a broken one. `ASTEROIDZ_BAR_ICON_DEBUG=1` prints what
each icon measures; that is how 0.62 was chosen.

And the provider is installed from the `Paths` singleton's factory, not from
`QQmlExtensionPlugin::initializeEngine`. That override compiles, is present in
the plugin, and quickshell's engine never calls it — the tray logged `Invalid
image provider` for every icon and drew them unnormalised. A singleton is
constructed on first access, and `Paths.opticalIcon()` is what builds the URLs,
so the provider cannot be missing when one is used. `tray-test.sh` now treats
that warning as an error, because nothing else did.

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
