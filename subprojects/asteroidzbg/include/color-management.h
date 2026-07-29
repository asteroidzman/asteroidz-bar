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

/* Tag surface with the image's colorimetry. Safe to call with a NULL or
 * non-HDR image, in which case any existing tag is left alone. Returns false
 * if the tag could not be applied, so the caller can fall back to SDR. */
bool cm_apply_to_surface(struct cm_state *cm, struct wl_surface *surface,
		const struct hdr_image *image);

#endif
