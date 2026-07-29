#include <stdlib.h>
#include <string.h>

#include "color-management.h"
#include "color-management-v1-client-protocol.h"
#include "log.h"

/* --- manager feature/enum probing ----------------------------------------
 *
 * wp_color_manager_v1 advertises its capabilities as a burst of events after
 * bind, terminated by `done`. Requesting a primaries or transfer-function
 * value that was never advertised is a protocol error and disconnects us, so
 * everything is recorded here and checked before it is used.
 */

static void cm_supported_intent(void *data, struct wp_color_manager_v1 *mgr,
		uint32_t render_intent) {
	// asteroidzbg only ever uses the perceptual default
}

static void cm_supported_feature(void *data, struct wp_color_manager_v1 *mgr,
		uint32_t feature) {
	struct cm_state *cm = data;
	if (feature == WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC) {
		cm->supports_parametric = true;
	}
}

static void cm_supported_tf_named(void *data, struct wp_color_manager_v1 *mgr,
		uint32_t tf) {
	struct cm_state *cm = data;
	if (tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ) {
		cm->supports_pq = true;
	} else if (tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_HLG) {
		cm->supports_hlg = true;
	}
}

static void cm_supported_primaries_named(void *data,
		struct wp_color_manager_v1 *mgr, uint32_t primaries) {
	struct cm_state *cm = data;
	if (primaries == WP_COLOR_MANAGER_V1_PRIMARIES_BT2020) {
		cm->supports_bt2020 = true;
	}
}

static void cm_done(void *data, struct wp_color_manager_v1 *mgr) {
	struct cm_state *cm = data;
	asteroidzbg_log(LOG_DEBUG,
			"wp-color-management: parametric=%d BT.2020=%d PQ=%d HLG=%d",
			cm->supports_parametric, cm->supports_bt2020, cm->supports_pq,
			cm->supports_hlg);
}

static const struct wp_color_manager_v1_listener cm_listener = {
	.supported_intent = cm_supported_intent,
	.supported_feature = cm_supported_feature,
	.supported_tf_named = cm_supported_tf_named,
	.supported_primaries_named = cm_supported_primaries_named,
	.done = cm_done,
};

bool cm_state_handle_global(struct cm_state *cm, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	if (strcmp(interface, wp_color_manager_v1_interface.name) != 0) {
		return false;
	}
	cm->manager = wl_registry_bind(registry, name,
			&wp_color_manager_v1_interface, 1);
	wp_color_manager_v1_add_listener(cm->manager, &cm_listener, cm);
	return true;
}

void cm_state_finish(struct cm_state *cm) {
	if (cm->manager) {
		wp_color_manager_v1_destroy(cm->manager);
		cm->manager = NULL;
	}
}

bool cm_can_represent(const struct cm_state *cm, const struct hdr_image *image) {
	if (!cm->manager || !cm->supports_parametric || !image || !image->is_hdr) {
		return false;
	}
	if (image->primaries == HDR_PRIM_BT2020 && !cm->supports_bt2020) {
		return false;
	}
	if (image->tf == HDR_TF_PQ && !cm->supports_pq) {
		return false;
	}
	if (image->tf == HDR_TF_HLG && !cm->supports_hlg) {
		return false;
	}
	return true;
}

/* --- image description creation ------------------------------------------
 *
 * The parametric creator is one-shot: `create` consumes it, and the resulting
 * image description is not usable until it emits `ready`. A `failed` event
 * instead means the compositor rejected the combination, which is recoverable
 * -- we simply leave the surface untagged and let it render as SDR.
 */

struct cm_image_desc_result {
	bool ready;
	bool failed;
};

static void image_desc_failed(void *data,
		struct wp_image_description_v1 *desc, uint32_t cause,
		const char *msg) {
	struct cm_image_desc_result *res = data;
	res->failed = true;
	asteroidzbg_log(LOG_ERROR, "Compositor rejected the HDR image description: %s",
			msg ? msg : "(no reason given)");
}

static void image_desc_ready(void *data,
		struct wp_image_description_v1 *desc, uint32_t identity) {
	struct cm_image_desc_result *res = data;
	res->ready = true;
}

static const struct wp_image_description_v1_listener image_desc_listener = {
	.failed = image_desc_failed,
	.ready = image_desc_ready,
};

bool cm_apply_to_surface(struct cm_state *cm, struct wl_surface *surface,
		const struct hdr_image *image) {
	if (!cm_can_represent(cm, image)) {
		return false;
	}

	struct wp_image_description_creator_params_v1 *params =
		wp_color_manager_v1_create_parametric_creator(cm->manager);
	if (!params) {
		return false;
	}

	wp_image_description_creator_params_v1_set_primaries_named(params,
			image->primaries == HDR_PRIM_BT2020
				? WP_COLOR_MANAGER_V1_PRIMARIES_BT2020
				: WP_COLOR_MANAGER_V1_PRIMARIES_SRGB);
	wp_image_description_creator_params_v1_set_tf_named(params,
			image->tf == HDR_TF_PQ
				? WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_ST2084_PQ
				: WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_HLG);

	/* Deliberately no set_mastering_display_primaries / set_luminances here.
	 * They need the `set_mastering_display_primaries` and `set_luminances`
	 * manager features, which asteroidz does not enable (wlroots asserts on
	 * them). They would also be dead weight: the compositor only forwards
	 * content mastering metadata to the display for a single fullscreen
	 * scanout candidate, and a layer-shell wallpaper can never be one. */

	struct wp_image_description_v1 *desc =
		wp_image_description_creator_params_v1_create(params);
	/* `create` destroys the creator object on the server side */

	struct cm_image_desc_result result = {0};
	wp_image_description_v1_add_listener(desc, &image_desc_listener, &result);

	/* The surface tag is latched on the next wl_surface commit, which the
	 * caller performs; ready/failed arrives asynchronously and only affects
	 * whether the description was usable, so there is no round-trip here. */
	struct wp_color_management_surface_v1 *cm_surface =
		wp_color_manager_v1_get_surface(cm->manager, surface);
	if (!cm_surface) {
		wp_image_description_v1_destroy(desc);
		return false;
	}
	wp_color_management_surface_v1_set_image_description(cm_surface, desc,
			WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL);

	/* Both objects can go as soon as the request is queued: the compositor
	 * holds its own references to the surface's description. */
	wp_image_description_v1_destroy(desc);
	wp_color_management_surface_v1_destroy(cm_surface);

	asteroidzbg_log(LOG_DEBUG, "Tagged wallpaper surface as %s / %s",
			image->primaries == HDR_PRIM_BT2020 ? "BT.2020" : "sRGB",
			image->tf == HDR_TF_PQ ? "PQ" : "HLG");
	return true;
}
