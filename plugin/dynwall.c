#include "dynwall.h"

#define _USE_MATH_DEFINES
#include <libheif/heif.h>
#include <math.h>
#include <png.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── base64 ──────────────────────────────────────────────────────────────── */

static int b64_value(char c) {
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+') return 62;
	if (c == '/') return 63;
	return -1; /* whitespace, padding, or rubbish -- all skipped */
}

static unsigned char *b64_decode(const char *in, size_t in_len, size_t *out_len) {
	unsigned char *out = malloc(in_len / 4 * 3 + 4);
	if (!out) {
		return NULL;
	}
	size_t n = 0;
	uint32_t acc = 0;
	int bits = 0;
	for (size_t i = 0; i < in_len; i++) {
		int v = b64_value(in[i]);
		if (v < 0) {
			continue;
		}
		acc = (acc << 6) | (uint32_t)v;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out[n++] = (unsigned char)((acc >> bits) & 0xff);
		}
	}
	*out_len = n;
	return out;
}

/* ── binary plist ────────────────────────────────────────────────────────────
 *
 * Only as much of bplist00 as this metadata uses: dictionaries, arrays, ASCII
 * keys, integers and reals. Written out rather than linked, because the
 * alternatives are CoreFoundation (not here) or a general-purpose plist
 * library pulled in to read about forty bytes of it.
 *
 * The layout: an 8-byte "bplist00", the objects, an offset table, and a
 * 32-byte trailer holding the widths and where the table is. Everything
 * multi-byte is big-endian. */

struct bplist {
	const unsigned char *data;
	size_t size;
	const unsigned char *offsets;
	uint8_t offset_size;
	uint8_t ref_size;
	uint64_t n_objects;
	uint64_t top;
};

static uint64_t be_read(const unsigned char *p, size_t n) {
	uint64_t v = 0;
	for (size_t i = 0; i < n; i++) {
		v = (v << 8) | p[i];
	}
	return v;
}

static bool bplist_open(const unsigned char *data, size_t size,
		struct bplist *bp) {
	if (size < 8 + 32 || memcmp(data, "bplist00", 8) != 0) {
		return false;
	}
	const unsigned char *tr = data + size - 32;
	bp->data = data;
	bp->size = size;
	bp->offset_size = tr[6];
	bp->ref_size = tr[7];
	bp->n_objects = be_read(tr + 8, 8);
	bp->top = be_read(tr + 16, 8);
	uint64_t table = be_read(tr + 24, 8);

	if (bp->offset_size == 0 || bp->offset_size > 8 || bp->ref_size == 0 ||
			bp->ref_size > 8) {
		return false;
	}
	/* The table has to fit, and so does every entry in it. A truncated plist
	 * is the one thing likely to be handed to this that is not a plist. */
	if (table > size || bp->n_objects > (size - table) / bp->offset_size) {
		return false;
	}
	bp->offsets = data + table;
	return true;
}

static const unsigned char *bplist_object(const struct bplist *bp, uint64_t ref) {
	if (ref >= bp->n_objects) {
		return NULL;
	}
	uint64_t off = be_read(bp->offsets + ref * bp->offset_size, bp->offset_size);
	if (off >= bp->size) {
		return NULL;
	}
	return bp->data + off;
}

/* The count of a collection or the length of a string, and where its body
 * starts. Small counts live in the low nibble; 0x0f means "an integer object
 * follows with the real count". */
static bool bplist_count(const struct bplist *bp, const unsigned char *obj,
		uint64_t *count, const unsigned char **body) {
	uint8_t low = obj[0] & 0x0f;
	if (low != 0x0f) {
		*count = low;
		*body = obj + 1;
		return true;
	}
	const unsigned char *p = obj + 1;
	if ((size_t)(p - bp->data) >= bp->size || (p[0] & 0xf0) != 0x10) {
		return false;
	}
	size_t n = (size_t)1 << (p[0] & 0x0f);
	if ((size_t)(p + 1 + n - bp->data) > bp->size) {
		return false;
	}
	*count = be_read(p + 1, n);
	*body = p + 1 + n;
	return true;
}

