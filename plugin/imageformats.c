#include "imageformats.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* Asked once and kept: the decoder's format list does not change while the
 * process runs, and every pill and page that wants it asks on every refresh. */
static const char **cached;

const char *const *azbar_image_extensions(void) {
	if (cached)
		return (const char *const *)cached;

	size_t n = 0, cap = 32;
	const char **out = calloc(cap, sizeof(*out));
	if (!out)
		return NULL;

	GSList *formats = gdk_pixbuf_get_formats();
	for (GSList *l = formats; l; l = l->next) {
		GdkPixbufFormat *fmt = l->data;
		gchar **exts = gdk_pixbuf_format_get_extensions(fmt);
		for (gchar **e = exts; e && *e; e++) {
			/* Lower case, and unique: a format may list the same extension as
			 * another (jpeg and jpg both appear more than once). */
			gchar *low = g_ascii_strdown(*e, -1);
			bool seen = false;
			for (size_t i = 0; i < n; i++)
				if (!strcmp(out[i], low)) {
					seen = true;
					break;
				}
			if (seen) {
				g_free(low);
				continue;
			}
			if (n + 2 > cap) {
				cap *= 2;
				const char **grown = realloc(out, cap * sizeof(*out));
				if (!grown) {
					g_free(low);
					break;
				}
				out = grown;
			}
			out[n++] = low; /* handed to the cache, freed never */
		}
		g_strfreev(exts);
	}
	g_slist_free(formats);
	out[n] = NULL;
	cached = out;
	return (const char *const *)cached;
}

bool azbar_image_to_png(const char *src, const char *dst, int max_edge,
                        char **err) {
	if (err)
		*err = NULL;
	if (!src || !dst)
		return false;
	if (max_edge < 1)
		max_edge = 1;

	GError *e = NULL;

	/* Scaled on the way in rather than afterwards: gdk-pixbuf hands the size to
	 * the loader, so a 6000px HEIC never becomes a full-size buffer just to be
	 * thrown away. TRUE preserves the aspect ratio, and _at_scale will not
	 * enlarge an image that is already smaller. */
	GdkPixbuf *pix = gdk_pixbuf_new_from_file_at_scale(src, max_edge, max_edge,
	                                                   TRUE, &e);
	if (!pix) {
		if (err)
			*err = strdup(e && e->message ? e->message : "could not be decoded");
		if (e)
			g_error_free(e);
		return false;
	}

	bool ok = gdk_pixbuf_save(pix, dst, "png", &e, NULL);
	if (!ok && err)
		*err = strdup(e && e->message ? e->message : "could not be written");
	if (e)
		g_error_free(e);
	g_object_unref(pix);
	return ok;
}
