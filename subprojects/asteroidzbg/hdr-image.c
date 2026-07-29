/* HDR still-image loading for asteroidzbg.
 *
 * Only formats that carry explicit colorimetry are considered: an image is
 * HDR because its own CICP says PQ/BT.2020, never because of a heuristic on
 * the pixels or the file extension. Anything else returns NULL so main.c
 * falls back to the ordinary gdk-pixbuf path.
 *
 * Output is a CAIRO_FORMAT_RGB30 surface (2:10:10:10). That keeps the whole
 * of background-image.c's scaling and placement logic working unchanged --
 * it is just cairo operating on a wider surface. Resampling happens in the
 * PQ-encoded domain rather than in linear light, which is technically
 * incorrect but is what every compositor and browser does for display
 * scaling; for a wallpaper the error is far below visible threshold.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hdr-image.h"
#include "log.h"

#if HAVE_LIBAVIF
#include <avif/avif.h>
#endif
#if HAVE_LIBJXL
#include <jxl/decode.h>
#include <jxl/encode.h>
#endif

bool hdr_image_supported(void) {
	return HAVE_LIBAVIF || HAVE_LIBJXL;
}

/* Pack a 10-bit RGB triple into cairo's RGB30 word. Alpha bits are set to
 * opaque; cairo ignores them for RGB30 but the compositor may not. */
static inline uint32_t pack_rgb30(uint16_t r, uint16_t g, uint16_t b) {
	return (0x3u << 30) | ((uint32_t)(r & 0x3FF) << 20) |
		   ((uint32_t)(g & 0x3FF) << 10) | (uint32_t)(b & 0x3FF);
}

static struct hdr_image *hdr_image_create(int width, int height) {
	struct hdr_image *img = calloc(1, sizeof(*img));
	if (!img) {
		return NULL;
	}
	img->surface = cairo_image_surface_create(CAIRO_FORMAT_RGB30, width, height);
	if (cairo_surface_status(img->surface) != CAIRO_STATUS_SUCCESS) {
		asteroidzbg_log(LOG_ERROR, "Failed to allocate a %dx%d RGB30 surface: %s",
				width, height,
				cairo_status_to_string(cairo_surface_status(img->surface)));
		hdr_image_destroy(img);
		return NULL;
	}
	return img;
}

void hdr_image_destroy(struct hdr_image *image) {
	if (!image) {
		return;
	}
	if (image->surface) {
		cairo_surface_destroy(image->surface);
	}
	free(image);
}

#if HAVE_LIBAVIF
/* AVIF carries CICP directly in the container, so the HDR decision is exact. */
static struct hdr_image *load_avif(const char *path) {
	avifDecoder *decoder = avifDecoderCreate();
	if (!decoder) {
		return NULL;
	}

	struct hdr_image *img = NULL;
	avifRGBImage rgb;
	memset(&rgb, 0, sizeof(rgb));
	bool rgb_allocated = false;

	avifResult res = avifDecoderSetIOFile(decoder, path);
	if (res != AVIF_RESULT_OK) {
		/* not an AVIF, or unreadable -- stay quiet, the caller will try the
		 * SDR loader next and report a single combined error if that fails */
		goto out;
	}
	res = avifDecoderParse(decoder);
	if (res != AVIF_RESULT_OK) {
		goto out;
	}

	bool is_pq = decoder->image->transferCharacteristics ==
			AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084;
	bool is_hlg = decoder->image->transferCharacteristics ==
			AVIF_TRANSFER_CHARACTERISTICS_HLG;
	if (!is_pq && !is_hlg) {
		/* An SDR AVIF. gdk-pixbuf may well handle it, and going through the
		 * 8-bit path keeps behaviour identical to swaybg. */
		goto out;
	}

	res = avifDecoderNextImage(decoder);
	if (res != AVIF_RESULT_OK) {
		asteroidzbg_log(LOG_ERROR, "Failed to decode AVIF image: %s",
				avifResultToString(res));
		goto out;
	}