static bool bplist_number(const struct bplist *bp, uint64_t ref, double *out) {
	const unsigned char *obj = bplist_object(bp, ref);
	if (!obj) {
		return false;
	}
	uint8_t type = obj[0] & 0xf0;
	size_t n = (size_t)1 << (obj[0] & 0x0f);
	if ((size_t)(obj + 1 + n - bp->data) > bp->size) {
		return false;
	}
	if (type == 0x10) { /* integer */
		*out = (double)be_read(obj + 1, n);
		return true;
	}
	if (type == 0x20) { /* real: 4 or 8 bytes, big-endian IEEE */
		if (n == 4) {
			uint32_t bits = (uint32_t)be_read(obj + 1, 4);
			float f;
			memcpy(&f, &bits, 4);
			*out = f;
			return true;
		}
		if (n == 8) {
			uint64_t bits = be_read(obj + 1, 8);
			double d;
			memcpy(&d, &bits, 8);
			*out = d;
			return true;
		}
	}
	return false;
}

/* The value stored under `key` in a dictionary object. */
static bool bplist_dict_get(const struct bplist *bp, const unsigned char *dict,
		const char *key, uint64_t *value_ref) {
	if ((dict[0] & 0xf0) != 0xd0) {
		return false;
	}
	uint64_t n;
	const unsigned char *body;
	if (!bplist_count(bp, dict, &n, &body)) {
		return false;
	}
	if ((size_t)(body - bp->data) + (size_t)n * 2 * bp->ref_size > bp->size) {
		return false;
	}
	size_t key_len = strlen(key);
	for (uint64_t i = 0; i < n; i++) {
		uint64_t kref = be_read(body + i * bp->ref_size, bp->ref_size);
		const unsigned char *kobj = bplist_object(bp, kref);
		if (!kobj || (kobj[0] & 0xf0) != 0x50) { /* ASCII string */
			continue;
		}
		uint64_t klen;
		const unsigned char *kbody;
		if (!bplist_count(bp, kobj, &klen, &kbody)) {
			continue;
		}
		if (klen == key_len && memcmp(kbody, key, key_len) == 0) {
			*value_ref = be_read(body + (n + i) * bp->ref_size, bp->ref_size);
			return true;
		}
	}
	return false;
}

/* ── the schedule ────────────────────────────────────────────────────────── */

/* One `ti` (or `si`) entry: a time and an image index. */
static bool read_entry(const struct bplist *bp, uint64_t ref,
		const char *time_key, struct azbar_dyn_frame *out) {
	const unsigned char *obj = bplist_object(bp, ref);
	if (!obj) {
		return false;
	}
	uint64_t tref, iref;
	double t = 0, i = 0;
	if (!bplist_dict_get(bp, obj, "i", &iref) || !bplist_number(bp, iref, &i)) {
		return false;
	}
	if (bplist_dict_get(bp, obj, time_key, &tref)) {
		if (!bplist_number(bp, tref, &t)) {
			return false;
		}
	}
	out->t = t;
	out->index = (int)i;
	/* Solar entries carry an azimuth beside the altitude. Only meaningful
	 * there, and absent from a clock table, so a miss is not a failure. */
	out->azimuth = 0;
	uint64_t zref;
	double z = 0;
	if (bplist_dict_get(bp, obj, "z", &zref) && bplist_number(bp, zref, &z)) {
		out->azimuth = z;
	}
	return true;
}

static int compare_frames(const void *a, const void *b) {
	double ta = ((const struct azbar_dyn_frame *)a)->t;
	double tb = ((const struct azbar_dyn_frame *)b)->t;
	return ta < tb ? -1 : (ta > tb ? 1 : 0);
}

static bool parse_plist(const unsigned char *data, size_t size, bool solar,
		struct azbar_dyn_schedule *out) {
	struct bplist bp;
	if (!bplist_open(data, size, &bp)) {
		return false;
	}
	const unsigned char *root = bplist_object(&bp, bp.top);
	if (!root) {
		return false;
	}

	out->light_index = -1;
	out->dark_index = -1;
	out->solar = solar;

	uint64_t ap_ref;
	if (bplist_dict_get(&bp, root, "ap", &ap_ref)) {
		const unsigned char *ap = bplist_object(&bp, ap_ref);
		uint64_t r;
		double v;
		if (ap && bplist_dict_get(&bp, ap, "l", &r) && bplist_number(&bp, r, &v)) {
			out->light_index = (int)v;
		}
		if (ap && bplist_dict_get(&bp, ap, "d", &r) && bplist_number(&bp, r, &v)) {
			out->dark_index = (int)v;
		}
	}

	/* `ti` for the clock table, `si` for the solar one. The solar entries are
	 * read for their indices even though their altitude cannot be evaluated
	 * here -- that is what makes the light/dark fallback possible at all. */
	const char *list_key = solar ? "si" : "ti";
	const char *time_key = solar ? "a" : "t";
	uint64_t list_ref;
	if (bplist_dict_get(&bp, root, list_key, &list_ref)) {
		const unsigned char *list = bplist_object(&bp, list_ref);
		uint64_t n;
		const unsigned char *body;
		if (list && (list[0] & 0xf0) == 0xa0 &&
				bplist_count(&bp, list, &n, &body) && n > 0 &&
				(size_t)(body - bp.data) + (size_t)n * bp.ref_size <= bp.size) {
			out->frames = calloc((size_t)n, sizeof(*out->frames));
			if (!out->frames) {
				return false;
			}
			size_t got = 0;
			for (uint64_t i = 0; i < n; i++) {
				uint64_t ref = be_read(body + i * bp.ref_size, bp.ref_size);
				if (read_entry(&bp, ref, time_key, &out->frames[got])) {
					got++;
				}
			}
			out->n_frames = got;
			/* In time order, because nothing promises the file is. Every
			 * lookup below is "the last entry at or before now". */
			if (got > 1 && !solar) {
				qsort(out->frames, got, sizeof(*out->frames), compare_frames);
			}
		}
	}

	return out->n_frames > 0 || out->light_index >= 0 || out->dark_index >= 0;
}

