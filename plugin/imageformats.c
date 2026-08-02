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