	img = hdr_image_create(decoder->image->width, decoder->image->height);
	if (!img) {
		goto out;
	}

	avifRGBImageSetDefaults(&rgb, decoder->image);
	rgb.format = AVIF_RGB_FORMAT_RGB;
	rgb.depth = 10;
	rgb.ignoreAlpha = AVIF_TRUE;
	if (avifRGBImageAllocatePixels(&rgb) != AVIF_RESULT_OK) {
		hdr_image_destroy(img);
		img = NULL;
		goto out;
	}
	rgb_allocated = true;

	res = avifImageYUVToRGB(decoder->image, &rgb);
	if (res != AVIF_RESULT_OK) {
		asteroidzbg_log(LOG_ERROR, "Failed to convert AVIF to RGB: %s",
				avifResultToString(res));
		hdr_image_destroy(img);
		img = NULL;
		goto out;
	}

	cairo_surface_flush(img->surface);
	uint32_t *dst = (uint32_t *)cairo_image_surface_get_data(img->surface);
	int dst_stride = cairo_image_surface_get_stride(img->surface) / 4;
	for (uint32_t y = 0; y < rgb.height; y++) {
		const uint16_t *src = (const uint16_t *)(rgb.pixels + (size_t)y * rgb.rowBytes);
		uint32_t *row = dst + (size_t)y * dst_stride;
		for (uint32_t x = 0; x < rgb.width; x++) {
			row[x] = pack_rgb30(src[x * 3], src[x * 3 + 1], src[x * 3 + 2]);
		}
	}
	cairo_surface_mark_dirty(img->surface);

	img->is_hdr = true;
	img->tf = is_pq ? HDR_TF_PQ : HDR_TF_HLG;
	img->primaries = decoder->image->colorPrimaries == AVIF_COLOR_PRIMARIES_BT2020
			? HDR_PRIM_BT2020 : HDR_PRIM_SRGB;

	asteroidzbg_log(LOG_DEBUG, "Loaded %ux%u HDR AVIF (%s, %s)",
			rgb.width, rgb.height, is_pq ? "PQ" : "HLG",
			img->primaries == HDR_PRIM_BT2020 ? "BT.2020" : "BT.709");

out:
	if (rgb_allocated) {
		avifRGBImageFreePixels(&rgb);
	}
	avifDecoderDestroy(decoder);
	return img;
}
#endif // HAVE_LIBAVIF

#if HAVE_LIBJXL
static uint8_t *read_whole_file(const char *path, size_t *out_size) {
	FILE *f = fopen(path, "rb");
	if (!f) {
		return NULL;
	}
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return NULL;
	}
	long len = ftell(f);
	if (len <= 0) {
		fclose(f);
		return NULL;
	}
	rewind(f);
	uint8_t *data = malloc((size_t)len);
	if (!data) {
		fclose(f);
		return NULL;
	}
	size_t got = fread(data, 1, (size_t)len, f);
	if (got != (size_t)len) {
		free(data);
		fclose(f);
		return NULL;
	}
	fclose(f);
	*out_size = (size_t)len;
	return data;
}

/* JPEG XL. Decoded as 16-bit unsigned and shifted down to 10, which keeps the
 * decoder path simple; JXL's own float pipeline would only matter if we were
 * resampling in linear light, which we deliberately are not. */
static struct hdr_image *load_jxl(const char *path) {
	size_t size = 0;
	uint8_t *data = read_whole_file(path, &size);
	if (!data) {
		return NULL;
	}

	if (JxlSignatureCheck(data, size) == JXL_SIG_INVALID ||
			JxlSignatureCheck(data, size) == JXL_SIG_NOT_ENOUGH_BYTES) {
		free(data);
		return NULL;
	}

	JxlDecoder *dec = JxlDecoderCreate(NULL);
	if (!dec) {
		free(data);
		return NULL;
	}

	struct hdr_image *img = NULL;
	uint16_t *pixels = NULL;
	JxlBasicInfo info;
	JxlColorEncoding color;
	bool have_color = false;