/* The XMP block, and the apple_desktop property inside it.
 *
 * Read as text rather than with an XML parser: the property is one base64
 * attribute in a document written by one program, and pulling in a parser to
 * find it would be the larger risk. */
static bool find_property(const char *xmp, size_t len, const char *name,
		const char **value, size_t *value_len) {
	char needle[64];
	snprintf(needle, sizeof(needle), "apple_desktop:%s=\"", name);
	size_t nlen = strlen(needle);
	if (len < nlen) {
		return false;
	}
	for (size_t i = 0; i + nlen <= len; i++) {
		if (memcmp(xmp + i, needle, nlen) != 0) {
			continue;
		}
		const char *start = xmp + i + nlen;
		const char *end = memchr(start, '"', len - (size_t)(start - xmp));
		if (!end) {
			return false;
		}
		*value = start;
		*value_len = (size_t)(end - start);
		return true;
	}
	return false;
}

bool azbar_dyn_parse_xmp(const char *xmp, size_t len,
		struct azbar_dyn_schedule *out) {
	if (!xmp || !out) {
		return false;
	}
	memset(out, 0, sizeof(*out));
	out->light_index = -1;
	out->dark_index = -1;

	const char *value;
	size_t value_len;
	bool solar = false;
	if (!find_property(xmp, len, "h24", &value, &value_len)) {
		if (!find_property(xmp, len, "solar", &value, &value_len)) {
			return false;
		}
		solar = true;
	}

	size_t raw_len = 0;
	unsigned char *raw = b64_decode(value, value_len, &raw_len);
	if (!raw) {
		return false;
	}
	bool ok = parse_plist(raw, raw_len, solar, out);
	free(raw);
	if (!ok) {
		azbar_dyn_schedule_free(out);
	}
	return ok;
}

bool azbar_dyn_schedule_read(const char *path, struct azbar_dyn_schedule *out) {
	if (!path || !out) {
		return false;
	}
	memset(out, 0, sizeof(*out));
	out->light_index = -1;
	out->dark_index = -1;

	struct heif_context *ctx = heif_context_alloc();
	if (!ctx) {
		return false;
	}
	bool ok = false;
	struct heif_image_handle *handle = NULL;
	uint8_t *xmp = NULL;

	struct heif_error err = heif_context_read_from_file(ctx, path, NULL);
	if (err.code != heif_error_Ok) {
		goto done;
	}

	out->n_images = (size_t)heif_context_get_number_of_top_level_images(ctx);
	/* One image is an ordinary still, whatever it says about itself. */
	if (out->n_images < 2) {
		goto done;
	}

	err = heif_context_get_primary_image_handle(ctx, &handle);
	if (err.code != heif_error_Ok) {
		goto done;
	}

	heif_item_id ids[16];
	int n = heif_image_handle_get_list_of_metadata_block_IDs(handle, "mime", ids,
		(int)(sizeof(ids) / sizeof(ids[0])));
	for (int i = 0; i < n; i++) {
		const char *type = heif_image_handle_get_metadata_content_type(handle, ids[i]);
		if (!type || strcmp(type, "application/rdf+xml") != 0) {
			continue;
		}
		size_t size = heif_image_handle_get_metadata_size(handle, ids[i]);
		if (size == 0 || size > (8u << 20)) {
			continue;
		}
		xmp = malloc(size + 1);
		if (!xmp) {
			goto done;
		}
		err = heif_image_handle_get_metadata(handle, ids[i], xmp);
		if (err.code != heif_error_Ok) {
			free(xmp);
			xmp = NULL;
			continue;
		}
		xmp[size] = '\0';

		size_t n_images = out->n_images;
		ok = azbar_dyn_parse_xmp((const char *)xmp, size, out);
		out->n_images = n_images; /* the parse does not know it; this does */
		free(xmp);
		xmp = NULL;
		if (ok) {
			break;
		}
	}

done:
	if (handle) {
		heif_image_handle_release(handle);
	}
	heif_context_free(ctx);
	if (!ok) {
		azbar_dyn_schedule_free(out);
	}
	return ok;
}

