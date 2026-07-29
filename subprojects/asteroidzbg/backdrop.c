#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "backdrop.h"
#include "background-image.h"
#include "cairo_util.h"
#include "color-management.h"
#include "hdr-image.h"
#include "log.h"
#include "pool-buffer.h"
#include "fractional-scale-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

/* The host's display is pumped by the host, so nothing here may block. Where
 * main() used to run `while (wl_display_dispatch(...))` and do a pass of
 * deferred work after every dispatch, the same pass is now
 * azbg_backdrop_flush() and the host is the one who calls it. */

#define FRACT_DENOM 120

struct azbg_image {
	struct hdr_image *hdr;
};

struct azbg_output {
	struct wl_list link;

	uint32_t wl_name;
	struct wl_output *wl_output;
	char *name;

	struct azbg_backdrop *bd;

	struct wl_surface *surface;
	/* Created with the surface and kept: a second get_surface for the same
	 * wl_surface is a protocol error, and destroying this object unsets the
	 * image description it carries. */
	struct wp_color_management_surface_v1 *cm_surface;
	struct zwlr_layer_surface_v1 *layer_surface;
	struct wp_viewport *viewport;
	struct wp_fractional_scale_v1 *fract_scale;

	uint32_t width, height;
	int32_t scale;
	uint32_t pref_fract_scale;

	uint32_t configure_serial;
	bool needs_ack;
	/* Wants pixels: it has never been drawn, or the size it wants has
	 * changed since it last was. */
	bool dirty;
	/* Size of the buffer currently attached, so a redraw that would produce
	 * the identical buffer can be skipped. */
	uint32_t buffer_width, buffer_height;
	/* Deferred surface creation, for the case where an output is announced
	 * before the layer shell is. */
	bool wants_surface;
};

struct azbg_backdrop {
	struct wl_display *display;
	struct wl_registry *registry;

	struct wl_compositor *compositor;
	struct wl_shm *shm;
	struct zwlr_layer_shell_v1 *layer_shell;
	struct wp_viewporter *viewporter;
	struct wp_fractional_scale_manager_v1 *fract_scale_manager;
	struct cm_state cm;

	struct wl_list outputs;

	enum background_mode mode;

	azbg_wake_fn wake;
	void *user;
};

static void wake(struct azbg_backdrop *bd) {
	if (bd->wake) {
		bd->wake(bd->user);
	}
}

/* ── decode ──────────────────────────────────────────────────────────────── */

struct azbg_image *azbg_image_load(const char *path) {
	if (!path || !*path) {
		return NULL;
	}

	/* HDR first, and only on its own say-so: hdr_image_load() returns NULL
	 * for anything that does not carry PQ/HLG colorimetry in its own
	 * metadata, which is what keeps an ordinary JPEG off the 10-bit path. */
	struct hdr_image *hdr = hdr_image_load(path);
	if (!hdr) {
		cairo_surface_t *surface = load_background_image(path);
		if (!surface) {
			return NULL;
		}
		hdr = calloc(1, sizeof(*hdr));
		if (!hdr) {
			cairo_surface_destroy(surface);
			return NULL;
		}
		hdr->surface = surface;
		hdr->is_hdr = false;
	}

	struct azbg_image *image = calloc(1, sizeof(*image));
	if (!image) {
		hdr_image_destroy(hdr);
		return NULL;
	}
	image->hdr = hdr;
	return image;
}

void azbg_image_destroy(struct azbg_image *image) {
	if (!image) {
		return;
	}
	hdr_image_destroy(image->hdr);
	free(image);
}

bool azbg_image_is_hdr(const struct azbg_image *image) {
	return image && image->hdr && image->hdr->is_hdr;
}

/* ── drawing ─────────────────────────────────────────────────────────────── */

static void get_buffer_size(const struct azbg_output *output,
		uint32_t *buffer_width, uint32_t *buffer_height) {
	if (output->pref_fract_scale && output->bd->viewporter) {
		// rounding mode is 'round half up'
		*buffer_width = (output->width * output->pref_fract_scale +
			FRACT_DENOM / 2) / FRACT_DENOM;
		*buffer_height = (output->height * output->pref_fract_scale +
			FRACT_DENOM / 2) / FRACT_DENOM;
	} else {
		*buffer_width = output->width * output->scale;
		*buffer_height = output->height * output->scale;
	}
}

/* A 10-bit buffer is only worth requesting when the image really is HDR and
 * the compositor can be told what its pixels mean -- an untagged PQ buffer
 * would be read as plain gamma and look badly washed out. */
static bool wants_hdr(const struct azbg_backdrop *bd,
		const struct hdr_image *image) {
	return image && image->is_hdr && cm_can_represent(&bd->cm, image);
}

