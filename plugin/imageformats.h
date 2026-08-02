#pragma once

/* Which filename extensions the image decoder can read.
 *
 * A plain C interface on purpose, in its own translation unit, because
 * gdk-pixbuf's headers and Qt's cannot share one. Adding gdk-pixbuf's include
 * paths to the C++ side made Qt's own `#define signals Q_SIGNALS` fail to
 * compile -- the two carry colliding definitions, and the usual remedies
 * (#undef signals around the include, QT_NO_KEYWORDS) trade a clean boundary
 * for a fragile one. This way the C++ never sees a glib header.
 *
 * Returns a NULL-terminated array of lower-case extensions without the dot,
 * owned by the callee and valid for the life of the process. */

#ifdef __cplusplus
extern "C" {
#endif

const char *const *azbar_image_extensions(void);

#ifdef __cplusplus
}
#endif
