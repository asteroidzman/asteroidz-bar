#ifndef _ASTEROIDZBG_HDR_IMAGE_H
#define _ASTEROIDZBG_HDR_IMAGE_H

#include <cairo.h>
#include <stdbool.h>

/* Colorimetry recovered from the file's own metadata (AVIF/JXL CICP), not
 * guessed from the pixel data. An image is treated as HDR only when it says
 * so itself -- see hdr_image_load(). */
enum hdr_transfer {
	HDR_TF_SRGB = 0, /* everything that isn't explicitly PQ or HLG */
	HDR_TF_PQ,       /* SMPTE ST 2084 -- the HDR10 transfer function */
	HDR_TF_HLG,      /* ARIB STD-B67 */
};

enum hdr_primaries {
	HDR_PRIM_SRGB = 0, /* BT.709 / sRGB */
	HDR_PRIM_BT2020,
};

struct hdr_image {
	/* CAIRO_FORMAT_RGB30 when is_hdr, CAIRO_FORMAT_RGB24 otherwise. Both are
	 * ordinary cairo image surfaces, so render_background_image()'s scaling
	 * and placement logic works unchanged on either. */
	cairo_surface_t *surface;
	bool is_hdr;
	enum hdr_transfer tf;
	enum hdr_primaries primaries;
};

/* Loads path as a 10-bit image if it carries HDR colorimetry, returning NULL
 * if the file isn't an HDR format this build can decode. The caller falls
 * back to the ordinary gdk-pixbuf path in that case. */
struct hdr_image *hdr_image_load(const char *path);

void hdr_image_destroy(struct hdr_image *image);

/* True if this build has any HDR decoder compiled in. */
bool hdr_image_supported(void);

#endif
