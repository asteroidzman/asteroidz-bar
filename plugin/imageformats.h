#pragma once

/* The image decoder, reached from the C++ side without a glib header.
 *
 * A plain C interface on purpose, in its own translation unit, because
 * gdk-pixbuf's headers and Qt's cannot share one. Adding gdk-pixbuf's include
 * paths to the C++ side made Qt's own `#define signals Q_SIGNALS` fail to
 * compile -- the two carry colliding definitions, and the usual remedies
 * (#undef signals around the include, QT_NO_KEYWORDS) trade a clean boundary
 * for a fragile one. This way the C++ never sees a glib header.
 */

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

/* Which filename extensions the decoder can read.
 *
 * A NULL-terminated array of lower-case extensions without the dot, owned by
 * the callee and valid for the life of the process. */
const char *const *azbar_image_extensions(void);

/* Decode `src` and write it to `dst` as a PNG, no larger than `max_edge` on its
 * long side (aspect preserved; an image already smaller is not enlarged).
 *
 * For handing an image to a tool whose decoder is narrower than this one's.
 * matugen reads what the Rust `image` crate reads, which is not HEIC -- and
 * since the wallpaper browser now offers everything gdk-pixbuf can draw, a
 * perfectly good wallpaper is one matugen can panic on. Rather than keeping a
 * table of somebody else's supported formats, which is wrong the moment they
 * add one, the caller converts and retries.
 *
 * Returns true on success. On failure `err` (if non-NULL) is set to a
 * heap-allocated message for the caller to free. */
bool azbar_image_to_png(const char *src, const char *dst, int max_edge,
                        char **err);

#ifdef __cplusplus
}
#endif