	if (JxlDecoderSubscribeEvents(dec,
			JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING | JXL_DEC_FULL_IMAGE)
			!= JXL_DEC_SUCCESS) {
		goto out;
	}
	JxlDecoderSetInput(dec, data, size);
	JxlDecoderCloseInput(dec);

	JxlPixelFormat fmt = {
		.num_channels = 3,
		.data_type = JXL_TYPE_UINT16,
		.endianness = JXL_NATIVE_ENDIAN,
		.align = 0,
	};

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_ERROR || status == JXL_DEC_NEED_MORE_INPUT) {
			goto out;
		} else if (status == JXL_DEC_BASIC_INFO) {
			if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) {
				goto out;
			}
		} else if (status == JXL_DEC_COLOR_ENCODING) {
			have_color = JxlDecoderGetColorAsEncodedProfile(dec,
					JXL_COLOR_PROFILE_TARGET_DATA, &color) == JXL_DEC_SUCCESS;
		} else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			size_t needed = 0;
			if (JxlDecoderImageOutBufferSize(dec, &fmt, &needed) != JXL_DEC_SUCCESS) {
				goto out;
			}
			pixels = malloc(needed);
			if (!pixels ||
					JxlDecoderSetImageOutBuffer(dec, &fmt, pixels, needed)
						!= JXL_DEC_SUCCESS) {
				goto out;
			}
		} else if (status == JXL_DEC_FULL_IMAGE) {
			break;
		} else if (status == JXL_DEC_SUCCESS) {
			break;
		}
	}

	if (!pixels) {
		goto out;
	}

	/* Only claim HDR when the file says PQ or HLG. An SDR JXL falls through
	 * to gdk-pixbuf exactly like an SDR AVIF does. */
	if (!have_color) {
		goto out;
	}
	bool is_pq = color.transfer_function == JXL_TRANSFER_FUNCTION_PQ;
	bool is_hlg = color.transfer_function == JXL_TRANSFER_FUNCTION_HLG;
	if (!is_pq && !is_hlg) {
		goto out;
	}

	img = hdr_image_create(info.xsize, info.ysize);
	if (!img) {
		goto out;
	}

	cairo_surface_flush(img->surface);
	uint32_t *dst = (uint32_t *)cairo_image_surface_get_data(img->surface);
	int dst_stride = cairo_image_surface_get_stride(img->surface) / 4;
	for (uint32_t y = 0; y < info.ysize; y++) {
		const uint16_t *src = pixels + (size_t)y * info.xsize * 3;
		uint32_t *row = dst + (size_t)y * dst_stride;
		for (uint32_t x = 0; x < info.xsize; x++) {
			row[x] = pack_rgb30(src[x * 3] >> 6, src[x * 3 + 1] >> 6,
					src[x * 3 + 2] >> 6);
		}
	}
	cairo_surface_mark_dirty(img->surface);

	img->is_hdr = true;
	img->tf = is_pq ? HDR_TF_PQ : HDR_TF_HLG;
	img->primaries = color.primaries == JXL_PRIMARIES_2100
			? HDR_PRIM_BT2020 : HDR_PRIM_SRGB;

	asteroidzbg_log(LOG_DEBUG, "Loaded %ux%u HDR JPEG XL (%s, %s)",
			info.xsize, info.ysize, is_pq ? "PQ" : "HLG",
			img->primaries == HDR_PRIM_BT2020 ? "BT.2020" : "BT.709");

out:
	free(pixels);
	JxlDecoderDestroy(dec);
	free(data);
	return img;
}
#endif // HAVE_LIBJXL

struct hdr_image *hdr_image_load(const char *path) {
	/* declared unconditionally: with only one decoder enabled the other
	 * block vanishes, and a declaration inside the first #if would leave
	 * the second referring to nothing */
	struct hdr_image *img = NULL;
#if HAVE_LIBAVIF
	img = load_avif(path);
	if (img) {
		return img;
	}
#endif
#if HAVE_LIBJXL
	img = load_jxl(path);
	if (img) {
		return img;
	}
#endif
	(void)path;
	return img;
}
