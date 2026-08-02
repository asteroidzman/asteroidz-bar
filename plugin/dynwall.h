#pragma once

/* Apple dynamic wallpapers: one HEIC holding several images and a schedule
 * saying which of them belongs to the time of day.
 *
 * `~/Pictures/Dome.heic` is one. Every ordinary decoder -- gdk-pixbuf here
 * included -- shows its PRIMARY image and nothing else, so the file looks like
 * an ordinary still and the other frames are invisible. The schedule lives in
 * an XMP property, `apple_desktop:h24` or `apple_desktop:solar`, as a base64
 * binary plist:
 *
 *   { ti: [ {t: 0.0, i: 0}, {t: 0.5, i: 1} ], ap: {d: 1, l: 0} }
 *
 * `ti` is the time table -- `t` is a fraction of the day, `i` an index into the
 * file's top-level images. `ap` is the light/dark pair, for a desktop that
 * follows an appearance setting rather than the clock.
 *
 * Plain C in its own translation unit, like imageformats.c and for the same
 * reason: this includes libheif, and the C++ side stays clear of it. */

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>

struct azbar_dyn_frame {
	/* When this frame takes over, as a fraction of the day: 0.0 is midnight,
	 * 0.5 is midday. Apple's own unit -- kept rather than converted to
	 * minutes, so nothing is rounded on the way in. */
	double t;
	/* Solar schedules only: `t` carries the sun's ALTITUDE in degrees for
	 * these, and this its azimuth. Both zero and unused for a clock table. */
	double azimuth;
	int index;
};

struct azbar_dyn_schedule {
	struct azbar_dyn_frame *frames;
	size_t n_frames;
	/* From `ap`, or -1 when the file does not carry one. */
	int light_index;
	int dark_index;
	/* The sun-position variant (`apple_desktop:solar`) rather than the clock
	 * one. Its table is keyed by solar altitude and azimuth, which cannot be
	 * evaluated without knowing where on Earth this machine is -- so the
	 * frames are read but the caller is told to fall back to the light/dark
	 * pair rather than pretending to a precision it does not have. */
	bool solar;
	/* How many top-level images the file actually holds. A schedule may name
	 * an index that is not there; that is the file being wrong, and it is
	 * better to notice than to decode whatever is at that offset. */
	size_t n_images;
};

/* Read the schedule. False when the file is not a dynamic wallpaper at all,
 * which is the ordinary case and not an error.
 *
 * On success the caller owns `out->frames` and frees it with
 * azbar_dyn_schedule_free. */
bool azbar_dyn_schedule_read(const char *path, struct azbar_dyn_schedule *out);
void azbar_dyn_schedule_free(struct azbar_dyn_schedule *s);

/* The same, from an XMP document already in hand.
 *
 * Split out because it is the half with no I/O in it: finding the property,
 * un-base64-ing it and walking the binary plist is where the fiddly work is,
 * and testing it should not require synthesising a HEIC -- which needs an
 * encoder, and would tie the test to whichever files happen to be on the
 * machine. `n_images` is not set here; the caller knows it. */
bool azbar_dyn_parse_xmp(const char *xmp, size_t len,
		struct azbar_dyn_schedule *out);

/* Which frame belongs at `fraction` of the day (0.0 .. 1.0).
 *
 * The table is a list of start times, so the answer is the LAST entry at or
 * before now -- and before the first entry it wraps to the last one, because
 * the frame that started at 22:00 is still the one showing at 01:00. Returns
 * -1 if there is nothing to choose from. */
int azbar_dyn_frame_at(const struct azbar_dyn_schedule *s, double fraction);

/* Where the sun is, for a place and a moment: altitude above the horizon and
 * azimuth clockwise from north, both in degrees.
 *
 * The standard low-precision solar position (accurate to about a hundredth of
 * a degree, which is four orders of magnitude better than a wallpaper needs).
 * No network and no clock skew beyond the system's own -- the alternative,
 * asking a weather API for sunrise and sunset, is a round trip for something
 * that is arithmetic. */
void azbar_sun_position(double lat, double lon, long long unix_time,
		double *altitude, double *azimuth);

/* Which frame of a SOLAR schedule belongs at that sun position.
 *
 * The table is keyed by altitude, and altitude alone is ambiguous -- the sun
 * passes through 20 degrees twice a day -- so azimuth breaks the tie: entries
 * are matched within the same half of the day, morning against morning. Apple
 * stores azimuth clockwise from north, so east of the meridian is rising.
 *
 * Returns -1 when the schedule is not solar or has no entries. */
int azbar_dyn_frame_at_sun(const struct azbar_dyn_schedule *s, double altitude,
		double azimuth);

/* When the frame chosen at `fraction` gives way to the next, as a fraction of
 * the day. Always strictly ahead of `fraction`; may be >= 1.0, meaning it
 * happens tomorrow. Returns -1 if there is nothing scheduled. */
double azbar_dyn_next_change(const struct azbar_dyn_schedule *s, double fraction);

/* Decode one top-level image out of the file and write it to `dest` as a PNG.
 *
 * A PNG intermediate, which is where the HDR path stops: the tagging that
 * carries BT.2020/PQ through to the compositor rides on the AVIF/JXL CICP
 * boxes, and PNG has nowhere to put it. An 8-bit dynamic wallpaper -- which is
 * what Apple ships -- is unaffected and lossless; a 10-bit one is drawn as
 * SDR, which is worth knowing rather than discovering.
 *
 * Returns true on success. On failure `err`, if given, is set to a
 * heap-allocated message for the caller to free. */
bool azbar_dyn_extract(const char *path, int index, const char *dest, char **err);

#ifdef __cplusplus
}
#endif
