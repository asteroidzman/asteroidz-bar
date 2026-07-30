# matugen

`asteroidz-colors.kdl` is the template matugen renders to
`~/.config/asteroidz/colors.kdl`, which asteroidz's config sources. The settings
window's **Palette** page edits which Material role each of the nine colours comes
from, and rewrites this file from that mapping.

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