void azbar_dyn_schedule_free(struct azbar_dyn_schedule *s) {
	if (!s) {
		return;
	}
	free(s->frames);
	s->frames = NULL;
	s->n_frames = 0;
}

int azbar_dyn_frame_at(const struct azbar_dyn_schedule *s, double fraction) {
	if (!s) {
		return -1;
	}
	/* A solar file's table cannot be evaluated without knowing where this
	 * machine is, so it takes the light/dark pair instead: light through the
	 * middle of the day, dark otherwise. An approximation, and a deliberate
	 * one -- the alternative is inventing a latitude. */
	if (s->solar || s->n_frames == 0) {
		bool day = fraction >= 0.25 && fraction < 0.75;
		int wanted = day ? s->light_index : s->dark_index;
		if (wanted >= 0) {
			return wanted;
		}
		return s->n_frames > 0 ? s->frames[0].index : -1;
	}

	int chosen = s->frames[s->n_frames - 1].index; /* wraps from yesterday */
	for (size_t i = 0; i < s->n_frames; i++) {
		if (s->frames[i].t <= fraction) {
			chosen = s->frames[i].index;
		} else {
			break;
		}
	}
	return chosen;
}

/* ── the sun ─────────────────────────────────────────────────────────────── */

#define DEG (M_PI / 180.0)

void azbar_sun_position(double lat, double lon, long long unix_time,
		double *altitude, double *azimuth) {
	/* Days since J2000.0. The Unix epoch is 10957.5 days before it. */
	double n = (double)unix_time / 86400.0 - 10957.5;

	double mean_long = fmod(280.460 + 0.9856474 * n, 360.0);
	double mean_anom = fmod(357.528 + 0.9856003 * n, 360.0) * DEG;
	double ecliptic = (mean_long + 1.915 * sin(mean_anom)
		+ 0.020 * sin(2 * mean_anom)) * DEG;
	double obliquity = (23.439 - 0.0000004 * n) * DEG;

	double right_asc = atan2(cos(obliquity) * sin(ecliptic), cos(ecliptic));
	double declination = asin(sin(obliquity) * sin(ecliptic));

	/* Greenwich mean sidereal time, then local, then the hour angle: how far
	 * the sun is from the local meridian. */
	double gmst = fmod(18.697374558 + 24.06570982441908 * n, 24.0);
	if (gmst < 0) {
		gmst += 24.0;
	}
	double hour_angle = (gmst * 15.0 + lon) * DEG - right_asc;

	double phi = lat * DEG;
	double alt = asin(sin(phi) * sin(declination)
		+ cos(phi) * cos(declination) * cos(hour_angle));
	/* Clockwise from north, which is how Apple's tables express it. */
	double az = atan2(-sin(hour_angle) * cos(declination),
		sin(declination) * cos(phi) - cos(declination) * sin(phi) * cos(hour_angle));
	az = fmod(az / DEG + 360.0, 360.0);

	if (altitude) {
		*altitude = alt / DEG;
	}
	if (azimuth) {
		*azimuth = az;
	}
}

int azbar_dyn_frame_at_sun(const struct azbar_dyn_schedule *s, double altitude,
		double azimuth) {
	if (!s || !s->solar || s->n_frames == 0) {
		return -1;
	}

	/* East of the meridian is the sun on its way up. Comparing entries only
	 * within the same half of the day is what stops a morning frame being
	 * chosen for the equivalent evening altitude -- the table passes through
	 * every altitude twice. */
	bool rising = azimuth < 180.0;

	int best = -1;
	double best_score = 0;
	for (size_t pass = 0; pass < 2 && best < 0; pass++) {
		for (size_t i = 0; i < s->n_frames; i++) {
			/* First pass: the matching half of the day only. Second: anything,
			 * for a table that only describes one half. */
			if (pass == 0 && (s->frames[i].azimuth < 180.0) != rising) {
				continue;
			}
			double score = fabs(s->frames[i].t - altitude);
			if (best < 0 || score < best_score) {
				best = s->frames[i].index;
				best_score = score;
			}
		}
	}
	return best;
}

