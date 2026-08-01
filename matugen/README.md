# matugen

`asteroidz-colors.kdl` is the template matugen renders to
`~/.config/asteroidz/colors.kdl`, which asteroidz's config sources. The settings
window's **Palette** page edits which Material role each of the nine colours comes
from, and rewrites this file from that mapping.

## The scheme settings are CLI-only, and that matters

matugen's generation settings — `--type` (`scheme-vibrant`, `scheme-fidelity`, …),
`--mode`, `--contrast`, `--prefer` — **cannot** be put in `config.toml`. Writing
them under `[config]` is accepted without an error and then ignored; the output is
byte-identical to the defaults. So every caller has to pass them, and a caller
that forgets silently gets `scheme-tonal-spot`.

That is not a subtle difference. On one seed, **39 of matugen's 50 roles** differ
between `scheme-fidelity` and `scheme-tonal-spot`. And `matugen image` re-renders
*every* template in the config, not just this one — so two callers disagreeing
about the scheme means each one retones every themed application on the machine,
and whichever ran last wins.

The Palette page stores the four settings in `~/.config/asteroidz-bar/matugen.conf`
alongside the role mapping:

```
scheme.type=scheme-fidelity
scheme.mode=dark
scheme.contrast=0
scheme.prefer=saturation
```

**Anything else that runs matugen must read the same file.** A wallpaper script is
the usual second caller; the shipped one parses those four keys and falls back to
its own defaults when the file is absent.

### `--prefer` is not optional

Three of those four are preferences. `scheme.prefer` is a requirement, and there
is no "leave it unset" value for it.

When an image yields more than one candidate source colour matugen **asks** which
to use, and with nothing attached to a terminal it does not choose — it exits 1:

```
Multiple source colors found, no preference was inputted, and a terminal was not
detected. Use --prefer=PREFERENCE to find suitable colors without needing user
input.
```

Neither a settings window nor a wallpaper script run from a session has a
terminal, so omitting the flag is not a default, it is a guaranteed failure. It is
not limited to busy photographs either: a 64×64 single-colour PNG fails the same
way. An empty `scheme.prefer` is therefore treated as `saturation` rather than
dropped, in both the page and the script.

## The other applications

The Palette page lists every `[templates.*]` in your `config.toml` and lets you
leave any of them out of Apply. It does this by rendering a filtered **copy** of
the config to `$XDG_RUNTIME_DIR` and running `matugen -c` against it: matugen has
no way to render a subset, and rewriting the real file to drop a section would put
this page in charge of a file that themes your whole desktop.

Disabling is per-Apply, not permanent. The template stays in `config.toml`, so a
wallpaper change still renders it. If you want an application to stop being themed
altogether, remove its section from `config.toml` by hand — that is the file that
owns the question.

The package installs it to `/usr/share/asteroidz-bar/matugen/`. Nothing under
`~/.config` is written at install time — a package that wrote into your home
directory would overwrite a template you had tuned — so the copy has to be made
once:

```bash
mkdir -p ~/.config/matugen/templates
cp /usr/share/asteroidz-bar/matugen/asteroidz-colors.kdl ~/.config/matugen/templates/
```

The Palette page does this for you the first time you open it, if the file is not
there.

The Palette page also adds the entry below to `~/.config/matugen/config.toml` the
first time you press Apply, if no template there already points at
`asteroidz-colors.kdl`. It **appends** — that file configures every other themed
application on the machine, so a page that regenerated it would be a settings
window that can lose your whole desktop theme. The previous contents are kept as
`config.toml.bak`.

To do it by hand instead:

```toml
[templates.asteroidz]
input_path = "~/.config/matugen/templates/asteroidz-colors.kdl"
output_path = "~/.config/asteroidz/colors.kdl"
post_hook = "amsg dispatch reload_config 2>/dev/null || true"
```

`post_hook` is what makes the change visible: matugen writes the file and the
compositor re-reads it. Without it the palette changes on disk and the screen does
not, until something else reloads.

## Why the output is sourced rather than inlined

`colors.kdl` is rewritten on every wallpaper change. A generator that had to edit
`config.kdl` in place would have to understand `config.kdl`; sourcing means it
only has to write nine lines.

The `source` line is **last** in the shipped config on purpose. `source` is applied
in place and later declarations win, so anything set above it is overridden by the
generated file — which is what makes matugen the owner of those nine colours.
Turning one off in the Palette page drops it from this template, and whatever your
own config says wins again.

## A missing file is fatal

asteroidz treats a `source` it cannot open as a config error, not a warning. So
`colors.kdl` has to exist before the compositor starts — which is why asteroidz
installs a default one to `/etc/asteroidz/colors.kdl`, and why the quick-start
copies *both* files:

```bash
cp /etc/asteroidz/config.kdl /etc/asteroidz/colors.kdl ~/.config/asteroidz/
```
