#pragma once

// HDR -> SDR, for a picture that has to be looked at on an SDR surface.
//
// The wallpaper itself never needs this: asteroidzbg hands the compositor the
// PQ pixels and a BT.2020/PQ image description, and the compositor does the
// right thing with them. A THUMBNAIL has no such luxury. It is drawn into the
// settings window, which is an ordinary sRGB surface, so the picker was
// showing raw PQ code values interpreted as plain gamma: a 4000-nit sunset
// came out as a flat grey rectangle, and the two HDR files in a folder of
// thirty-seven read as broken tiles rather than as pictures.
//
// Deliberately plain doubles and no Qt, so the curve can be unit-tested
// without an image, a decoder or a display (tests/test_tonemap.cpp).
//
// The path, in order, is the one every HDR->SDR conversion uses:
//
//   code value -> absolute luminance   (the file's own transfer function)
//              -> relative to white    (BT.2408 reference white, 203 cd/m²)
//              -> BT.709 primaries     (only if the file is BT.2020)
//              -> tone mapped          (extended Reinhard, image-adaptive)
//              -> sRGB encoded
//
// Tone mapping happens AFTER the gamut conversion, and the gamut conversion
// clamps: BT.2020 covers colours BT.709 has no way to express, and the matrix
// answers with a negative channel for those. Rolling off a negative number is
// meaningless, and letting it through inverts the highlight.

namespace tonemap {

// BT.2408 HDR reference white: the luminance an SDR "white" sits at inside an
// HDR grade. Dividing by it is what makes a diffuse white page in an HDR photo
// land where a white page belongs, rather than at 1/50th of peak.
inline constexpr double kReferenceWhite = 203.0;

// SMPTE ST 2084. `e` is the encoded value in 0..1, the result is absolute
// luminance in cd/m² (0..10000).
double pqEotfNits(double e);

// ARIB STD-B67 inverse OETF: encoded 0..1 -> scene-linear 0..1, before the
// OOTF. Applied per channel; hlgOotfScale() supplies the rest.
double hlgInverseOetf(double e);

// The HLG OOTF's per-pixel scale factor, from the scene-linear triple. Applied
// to all three channels equally, which is what makes it a system gamma rather
// than a per-channel curve.
double hlgOotfScale(double rScene, double gScene, double bScene, double peakNits);

// BT.2020 -> BT.709, in linear light. In place, and NOT clamped -- the caller
// clamps, because whether an out-of-gamut colour should become 0 or should be
// desaturated is the caller's decision to make once, not this function's to
// make three times per pixel.
void bt2020ToSrgb(double& r, double& g, double& b);

// Extended Reinhard. `x` is relative to reference white (1.0 == diffuse
// white); `lw` is the brightest value in the image, in the same units.
//
// The extension is the whole point: plain x/(1+x) sends 1.0 to 0.5 and infinity
// to 1.0, so the brightest pixel in the picture lands wherever it happens to
// land and no image ever reaches white. This form maps `lw` to exactly 1.0,
// so the highlight in the file is the highlight on screen, and everything
// below it keeps its order.
double reinhard(double x, double lw);

// Linear 0..1 -> sRGB encoded 0..1.
double srgbOetf(double x);

// Clamp to 0..1. Named because it appears at three different points and
// "which clamp was that" is a question worth not having.
double clamp01(double x);

} // namespace tonemap