static struct wl_buffer *draw_buffer(struct azbg_output *output,
		const struct hdr_image *image, uint32_t buffer_width,
		uint32_t buffer_height) {
	struct azbg_backdrop *bd = output->bd;
	bool use_hdr = wants_hdr(bd, image);

	struct pool_buffer buffer;
	if (!create_buffer(&buffer, bd->shm, buffer_width, buffer_height,
			use_hdr ? WL_SHM_FORMAT_XRGB2101010 : WL_SHM_FORMAT_XRGB8888)) {
		return NULL;
	}

	cairo_t *cairo = buffer.cairo;
	cairo_set_source_u32(cairo, 0x000000ff);
	cairo_paint(cairo);

	if (image && image->surface) {
		render_background_image(cairo, image->surface, bd->mode,
			buffer_width, buffer_height);
	}

	struct wl_buffer *wl_buf = buffer.buffer;
	buffer.buffer = NULL;
	destroy_buffer(&buffer);
	return wl_buf;
}

static void render_frame(struct azbg_output *output,
		const struct hdr_image *image) {
	if (!output->layer_surface || output->width == 0 || output->height == 0) {
		return;
	}

	uint32_t buffer_width, buffer_height;
	get_buffer_size(output, &buffer_width, &buffer_height);

	struct wl_buffer *buf = draw_buffer(output, image,
		buffer_width, buffer_height);
	if (!buf) {
		return;
	}

	/* Tag before the commit below: the image description is latched by the
	 * same commit that attaches the buffer it describes, so the compositor
	 * never sees PQ pixels it has not been told about. */
	cm_apply_to_surface(&output->bd->cm, output->bd->display,
		output->cm_surface, image);

	wl_surface_attach(output->surface, buf, 0, 0);
	wl_surface_damage_buffer(output->surface, 0, 0, buffer_width, buffer_height);

	output->buffer_width = buffer_width;
	output->buffer_height = buffer_height;

	if (output->viewport) {
		wp_viewport_set_destination(output->viewport,
			output->width, output->height);
	} else {
		wl_surface_set_buffer_scale(output->surface, output->scale);
	}
	wl_surface_commit(output->surface);
	wl_buffer_destroy(buf);
}

/* ── outputs ─────────────────────────────────────────────────────────────── */

static void destroy_output(struct azbg_output *output) {
	if (!output) {
		return;
	}
	wl_list_remove(&output->link);
	if (output->layer_surface) {
		zwlr_layer_surface_v1_destroy(output->layer_surface);
	}
	if (output->surface) {
		cm_surface_destroy(output->cm_surface);
		wl_surface_destroy(output->surface);
	}
	if (output->viewport) {
		wp_viewport_destroy(output->viewport);
	}
	if (output->fract_scale) {
		wp_fractional_scale_v1_destroy(output->fract_scale);
	}
	wl_output_destroy(output->wl_output);
	free(output->name);
	free(output);
}

static void layer_surface_configure(void *data,
		struct zwlr_layer_surface_v1 *surface,
		uint32_t serial, uint32_t width, uint32_t height) {
	struct azbg_output *output = data;
	output->width = width;
	output->height = height;
	output->configure_serial = serial;
	output->needs_ack = true;
	output->dirty = true;
	wake(output->bd);
}

static void layer_surface_closed(void *data,
		struct zwlr_layer_surface_v1 *surface) {
	struct azbg_output *output = data;
	asteroidzbg_log(LOG_DEBUG, "Destroying output %s", output->name);
	destroy_output(output);
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
	.configure = layer_surface_configure,
	.closed = layer_surface_closed,
};

static void fract_preferred_scale(void *data, struct wp_fractional_scale_v1 *f,
		uint32_t scale) {
	struct azbg_output *output = data;
	if (output->pref_fract_scale == scale) {
		return;
	}
	output->pref_fract_scale = scale;
	output->dirty = true;
	wake(output->bd);
}

static const struct wp_fractional_scale_v1_listener fract_scale_listener = {
	.preferred_scale = fract_preferred_scale,
};

