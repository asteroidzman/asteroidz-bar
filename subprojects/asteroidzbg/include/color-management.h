#ifndef _ASTEROIDZBG_COLOR_MANAGEMENT_H
#define _ASTEROIDZBG_COLOR_MANAGEMENT_H

#include <stdbool.h>
#include <wayland-client.h>

#include "hdr-image.h"

/* All wp-color-management-v1 contact is confined to this file so a second
 * backend (frog-color-management-v1, for compositors that only speak that)
 * can be added without touching main.c. */

struct cm_state {
	struct wp_color_manager_v1 *manager;
	/* The compositor advertises which primaries and transfer functions it
	 * can accept; asking for one it did not advertise is a protocol error
	 * that kills the client, so both are checked before use. */
	bool supports_bt2020;
	bool supports_pq;
	bool supports_hlg;
	bool supports_parametric;
};

/* Called from the registry handler for each global. Returns true if it
 * consumed the global. */
bool cm_state_handle_global(struct cm_state *cm, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version);

void cm_state_finish(struct cm_state *cm);

/* True when the compositor can accept the colorimetry this image carries. */
bool cm_can_represent(const struct cm_state *cm, const struct hdr_image *image);

/* The per-surface colour-management object, created ONCE and kept for as long
 * as the surface lives.
 *
 * Not created per frame: get_surface raises the protocol error surface_exists
 * if one already exists for that wl_surface, and -- worse -- DESTROYING one
 * "does the same as unset_image_description", so a create/set/destroy cycle
 * around a single commit cancels the very tag it just applied. Returns NULL if
 * the compositor has no colour management. */
struct wp_color_management_surface_v1 *cm_surface_create(struct cm_state *cm,
		struct wl_surface *surface);
void cm_surface_destroy(struct wp_color_management_surface_v1 *cm_surface);

/* Tag the surface with the image's colorimetry, or UNTAG it when the image is
 * not HDR -- a wallpaper that changes from an HDR file to an SDR one has to
 * drop the old description, or sRGB pixels keep being read as PQ.
 *
 * Blocks until the image description is ready: the protocol forbids passing a
 * description that has not emitted `ready` to set_image_description. Returns
 * false if the tag could not be applied, so the caller can fall back to SDR. */
bool cm_apply_to_surface(struct cm_state *cm, struct wl_display *display,
		struct wp_color_management_surface_v1 *cm_surface,
		const struct hdr_image *image);

#endif