double azbar_dyn_next_change(const struct azbar_dyn_schedule *s, double fraction) {
	if (!s || s->n_frames == 0) {
		return -1;
	}
	if (s->solar) {
		/* The two boundaries the fallback above uses. */
		if (fraction < 0.25) {
			return 0.25;
		}
		if (fraction < 0.75) {
			return 0.75;
		}
		return 1.25;
	}
	for (size_t i = 0; i < s->n_frames; i++) {
		if (s->frames[i].t > fraction) {
			return s->frames[i].t;
		}
	}
	/* Past the last entry: the next change is the first one, tomorrow. */
	return 1.0 + s->frames[0].t;
}

/* ── extracting a frame ──────────────────────────────────────────────────── */

static bool write_png(const struct heif_image *img, const char *dest, char **err) {
	int width = heif_image_get_width(img, heif_channel_interleaved);
	int height = heif_image_get_height(img, heif_channel_interleaved);
	int stride = 0;
	const uint8_t *plane = heif_image_get_plane_readonly(img,
		heif_channel_interleaved, &stride);
	if (!plane || width <= 0 || height <= 0) {
		if (err) {
			*err = strdup("decoded image has no pixels");
		}
		return false;
	}

	FILE *f = fopen(dest, "wb");
	if (!f) {
		if (err) {
			*err = strdup("cannot write the extracted frame");
		}
		return false;
	}

	png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
	png_infop info = png ? png_create_info_struct(png) : NULL;
	if (!png || !info || setjmp(png_jmpbuf(png))) {
		if (png) {
			png_destroy_write_struct(&png, info ? &info : NULL);
		}
		fclose(f);
		if (err) {
			*err = strdup("libpng failed on the extracted frame");
		}
		return false;
	}

	png_init_io(png, f);
	png_set_IHDR(png, info, (png_uint_32)width, (png_uint_32)height, 8,
		PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT,
		PNG_FILTER_TYPE_DEFAULT);
	png_write_info(png, info);
	for (int y = 0; y < height; y++) {
		png_write_row(png, (png_bytep)(plane + (size_t)y * (size_t)stride));
	}
	png_write_end(png, NULL);
	png_destroy_write_struct(&png, &info);
	fclose(f);
	return true;
}

bool azbar_dyn_extract(const char *path, int index, const char *dest, char **err) {
	if (err) {
		*err = NULL;
	}
	if (!path || !dest || index < 0) {
		return false;
	}

	struct heif_context *ctx = heif_context_alloc();
	if (!ctx) {
		return false;
	}
	bool ok = false;
	heif_item_id *ids = NULL;
	struct heif_image_handle *handle = NULL;
	struct heif_image *img = NULL;

	struct heif_error e = heif_context_read_from_file(ctx, path, NULL);
	if (e.code != heif_error_Ok) {
		if (err) {
			*err = strdup(e.message ? e.message : "cannot read the file");
		}
		goto done;
	}

	int n = heif_context_get_number_of_top_level_images(ctx);
	if (index >= n) {
		if (err) {
			*err = strdup("the schedule names a frame the file does not have");
		}
		goto done;
	}
	ids = calloc((size_t)n, sizeof(*ids));
	if (!ids) {
		goto done;
	}
	heif_context_get_list_of_top_level_image_IDs(ctx, ids, n);

	e = heif_context_get_image_handle(ctx, ids[index], &handle);
	if (e.code != heif_error_Ok) {
		if (err) {
			*err = strdup(e.message ? e.message : "cannot open that frame");
		}
		goto done;
	}

	/* 8-bit interleaved RGB. The bit depth is where HDR is lost, and it is
	 * lost in the PNG rather than here -- see the header. */
	e = heif_decode_image(handle, &img, heif_colorspace_RGB, heif_chroma_interleaved_RGB, NULL);
	if (e.code != heif_error_Ok) {
		if (err) {
			*err = strdup(e.message ? e.message : "cannot decode that frame");
		}
		goto done;
	}

	ok = write_png(img, dest, err);

done:
	if (img) {
		heif_image_release(img);
	}
	if (handle) {
		heif_image_handle_release(handle);
	}
	free(ids);
	heif_context_free(ctx);
	return ok;
}
