# asteroidzbg

Wallpaper daemon for wlroots compositors, with **HDR10 wallpaper support**.

## Provenance

asteroidzbg is a fork of [swaybg](https://github.com/swaywm/swaybg) by Drew
DeVault and the swaybg contributors, used under the MIT license (see
`LICENSE`, retained unchanged along with the original copyright notice).
Everything swaybg does, asteroidzbg still does, with the same command line.

Forked at swaybg 1.2.2 (`a59ea3d`).

## What's added

**HDR10 wallpapers.** If the image carries HDR colorimetry, asteroidzbg
decodes it at 10 bits per channel, uploads it in an `XRGB2101010` buffer, and
tags the surface through `wp-color-management-v1` so the compositor knows the
pixels are PQ-encoded and converts them correctly for the output.

| Format | Decoder | Detection |
| --- | --- | --- |
| AVIF | libavif | CICP transfer characteristics (PQ / HLG) |
| JPEG XL | libjxl | `JxlColorEncoding` transfer function |

An image is treated as HDR **only when its own metadata says so** — never
from a heuristic on the pixel data or the file extension. Anything else takes
the ordinary swaybg path (gdk-pixbuf, 8-bit, untagged), so SDR behaviour is
unchanged.

Both decoders are optional (`-Davif=disabled`, `-Djxl=disabled`). With both
disabled, asteroidzbg is functionally swaybg.

## Notes and limitations

- **Mastering metadata is not sent.** `wp-color-management-v1`'s
  `set_luminances` and `set_mastering_display_primaries` require manager
  features wlroots does not implement. It would be wasted effort regardless:
  compositors forward content mastering metadata to the display only for a
  single fullscreen scanout candidate, and a layer-shell wallpaper can never
  be one. The surface still gets correct BT.2020 + PQ tagging, which is what
  determines how it is rendered.
- **Scaling happens in the PQ-encoded domain**, not in linear light. This is
  what compositors and browsers do for display scaling; for a wallpaper the
  error is far below visible threshold.
- **`--color` is interpreted in the image's colour space.** When an HDR image
  is loaded, the background colour behind it is PQ-encoded, so a mid-grey
  will not look as it does in SDR. Solid-colour-only mode is unaffected.
- If the compositor does not advertise `wp-color-management-v1`, or does not
  support BT.2020/PQ, asteroidzbg falls back to the 8-bit SDR path rather
  than sending PQ pixels the compositor would misread.

## Building

    meson setup build/
    ninja -C build/
    sudo ninja -C build/ install

Dependencies:

* meson \*
* wayland
* wayland-protocols ≥1.41 \*
* cairo
* gdk-pixbuf2 (optional: SDR image formats other than PNG)
* libavif (optional: HDR10 AVIF)
* libjxl (optional: HDR10 JPEG XL)
* [scdoc](https://git.sr.ht/~sircmpwn/scdoc) (optional: man pages) \*
* git (optional: version information) \*

_\* Compile-time dep_