static void create_layer_surface(struct azbg_output *output) {
	struct azbg_backdrop *bd = output->bd;

	output->surface = wl_compositor_create_surface(bd->compositor);
	output->cm_surface = cm_surface_create(&bd->cm, output->surface);
	assert(output->surface);

	/* Empty input region: the wallpaper is scenery. Without this it would
	 * swallow every click that lands on the desktop. */
	struct wl_region *input_region = wl_compositor_create_region(bd->compositor);
	assert(input_region);
	wl_surface_set_input_region(output->surface, input_region);
	wl_region_destroy(input_region);

	if (bd->fract_scale_manager) {
		output->fract_scale = wp_fractional_scale_manager_v1_get_fractional_scale(
			bd->fract_scale_manager, output->surface);
		assert(output->fract_scale);
		wp_fractional_scale_v1_add_listener(output->fract_scale,
			&fract_scale_listener, output);
	}

	if (bd->viewporter && bd->fract_scale_manager) {
		output->viewport = wp_viewporter_get_viewport(bd->viewporter,
			output->surface);
	}

	output->layer_surface = zwlr_layer_shell_v1_get_layer_surface(
		bd->layer_shell, output->surface, output->wl_output,
		ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallpaper");
	assert(output->layer_surface);

	zwlr_layer_surface_v1_set_size(output->layer_surface, 0, 0);
	zwlr_layer_surface_v1_set_anchor(output->layer_surface,
		ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
		ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
	zwlr_layer_surface_v1_set_exclusive_zone(output->layer_surface, -1);
	zwlr_layer_surface_v1_add_listener(output->layer_surface,
		&layer_surface_listener, output);
	wl_surface_commit(output->surface);

	output->wants_surface = false;
}

static void output_geometry(void *data, struct wl_output *wl_output, int32_t x,
		int32_t y, int32_t width_mm, int32_t height_mm, int32_t subpixel,
		const char *make, const char *model, int32_t transform) {
	// Who cares
}

static void output_mode(void *data, struct wl_output *wl_output, uint32_t flags,
		int32_t width, int32_t height, int32_t refresh) {
	// Who cares
}

static void output_done(void *data, struct wl_output *wl_output) {
	struct azbg_output *output = data;
	if (output->layer_surface) {
		return;
	}
	/* The globals usually all arrive before any output finishes announcing
	 * itself, but nothing in the protocol promises that ordering -- so an
	 * output that cannot be given a surface yet asks for one later rather
	 * than being dropped, which is what would leave a monitor with no
	 * wallpaper for the rest of the session. */
	if (output->bd->compositor && output->bd->layer_shell) {
		create_layer_surface(output);
	} else {
		output->wants_surface = true;
		wake(output->bd);
	}
}

static void output_scale(void *data, struct wl_output *wl_output,
		int32_t scale) {
	struct azbg_output *output = data;
	if (output->scale == scale) {
		return;
	}
	output->scale = scale;
	if (output->width > 0 && output->height > 0) {
		output->dirty = true;
		wake(output->bd);
	}
}

static void output_name(void *data, struct wl_output *wl_output,
		const char *name) {
	struct azbg_output *output = data;
	free(output->name);
	output->name = strdup(name);
}

static void output_description(void *data, struct wl_output *wl_output,
		const char *description) {
	// Who cares: there is one wallpaper for every output, so there is
	// nothing to match a description against.
}

static const struct wl_output_listener output_listener = {
	.geometry = output_geometry,
	.mode = output_mode,
	.done = output_done,
	.scale = output_scale,
	.name = output_name,
	.description = output_description,
};

/* ── registry ────────────────────────────────────────────────────────────── */

static void handle_global(void *data, struct wl_registry *registry,
		uint32_t name, const char *interface, uint32_t version) {
	struct azbg_backdrop *bd = data;
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		bd->compositor = wl_registry_bind(registry, name,
			&wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		bd->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_output_interface.name) == 0) {
		struct azbg_output *output = calloc(1, sizeof(*output));
		if (!output) {
			return;
		}
		output->bd = bd;
		output->scale = 1;
		output->wl_name = name;
		output->wl_output = wl_registry_bind(registry, name,
			&wl_output_interface, 4);
		wl_output_add_listener(output->wl_output, &output_listener, output);
		wl_list_insert(&bd->outputs, &output->link);
	} else if (strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
		bd->layer_shell = wl_registry_bind(registry, name,
			&zwlr_layer_shell_v1_interface, 1);
	} else if (strcmp(interface, wp_viewporter_interface.name) == 0) {
		bd->viewporter = wl_registry_bind(registry, name,
			&wp_viewporter_interface, 1);
	} else if (strcmp(interface,
			wp_fractional_scale_manager_v1_interface.name) == 0) {
		bd->fract_scale_manager = wl_registry_bind(registry, name,
			&wp_fractional_scale_manager_v1_interface, 1);
	} else if (cm_state_handle_global(&bd->cm, registry, name, interface,
			version)) {
		// consumed by the color-management backend
	}
}

static void handle_global_remove(void *data, struct wl_registry *registry,
		uint32_t name) {
	struct azbg_backdrop *bd = data;
	struct azbg_output *output, *tmp;
	wl_list_for_each_safe(output, tmp, &bd->outputs, link) {
		if (output->wl_name == name) {
			asteroidzbg_log(LOG_DEBUG, "Destroying output %s", output->name);
			destroy_output(output);
			break;
		}
	}
}

static const struct wl_registry_listener registry_listener = {
	.global = handle_global,
	.global_remove = handle_global_remove,
};

/* ── the API ─────────────────────────────────────────────────────────────── */

struct azbg_backdrop *azbg_backdrop_create(struct wl_display *display,
		azbg_wake_fn wake_fn, void *user) {
	if (!display) {
		return NULL;
	}
	struct azbg_backdrop *bd = calloc(1, sizeof(*bd));
	if (!bd) {
		return NULL;
	}
	bd->display = display;
	bd->wake = wake_fn;
	bd->user = user;
	bd->mode = BACKGROUND_MODE_FILL;
	wl_list_init(&bd->outputs);

	/* Our own registry on the host's display. A second registry is
	 * ordinary: Qt has one for its own globals and never sees these
	 * bindings, and there is deliberately no roundtrip here -- blocking on
	 * a display somebody else is dispatching is how a client deadlocks
	 * itself. The globals arrive as events like everything else. */
	bd->registry = wl_display_get_registry(display);
	wl_registry_add_listener(bd->registry, &registry_listener, bd);
	wl_display_flush(display);

	return bd;
}

void azbg_backdrop_destroy(struct azbg_backdrop *bd) {
	if (!bd) {
		return;
	}
	struct azbg_output *output, *tmp;
	wl_list_for_each_safe(output, tmp, &bd->outputs, link) {
		destroy_output(output);
	}
	cm_state_finish(&bd->cm);
	if (bd->fract_scale_manager) {
		wp_fractional_scale_manager_v1_destroy(bd->fract_scale_manager);
	}
	if (bd->viewporter) {
		wp_viewporter_destroy(bd->viewporter);
	}
	if (bd->layer_shell) {
		zwlr_layer_shell_v1_destroy(bd->layer_shell);
	}
	if (bd->shm) {
		wl_shm_destroy(bd->shm);
	}
	if (bd->compositor) {
		wl_compositor_destroy(bd->compositor);
	}
	if (bd->registry) {
		wl_registry_destroy(bd->registry);
	}
	wl_display_flush(bd->display);
	free(bd);
}

bool azbg_backdrop_ready(const struct azbg_backdrop *bd) {
	return bd && bd->compositor && bd->shm && bd->layer_shell;
}

bool azbg_backdrop_present(struct azbg_backdrop *bd,
		const struct azbg_image *image, const char *mode) {
	if (!azbg_backdrop_ready(bd)) {
		return false;
	}

	enum background_mode m = parse_background_mode(mode ? mode : "fill");
	if (m == BACKGROUND_MODE_INVALID) {
		m = BACKGROUND_MODE_FILL;
	}
	bd->mode = m;

	struct azbg_output *output;
	wl_list_for_each(output, &bd->outputs, link) {
		if (output->needs_ack) {
			output->needs_ack = false;
			zwlr_layer_surface_v1_ack_configure(output->layer_surface,
				output->configure_serial);
		}
		/* Every output is redrawn, even one whose buffer is already the
		 * right size: this is a new image, so the size being unchanged says
		 * nothing about the pixels. */
		render_frame(output, image ? image->hdr : NULL);
		output->dirty = false;
	}
	wl_display_flush(bd->display);

	bool hdr = wants_hdr(bd, image ? image->hdr : NULL);
	asteroidzbg_log(LOG_DEBUG, "presented %s as %s",
		mode ? mode : "fill", hdr ? "HDR10 (10-bit, tagged)" : "SDR (8-bit)");
	return hdr;
}

bool azbg_backdrop_flush(struct azbg_backdrop *bd) {
	if (!bd) {
		return false;
	}

	bool wants_content = false;
	struct azbg_output *output;
	wl_list_for_each(output, &bd->outputs, link) {
		if (output->wants_surface && bd->compositor && bd->layer_shell) {
			create_layer_surface(output);
		}
		if (output->needs_ack) {
			output->needs_ack = false;
			zwlr_layer_surface_v1_ack_configure(output->layer_surface,
				output->configure_serial);
		}
		if (!output->dirty) {
			continue;
		}

		uint32_t buffer_width, buffer_height;
		get_buffer_size(output, &buffer_width, &buffer_height);
		if (buffer_width == output->buffer_width &&
				buffer_height == output->buffer_height &&
				output->buffer_width != 0) {
			/* Configured at the size it is already drawn at -- the ack
			 * above is the whole of the answer. */
			output->dirty = false;
			continue;
		}
		wants_content = true;
	}

	wl_display_flush(bd->display);
	return wants_content;
}
