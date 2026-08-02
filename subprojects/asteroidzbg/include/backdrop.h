#ifndef _ASTEROIDZBG_BACKDROP_H
#define _ASTEROIDZBG_BACKDROP_H

#include <stdbool.h>
#include <stddef.h>
#include <wayland-client.h>

/* asteroidzbg as a library: the wallpaper, drawn on somebody else's
 * connection.
 *
 * This is the same client swaybg was forked into -- layer-shell background
 * surfaces, shm buffers, 10-bit HDR pixels tagged through
 * wp_color_manager_v1 -- with its process removed. It does not connect to a
 * compositor, does not own an event loop and never blocks: the host passes in
 * the wl_display it already has and pumps it as it pleases, and this code
 * only ever creates proxies on it and answers events.
 *
 * That split is the whole point. The shell has to be the one holding the
 * connection (it is a Qt application; its display is Qt's), and the wallpaper
 * has to keep speaking colour management (Qt cannot). So the wallpaper moves
 * in as a guest.
 *
 * Threading: everything here except azbg_image_load() must be called on the
 * thread that dispatches the display. azbg_image_load() touches no Wayland
 * object at all and is meant to be run on a worker -- decoding a 4K AVIF
 * takes long enough to drop frames if it happens on the UI thread, which is
 * a cost the separate process never imposed on anyone.
 */

struct azbg_backdrop;

/* A decoded image, ready to be drawn. Opaque so the host does not have to
 * know about cairo or the HDR metadata. */
struct azbg_image;

/* Called when a Wayland event left work to do -- an output appeared, resized
 * or changed scale. The host is expected to arrange for
 * azbg_backdrop_flush() to run soon on the display's thread; calling it
 * directly from here would re-enter the dispatch that is already running.
 *
 * May be called several times before the flush happens. */
typedef void (*azbg_wake_fn)(void *user);

struct azbg_backdrop *azbg_backdrop_create(struct wl_display *display,
		azbg_wake_fn wake, void *user);
void azbg_backdrop_destroy(struct azbg_backdrop *bd);

/* Decode. No Wayland contact, no shared state: safe on any thread, and the
 * expensive half of putting up a wallpaper. NULL if the file cannot be read
 * or decoded by this build. */
struct azbg_image *azbg_image_load(const char *path);
void azbg_image_destroy(struct azbg_image *image);
bool azbg_image_is_hdr(const struct azbg_image *image);

/* Draw image across every output, in `mode` (stretch, fill, fit, center,
 * tile -- as asteroidzbg's -m). The image is borrowed, not kept: it is drawn
 * into a buffer here and the host may destroy it as soon as this returns,
 * which is what keeps a decoded 4K surface from sitting in the shell's heap
 * for the rest of the session.
 *
 * Returns true if the wallpaper went up as HDR -- 10-bit pixels, tagged with
 * their real transfer function and primaries. False covers both an ordinary
 * SDR image and an HDR one the compositor cannot be told about, which are
 * different situations with the same outcome: 8-bit sRGB. */
bool azbg_backdrop_present(struct azbg_backdrop *bd,
		const struct azbg_image *image, const char *mode);

/* The same, on ONE output, named as the compositor names it ("DP-1"). NULL is
 * every output, i.e. exactly azbg_backdrop_present.
 *
 * The surfaces are per-output already -- each has its own size, scale and
 * colour-management object -- so a different image per output costs nothing
 * structurally. What it does cost is a decode per distinct image, which is why
 * the caller groups outputs by path rather than calling this once per output
 * with the same file.
 *
 * Returns whether THIS image went up as HDR. An output whose name has not
 * arrived from the compositor yet cannot be selected by name, and matching
 * nothing returns false without drawing. */
bool azbg_backdrop_present_output(struct azbg_backdrop *bd,
		const char *output_name, const struct azbg_image *image,
		const char *mode);

/* The shared image, onto every output EXCEPT the named ones.
 *
 * For a wallpaper that is per-output: the outputs with an image of their own
 * must not be drawn with the shared one first, or they visibly flash it and
 * revert a decode later. An output whose name has not arrived from the
 * compositor yet cannot be named here, so it still takes the shared image --
 * which is the reason the shared one is drawn first at all. */
bool azbg_backdrop_present_except(struct azbg_backdrop *bd,
		const char *const *skip, size_t n_skip,
		const struct azbg_image *image, const char *mode);

/* The outputs that have a name, for a caller that wants to offer them: a
 * settings page cannot ask for "the wallpaper on DP-1" without knowing DP-1
 * exists. Indexed rather than handing back an array, so there is nothing to
 * free; the string belongs to the backdrop and lives until that output goes
 * away. */
size_t azbg_backdrop_output_count(const struct azbg_backdrop *bd);
const char *azbg_backdrop_output_name(const struct azbg_backdrop *bd,
		size_t index);

/* Deferred work: acknowledge configures and notice which outputs still have
 * no pixels. Returns true when an output is waiting for content, i.e. when
 * the host should load the current wallpaper again and present it.
 *
 * Returning "load it again" rather than caching the decoded image is
 * deliberate: outputs configure at startup and then almost never again, so
 * the alternative is holding tens of megabytes of decoded surface
 * permanently to save a decode that happens about twice a session. */
bool azbg_backdrop_flush(struct azbg_backdrop *bd);

/* True once the compositor has given us everything the wallpaper needs
 * (wl_shm, wl_compositor, zwlr_layer_shell_v1). Until then presenting is a
 * no-op, so the host can call it freely and let this settle. */
bool azbg_backdrop_ready(const struct azbg_backdrop *bd);

#endif
