/*
 * pzcore - image decoding, resampling and non-destructive filter kernels
 * for Pizzicato. Plain C ABI so it can be linked into the Lazarus/FPC app.
 *
 * All images are 32-bit BGRA (alpha = 255 for opaque images), rows tightly
 * packed (stride = w * 4), returned upright (EXIF orientation applied).
 */
#ifndef PZCORE_H
#define PZCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t w, h;
    uint32_t* px;
} pz_image;

typedef struct {
    int32_t width, height;   /* full-resolution size, upright */
    int32_t orientation;     /* EXIF orientation of the source (1..8) */
    int32_t is_raw;          /* 1 for camera raw (dng, pef, cr2, ...) */
    int32_t format;          /* PZ_FMT_* */
    int64_t taken;           /* capture time, seconds since epoch (local), 0 = unknown */
    float exposure, fnumber, iso, focal;
    char make[32];
    char model[64];
    char lens[64];
} pz_meta;

enum { PZ_FMT_UNKNOWN = 0, PZ_FMT_JPEG, PZ_FMT_PNG, PZ_FMT_GIF, PZ_FMT_RAW, PZ_FMT_TIFF, PZ_FMT_WEBP };

/* pz_load flags */
#define PZ_THUMB       1   /* fastest path: embedded previews, fast IDCT     */
#define PZ_RAW_FULL    2   /* full demosaic for raw (else half-size)          */
#define PZ_NO_PREVIEW  4   /* raw: never substitute the embedded preview      */
#define PZ_PREVIEW_ONLY 8  /* raw: only return the embedded preview (fast)    */

/* Load and downscale so the result fits in maxw x maxh (0 = no limit).
 * Returns 0 on success, negative on error. */
int pz_load(const char* path, int maxw, int maxh, int flags, pz_image* img, pz_meta* meta);
/* Metadata only (cheap). */
int pz_probe(const char* path, pz_meta* meta);
int pz_format_of(const char* path);

int  pz_alloc(pz_image* img, int w, int h);
void pz_free(pz_image* img);
int  pz_copy(const pz_image* src, pz_image* dst);
/* High quality area-average resample into dst (allocated by callee). */
int  pz_resize(const pz_image* src, int w, int h, pz_image* dst);
int  pz_orient(pz_image* img, int orientation);   /* in place (realloc) */
int  pz_rotate90(pz_image* img, int quarter_turns_cw);

int  pz_decode_jpeg_mem(const unsigned char* buf, unsigned long len, int maxw, int maxh,
                        int fast, pz_image* img);
int  pz_encode_jpeg_mem(const pz_image* img, int quality, unsigned char** out, unsigned long* outlen);
void pz_free_mem(void* p);
int  pz_save_jpeg(const char* path, const pz_image* img, int quality);
/* an 8-bit grayscale PNG (masks); 0 on success */
int  pz_save_png_gray(const char* path, int w, int h, const unsigned char* px);

/* ---- filters (all in place unless stated) ---- */
typedef struct {
    uint8_t lut[3][256];      /* B, G, R */
} pz_lut;

void pz_lut_identity(pz_lut* l);
void pz_apply_lut(pz_image* img, const pz_lut* l);

/* histogram: 4 x 256 (B, G, R, luma) */
void pz_histogram(const pz_image* img, uint32_t hist[4][256]);

/* tone: Picasa-style fill light / highlights / shadows plus
 * brightness / contrast extension; all amounts 0..1 (bright/contrast -1..1) */
void pz_tone(pz_image* img, float fill, float highlights, float shadows,
             float brightness, float contrast);
/* colour temperature (-1..1, positive = warmer) and neutral-point pick */
void pz_color(pz_image* img, float temperature, uint32_t neutral_argb);
void pz_autolight(pz_image* img);
void pz_autocolor(pz_image* img);
void pz_saturation(pz_image* img, float factor);           /* 1 = unchanged */
void pz_boost(pz_image* img, float amount);                 /* 0..1 */
void pz_bw(pz_image* img);
void pz_sepia(pz_image* img);
void pz_warm(pz_image* img);
void pz_sharpen(pz_image* img, float amount, float radius); /* unsharp mask */
void pz_softfocus(pz_image* img, float amount);
void pz_vignette(pz_image* img, float amount);
/* geometry: crop (normalised l,t,r,b) and straighten (degrees, zoom to fill) */
int  pz_crop(pz_image* img, float l, float t, float r, float b);
int  pz_tilt(pz_image* img, float degrees);

/* scores of n int8 vectors of d values (row i scaled by scale[i]) against
 * the float query q: out[i] = scale[i] * dot(m[i], q). For embedding search. */
void pz_dot_i8(const int8_t* m, const float* scale, int n, int d, const float* q, float* out);

/* number of worker threads used by the kernels */
void pz_set_threads(int n);
const char* pz_version(void);

#ifdef __cplusplus
}
#endif
#endif
