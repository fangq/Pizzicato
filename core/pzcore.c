/*
 * pzcore.c - decoding, resampling and filter kernels for Pizzicato
 *
 * Decoders: libjpeg-turbo (DCT-domain downscaling, direct BGRA output),
 * libpng (simplified API), giflib, libwebp, libheif and LibRaw (thread-safe
 * libraw_r).  Raw thumbnails come from the embedded JPEG previews found by
 * our own TIFF walker, so a thumbnail costs two small reads, not a demosaic.
 */
#define _GNU_SOURCE
#include "pzcore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <math.h>
#include <setjmp.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <omp.h>

#include <jpeglib.h>
#include <png.h>
#include <gif_lib.h>
#include <webp/decode.h>
#include <libheif/heif.h>
#include <libraw/libraw.h>

#define PZ_MIN(a, b) ((a) < (b) ? (a) : (b))
#define PZ_MAX(a, b) ((a) > (b) ? (a) : (b))
/* only go parallel on images big enough to amortise thread wake-ups;
 * small images (thumbnails) stay on the calling worker thread */
#define PZ_PAR(npix) ((npix) > 600000)
#define CLAMP255(v) ((v) < 0 ? 0 : ((v) > 255 ? 255 : (v)))

const char* pz_version(void) {
    return "pzcore 0.1";
}

void pz_set_threads(int n) {
    if (n > 0) {
        omp_set_num_threads(n);
    }
}

/* ------------------------------------------------------------------ */
/* image helpers                                                       */
/* ------------------------------------------------------------------ */

int pz_alloc(pz_image* img, int w, int h) {
    img->w = w;
    img->h = h;
    img->px = (uint32_t*)malloc((size_t)w * h * 4 + 16);
    return img->px ? 0 : -1;
}

void pz_free(pz_image* img) {
    if (img && img->px) {
        free(img->px);
        img->px = NULL;
    }
}

void pz_free_mem(void* p) {
    free(p);
}

int pz_copy(const pz_image* src, pz_image* dst) {
    if (pz_alloc(dst, src->w, src->h)) {
        return -1;
    }

    memcpy(dst->px, src->px, (size_t)src->w * src->h * 4);
    return 0;
}

static void fill_opaque(pz_image* img) {
    size_t n = (size_t)img->w * img->h;

    for (size_t i = 0; i < n; i++) {
        img->px[i] |= 0xFF000000u;
    }
}

/* ---- separable antialiased resampler (triangle filter, Pillow-style) ---- */

typedef struct {
    int* start, *count;
    int32_t* w; /* 14-bit fixed weights, stride = maxk */
    int maxk;
} pz_coeffs;

static int make_coeffs(int insize, int outsize, pz_coeffs* c) {
    double scale = (double)insize / outsize;
    double fscale = scale > 1.0 ? scale : 1.0;
    double support = 1.0 * fscale;
    int maxk = (int)ceil(support) * 2 + 1;
    c->maxk = maxk;
    c->start = malloc(sizeof(int) * outsize);
    c->count = malloc(sizeof(int) * outsize);
    c->w = malloc(sizeof(int32_t) * outsize * maxk);
    double* tmp = malloc(sizeof(double) * maxk);

    if (!c->start || !c->count || !c->w || !tmp) {
        free(tmp);
        return -1;
    }

    for (int i = 0; i < outsize; i++) {
        double center = (i + 0.5) * scale;
        int xmin = (int)floor(center - support + 0.5);
        int xmax = (int)floor(center + support + 0.5);

        if (xmin < 0) {
            xmin = 0;
        }

        if (xmax > insize) {
            xmax = insize;
        }

        int n = xmax - xmin;

        if (n > maxk) {
            n = maxk;
        }

        double ww = 0;

        for (int k = 0; k < n; k++) {
            double x = (k + xmin - center + 0.5) / fscale;
            double v = 1.0 - fabs(x);

            if (v < 0) {
                v = 0;
            }

            tmp[k] = v;
            ww += v;
        }

        int32_t* wp = c->w + i * maxk;
        int32_t acc = 0;

        for (int k = 0; k < n; k++) {
            wp[k] = (int32_t)lround(tmp[k] / (ww > 0 ? ww : 1) * 16384.0);
            acc += wp[k];
        }

        if (n > 0 && acc != 16384) { /* keep weights summing to unity */
            wp[n / 2] += 16384 - acc;
        }

        c->start[i] = xmin;
        c->count[i] = n;
    }

    free(tmp);
    return 0;
}

static void free_coeffs(pz_coeffs* c) {
    free(c->start);
    free(c->count);
    free(c->w);
}

int pz_resize(const pz_image* src, int w, int h, pz_image* dst) {
    dst->px = NULL;

    if (w < 1) {
        w = 1;
    }

    if (h < 1) {
        h = 1;
    }

    if (w == src->w && h == src->h) {
        return pz_copy(src, dst);
    }

    pz_coeffs cx, cy;

    if (make_coeffs(src->w, w, &cx)) {
        return -1;
    }

    if (make_coeffs(src->h, h, &cy)) {
        free_coeffs(&cx);
        return -1;
    }

    /* horizontal pass: src->h rows x w cols, only rows that are needed */
    uint32_t* tmp = malloc((size_t)w * src->h * 4);

    if (!tmp || pz_alloc(dst, w, h)) {
        free(tmp);
        free_coeffs(&cx);
        free_coeffs(&cy);
        return -1;
    }

    #pragma omp parallel for schedule(static) if (PZ_PAR((size_t)w * src->h))

    for (int y = 0; y < src->h; y++) {
        const uint8_t* in = (const uint8_t*)(src->px + (size_t)y * src->w);
        uint8_t* out = (uint8_t*)(tmp + (size_t)y * w);

        for (int x = 0; x < w; x++) {
            const int32_t* wp = cx.w + x * cx.maxk;
            const uint8_t* p = in + cx.start[x] * 4;
            int32_t b = 8192, g = 8192, r = 8192, a = 8192;

            for (int k = 0; k < cx.count[x]; k++, p += 4) {
                b += p[0] * wp[k];
                g += p[1] * wp[k];
                r += p[2] * wp[k];
                a += p[3] * wp[k];
            }

            b >>= 14;
            g >>= 14;
            r >>= 14;
            a >>= 14;
            out[4 * x + 0] = CLAMP255(b);
            out[4 * x + 1] = CLAMP255(g);
            out[4 * x + 2] = CLAMP255(r);
            out[4 * x + 3] = CLAMP255(a);
        }
    }

    /* vertical pass */
    #pragma omp parallel for schedule(static) if (PZ_PAR((size_t)w * h))

    for (int y = 0; y < h; y++) {
        const int32_t* wp = cy.w + y * cy.maxk;
        uint8_t* out = (uint8_t*)(dst->px + (size_t)y * w);

        for (int x = 0; x < w; x++) {
            int32_t b = 8192, g = 8192, r = 8192, a = 8192;
            const uint8_t* p = (const uint8_t*)(tmp + (size_t)cy.start[y] * w + x);

            for (int k = 0; k < cy.count[y]; k++, p += (size_t)w * 4) {
                b += p[0] * wp[k];
                g += p[1] * wp[k];
                r += p[2] * wp[k];
                a += p[3] * wp[k];
            }

            b >>= 14;
            g >>= 14;
            r >>= 14;
            a >>= 14;
            out[4 * x + 0] = CLAMP255(b);
            out[4 * x + 1] = CLAMP255(g);
            out[4 * x + 2] = CLAMP255(r);
            out[4 * x + 3] = CLAMP255(a);
        }
    }

    free(tmp);
    free_coeffs(&cx);
    free_coeffs(&cy);
    return 0;
}

/* shrink so it fits maxw x maxh (keeps aspect); no-op when it already fits */
static int fit_into(pz_image* img, int maxw, int maxh) {
    if ((maxw <= 0 || img->w <= maxw) && (maxh <= 0 || img->h <= maxh)) {
        return 0;
    }

    double s = 1e9;

    if (maxw > 0) {
        s = PZ_MIN(s, (double)maxw / img->w);
    }

    if (maxh > 0) {
        s = PZ_MIN(s, (double)maxh / img->h);
    }

    int w = (int)lround(img->w * s), h = (int)lround(img->h * s);
    pz_image d;

    if (pz_resize(img, w, h, &d)) {
        return -1;
    }

    pz_free(img);
    *img = d;
    return 0;
}

int pz_rotate90(pz_image* img, int q) {
    q = ((q % 4) + 4) % 4;

    if (q == 0) {
        return 0;
    }

    static const int map[4] = {1, 6, 3, 8};
    return pz_orient(img, map[q]);
}

/* apply EXIF orientation so the image becomes upright */
int pz_orient(pz_image* img, int o) {
    if (o <= 1 || o > 8) {
        return 0;
    }

    int w = img->w, h = img->h;
    int swap = o >= 5;
    pz_image d;

    if (pz_alloc(&d, swap ? h : w, swap ? w : h)) {
        return -1;
    }

    int dw = d.w;
    #pragma omp parallel for schedule(static) if (PZ_PAR((size_t)w * h))

    for (int y = 0; y < h; y++) {
        const uint32_t* s = img->px + (size_t)y * w;

        for (int x = 0; x < w; x++) {
            int dx, dy;

            switch (o) {
                case 2:
                    dx = w - 1 - x;
                    dy = y;
                    break;

                case 3:
                    dx = w - 1 - x;
                    dy = h - 1 - y;
                    break;

                case 4:
                    dx = x;
                    dy = h - 1 - y;
                    break;

                case 5:
                    dx = y;
                    dy = x;
                    break;

                case 6:
                    dx = h - 1 - y;
                    dy = x;
                    break;

                case 7:
                    dx = h - 1 - y;
                    dy = w - 1 - x;
                    break;

                case 8:
                    dx = y;
                    dy = w - 1 - x;
                    break;

                default:
                    dx = x;
                    dy = y;
            }

            d.px[(size_t)dy * dw + dx] = s[x];
        }
    }

    pz_free(img);
    *img = d;
    return 0;
}

/* ------------------------------------------------------------------ */
/* file helpers                                                        */
/* ------------------------------------------------------------------ */

static unsigned char* read_file(const char* path, size_t maxlen, size_t* len) {
    int fd = open(path, O_RDONLY);

    if (fd < 0) {
        return NULL;
    }

    struct stat st;

    if (fstat(fd, &st)) {
        close(fd);
        return NULL;
    }

    size_t n = (size_t)st.st_size;

    if (maxlen && n > maxlen) {
        n = maxlen;
    }

    unsigned char* buf = malloc(n + 1);

    if (!buf) {
        close(fd);
        return NULL;
    }

    size_t got = 0;

    while (got < n) {
        ssize_t r = read(fd, buf + got, n - got);

        if (r <= 0) {
            break;
        }

        got += (size_t)r;
    }

    close(fd);
    *len = got;
    return buf;
}

static unsigned char* read_range(int fd, uint64_t off, size_t len) {
    unsigned char* buf = malloc(len + 1);

    if (!buf) {
        return NULL;
    }

    ssize_t r = pread(fd, buf, len, (off_t)off);

    if (r != (ssize_t)len) {
        free(buf);
        return NULL;
    }

    return buf;
}

static const char* raw_exts[] = {"dng", "pef", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2",
                                 "orf", "rw2", "raf", "raw", "rwl", "srw", "x3f", "3fr", "iiq", "mos",
                                 "mrw", "kdc", "dcr", "erf", "mef", "ptx", NULL
                                };

int pz_format_of(const char* path) {
    const char* dot = strrchr(path, '.');

    if (dot) {
        dot++;

        for (int i = 0; raw_exts[i]; i++)
            if (!strcasecmp(dot, raw_exts[i])) {
                return PZ_FMT_RAW;
            }
    }

    unsigned char m[16] = {0};
    int fd = open(path, O_RDONLY);

    if (fd < 0) {
        return PZ_FMT_UNKNOWN;
    }

    ssize_t n = read(fd, m, sizeof(m));
    close(fd);

    if (n < 4) {
        return PZ_FMT_UNKNOWN;
    }

    if (m[0] == 0xFF && m[1] == 0xD8) {
        return PZ_FMT_JPEG;
    }

    if (m[0] == 0x89 && m[1] == 'P' && m[2] == 'N' && m[3] == 'G') {
        return PZ_FMT_PNG;
    }

    if (!memcmp(m, "GIF8", 4)) {
        return PZ_FMT_GIF;
    }

    if (n >= 12 && !memcmp(m, "RIFF", 4) && !memcmp(m + 8, "WEBP", 4)) {
        return PZ_FMT_WEBP;
    }

    if (n >= 12 && !memcmp(m + 4, "ftyp", 4) &&
            (!memcmp(m + 8, "heic", 4) || !memcmp(m + 8, "heix", 4) || !memcmp(m + 8, "mif1", 4) ||
             !memcmp(m + 8, "msf1", 4) || !memcmp(m + 8, "avif", 4))) {
        return PZ_FMT_TIFF + 100;    /* HEIF, see below */
    }

    if ((m[0] == 'I' && m[1] == 'I' && m[2] == 42) || (m[0] == 'M' && m[1] == 'M' && m[3] == 42)) {
        return PZ_FMT_TIFF;
    }

    return PZ_FMT_UNKNOWN;
}
#define PZ_FMT_HEIF (PZ_FMT_TIFF + 100)

/* ------------------------------------------------------------------ */
/* TIFF / EXIF walker                                                  */
/* ------------------------------------------------------------------ */

typedef struct {
    const uint8_t* b;
    size_t n;
    int le;
    size_t base; /* offset of the TIFF header within the file (JPEG APP1) */
} tiff_t;

static unsigned t16(const tiff_t* t, size_t o) {
    if (o + 2 > t->n) {
        return 0;
    }

    const uint8_t* p = t->b + o;
    return t->le ? (unsigned)(p[0] | p[1] << 8) : (unsigned)(p[0] << 8 | p[1]);
}

static uint32_t t32(const tiff_t* t, size_t o) {
    if (o + 4 > t->n) {
        return 0;
    }

    const uint8_t* p = t->b + o;
    return t->le ? (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24
           : (uint32_t)p[3] | (uint32_t)p[2] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[0] << 24;
}

static int64_t days_from_civil(int y, unsigned m, unsigned d) {
    y -= m <= 2;
    const int era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return (int64_t)era * 146097 + (int64_t)doe - 719468;
}

static int64_t parse_exif_date(const char* s) {
    int Y, M, D, h = 0, mi = 0, se = 0;

    if (sscanf(s, "%d:%d:%d %d:%d:%d", &Y, &M, &D, &h, &mi, &se) < 3 || Y < 1900 || M < 1 || M > 12) {
        return 0;
    }

    return days_from_civil(Y, (unsigned)M, (unsigned)D) * 86400 + h * 3600 + mi * 60 + se;
}

typedef struct {
    uint64_t off;
    uint32_t len;
    int w, h;
} prev_cand;

typedef struct {
    /* best JPEG preview found (file offsets) */
    uint64_t prev_off;
    uint32_t prev_len;
    int prev_w, prev_h;
    prev_cand cand[8];
    int ncand;
    /* main (largest) image */
    int main_w, main_h;
    int crop_w, crop_h; /* DNG DefaultCropSize */
    int is_dng;
} tiff_scan;

static double t_rational(const tiff_t* t, size_t off, int is_signed) {
    uint32_t a = t32(t, off), b = t32(t, off + 4);

    if (!b) {
        return 0;
    }

    if (is_signed) {
        return (double)(int32_t)a / (double)(int32_t)b;
    }

    return (double)a / b;
}

static void t_string(const tiff_t* t, size_t off, uint32_t cnt, char* dst, size_t dsz) {
    size_t n = PZ_MIN((size_t)cnt, dsz - 1);

    if (off + n > t->n) {
        dst[0] = 0;
        return;
    }

    memcpy(dst, t->b + off, n);
    dst[n] = 0;

    /* trim */
    while (n > 0 && (dst[n - 1] == ' ' || dst[n - 1] == 0)) {
        dst[--n] = 0;
    }
}

static void walk_ifd(const tiff_t* t, uint32_t off, int depth, int is_exif, pz_meta* m, tiff_scan* sc);

static void add_cand(tiff_scan* sc, uint64_t off, uint32_t len, int w, int h) {
    if (!sc || !len || sc->ncand >= 8) {
        return;
    }

    prev_cand* pc = &sc->cand[sc->ncand++];
    pc->off = off;
    pc->len = len;
    pc->w = w;
    pc->h = h;
}

/* Pentax maker notes carry a ~640x480 JPEG preview (tags 2/3/4). Layouts:
 *   "PENTAX \0" + "MM|II" + IFD, offsets relative to the maker note start
 *   "AOC\0"     + "MM|II" + IFD, offsets relative to the TIFF header
 *   DNGPrivateData "Adobe\0MakN" wrapper around either of the above */
static void parse_pentax_mn(const tiff_t* t, size_t mn, size_t len, tiff_scan* sc) {
    if (!sc || mn + 16 > t->n) {
        return;
    }

    const uint8_t* p = t->b + mn;
    int64_t adj = 0; /* added to stored offsets to get offsets within t->b */

    if (!memcmp(p, "Adobe\0MakN", 10)) {
        tiff_t bt = {t->b, t->n, 0, 0};
        uint32_t orig = t32(&bt, mn + 16);
        mn += 20;
        len = len > 20 ? len - 20 : 0;
        p = t->b + mn;

        if (mn + 16 > t->n) {
            return;
        }

        /* original maker note offsets were relative to the original file;
         * relocate them relative to where the copy lives now */
        adj = (int64_t)mn - (int64_t)orig;

        if (!memcmp(p, "PENTAX \0", 8)) {
            adj = (int64_t)mn;
        }
    } else if (!memcmp(p, "PENTAX \0", 8)) {
        adj = (int64_t)mn;
    }

    size_t ifd;
    tiff_t mt = *t;

    if (!memcmp(p, "PENTAX \0", 8)) {
        mt.le = p[8] == 'I';
        ifd = mn + 10;
    } else if (!memcmp(p, "AOC\0", 4)) {
        mt.le = p[4] == 'I' ? 1 : (p[4] == 'M' ? 0 : t->le);
        ifd = mn + 6;
    } else {
        return;
    }

    unsigned n = t16(&mt, ifd);

    if (n == 0 || n > 400) {
        return;
    }

    uint32_t plen = 0, pstart = 0;
    int pw = 0, ph = 0;

    for (unsigned i = 0; i < n; i++) {
        size_t e = ifd + 2 + i * 12;
        unsigned tag = t16(&mt, e);

        if (tag == 2) {
            pw = (int)t16(&mt, e + 8);
            ph = (int)t16(&mt, e + 10);
        } else if (tag == 3) {
            plen = t32(&mt, e + 8);
        } else if (tag == 4) {
            pstart = t32(&mt, e + 8);
        }
    }

    if (plen > 100 && pstart) {
        int64_t o = (int64_t)pstart + adj;

        if (o > 0) {
            add_cand(sc, (uint64_t)o + t->base, plen, pw ? pw : 640, ph ? ph : 480);
        }
    }

    (void)len;
}

static void walk_ifd_chain(const tiff_t* t, uint32_t off, int depth, pz_meta* m, tiff_scan* sc) {
    int guard = 0;

    while (off && off < t->n && guard++ < 8) {
        walk_ifd(t, off, depth, 0, m, sc);
        unsigned n = t16(t, off);
        off = t32(t, off + 2 + n * 12);
    }
}

static void walk_ifd(const tiff_t* t, uint32_t off, int depth, int is_exif, pz_meta* m, tiff_scan* sc) {
    if (depth > 4 || off + 2 > t->n) {
        return;
    }

    unsigned n = t16(t, off);

    if (n > 1000) {
        return;
    }

    uint32_t subfile = 0, width = 0, height = 0, comp = 0, bps = 0;
    uint64_t strip_off = 0, jif_off = 0;
    uint32_t strip_len = 0, jif_len = 0;
    int strips = 0;

    for (unsigned i = 0; i < n; i++) {
        size_t e = off + 2 + i * 12;
        unsigned tag = t16(t, e), type = t16(t, e + 2);
        uint32_t cnt = t32(t, e + 4);
        static const int tsize[] = {0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4};
        size_t sz = (type < 14 ? tsize[type] : 1) * (size_t)cnt;
        size_t voff = sz <= 4 ? e + 8 : t32(t, e + 8);
        uint32_t val = type == 3 ? t16(t, e + 8) : t32(t, e + 8);

        switch (tag) {
            case 0xFE:
                subfile = val;
                break;

            case 0x100:
                width = val;
                break;

            case 0x101:
                height = val;
                break;

            case 0x102:
                bps = t16(t, voff);
                break;

            case 0x103:
                comp = val;
                break;

            case 0x10F:
                if (m && !m->make[0]) {
                    t_string(t, voff, cnt, m->make, sizeof(m->make));
                }

                break;

            case 0x110:
                if (m && !m->model[0]) {
                    t_string(t, voff, cnt, m->model, sizeof(m->model));
                }

                break;

            case 0x111:
                strips = (int)cnt;
                strip_off = type == 3 ? t16(t, voff) : t32(t, voff);
                break;

            case 0x117:
                strip_len = type == 3 ? t16(t, voff) : t32(t, voff);
                break;

            case 0x112:
                if (m && depth == 0 && !is_exif) {
                    m->orientation = (int)t16(t, e + 8);
                }

                break;

            case 0x132:
                if (m && !m->taken) {
                    char s[32];
                    t_string(t, voff, cnt, s, sizeof(s));
                    m->taken = parse_exif_date(s);
                }

                break;

            case 0x201:
                jif_off = val;
                break;

            case 0x202:
                jif_len = val;
                break;

            case 0x14A: /* SubIFDs */
                for (uint32_t k = 0; k < cnt && k < 8; k++) {
                    uint32_t so = cnt == 1 ? val : t32(t, voff + 4 * k);
                    walk_ifd(t, so, depth + 1, 0, m, sc);
                }

                break;

            case 0x8769:
                walk_ifd(t, val, depth + 1, 1, m, sc);
                break;

            case 0x829A:
                if (m) {
                    m->exposure = (float)t_rational(t, voff, 0);
                }

                break;

            case 0x829D:
                if (m) {
                    m->fnumber = (float)t_rational(t, voff, 0);
                }

                break;

            case 0x8827:
                if (m) {
                    m->iso = (float)(type == 3 ? t16(t, e + 8) : val);
                }

                break;

            case 0x9003:
                if (m) {
                    char s[32];
                    t_string(t, voff, cnt, s, sizeof(s));
                    int64_t d = parse_exif_date(s);

                    if (d) {
                        m->taken = d;
                    }
                }

                break;

            case 0x920A:
                if (m) {
                    m->focal = (float)t_rational(t, voff, 0);
                }

                break;

            case 0xA434:
                if (m) {
                    t_string(t, voff, cnt, m->lens, sizeof(m->lens));
                }

                break;

            case 0xA002:
                if (m && is_exif && !m->width) {
                    m->width = (int)val;
                }

                break;

            case 0xA003:
                if (m && is_exif && !m->height) {
                    m->height = (int)val;
                }

                break;

            case 0xC612:
                if (sc) {
                    sc->is_dng = 1;
                }

                break;

            case 0xC634: /* DNGPrivateData */
            case 0x927C: /* MakerNote */
                if (voff < t->n) {
                    parse_pentax_mn(t, voff, cnt, sc);
                }

                break;

            case 0xC620: /* DefaultCropSize */
                if (sc) {
                    if (type == 3) {
                        sc->crop_w = (int)t16(t, voff);
                        sc->crop_h = (int)t16(t, voff + 2);
                    } else if (type == 4) {
                        sc->crop_w = (int)t32(t, voff);
                        sc->crop_h = (int)t32(t, voff + 4);
                    } else if (type == 5) {
                        sc->crop_w = (int)lround(t_rational(t, voff, 0));
                        sc->crop_h = (int)lround(t_rational(t, voff + 8, 0));
                    }
                }

                break;
        }
    }

    if (!sc || is_exif) {
        return;
    }

    if (width && height && (int)(width * height) > sc->main_w * sc->main_h && bps > 8) {
        sc->main_w = (int)width;
        sc->main_h = (int)height;
    }

    /* candidate JPEG preview: 8-bit, JPEG compressed (6 = old-style, 7 = new) */
    uint64_t po = 0;
    uint32_t pl = 0;

    if (jif_off && jif_len) {
        po = jif_off;
        pl = jif_len;
    } else if ((comp == 7 || comp == 6) && strips == 1 && (bps == 8 || bps == 0) && (subfile & 1)) {
        po = strip_off;
        pl = strip_len;
    }

    if (po && pl > 100) {
        int pw = (int)width, ph = (int)height;

        if (!pw) { /* IFD1 thumbnails often lack sizes: guess from length */
            pw = 160;
            ph = 120;
        }

        add_cand(sc, po + t->base, pl, pw, ph);

        if (pw * ph > sc->prev_w * sc->prev_h) {
            sc->prev_w = pw;
            sc->prev_h = ph;
            sc->prev_off = po + t->base;
            sc->prev_len = pl;
        }
    }
}

static int parse_tiff(const uint8_t* b, size_t n, size_t base, pz_meta* m, tiff_scan* sc) {
    if (n < 8) {
        return -1;
    }

    tiff_t t = {b, n, 0, base};

    if (b[0] == 'I' && b[1] == 'I') {
        t.le = 1;
    } else if (b[0] == 'M' && b[1] == 'M') {
        t.le = 0;
    } else {
        return -1;
    }

    uint32_t ifd0 = t32(&t, 4);
    walk_ifd_chain(&t, ifd0, 0, m, sc);
    return 0;
}

static const char* month_names = "JanFebMarAprMayJunJulAugSepOctNovDec";

/* JPEG: scan markers for APP1 Exif and SOFn */
static int jpeg_scan(const uint8_t* b, size_t n, pz_meta* m, tiff_scan* sc) {
    size_t i = 2;

    while (i + 4 <= n) {
        if (b[i] != 0xFF) {
            i++;
            continue;
        }

        uint8_t mk = b[i + 1];

        if (mk == 0xFF) {
            i++;
            continue;
        }

        if (mk == 0xD8 || (mk >= 0xD0 && mk <= 0xD7) || mk == 0x01) {
            i += 2;
            continue;
        }

        size_t L = (size_t)b[i + 2] << 8 | b[i + 3];

        if (mk == 0xE1 && i + 10 <= n && !memcmp(b + i + 4, "Exif\0", 5) && !(m && m->make[0] && 0)) {
            size_t st = i + 10, len = PZ_MIN(L - 8, n - st);
            parse_tiff(b + st, len, st, m, sc);
        } else if ((mk >= 0xC0 && mk <= 0xCF) && mk != 0xC4 && mk != 0xC8 && mk != 0xCC) {
            if (i + 9 <= n && m) {
                m->height = (int)(b[i + 5] << 8 | b[i + 6]);
                m->width = (int)(b[i + 7] << 8 | b[i + 8]);
            }

            return 0;
        } else if (mk == 0xDA) {
            return 0;
        }

        i += 2 + L;
    }

    (void)month_names;
    return m && m->width ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* JPEG                                                                */
/* ------------------------------------------------------------------ */

struct pz_jerr {
    struct jpeg_error_mgr pub;
    jmp_buf jb;
};

static void pz_jerr_exit(j_common_ptr c) {
    longjmp(((struct pz_jerr*)c->err)->jb, 1);
}
static void pz_jerr_msg(j_common_ptr c) {
    (void)c;
}

int pz_decode_jpeg_mem(const unsigned char* buf, unsigned long len, int maxw, int maxh, int fast,
                       pz_image* img) {
    struct jpeg_decompress_struct ci;
    struct pz_jerr je;
    img->px = NULL;
    ci.err = jpeg_std_error(&je.pub);
    je.pub.error_exit = pz_jerr_exit;
    je.pub.output_message = pz_jerr_msg;
    uint8_t* cmyk_row = NULL;

    if (setjmp(je.jb)) {
        jpeg_destroy_decompress(&ci);
        free(cmyk_row);

        /* keep whatever was decoded of a truncated file */
        if (img->px && img->w > 0) {
            return 1;
        }

        pz_free(img);
        return -3;
    }

    jpeg_create_decompress(&ci);
    jpeg_mem_src(&ci, buf, len);
    jpeg_read_header(&ci, TRUE);
    int cmyk = ci.jpeg_color_space == JCS_CMYK || ci.jpeg_color_space == JCS_YCCK;
    ci.out_color_space = cmyk ? JCS_CMYK : JCS_EXT_BGRA;

    /* choose the smallest N/8 scale that still covers the target box */
    if (maxw > 0 || maxh > 0) {
        double s = 1.0;

        if (maxw > 0) {
            s = PZ_MIN(s, (double)maxw / ci.image_width);
        }

        if (maxh > 0) {
            s = PZ_MIN(s, (double)maxh / ci.image_height);
        }

        int N = (int)ceil(s * 8.0 - 1e-6);

        if (fast && N > 1 && s * 8.0 < N - 0.5) { /* thumbnails can be a bit soft */
            N--;
        }

        N = N < 1 ? 1 : (N > 8 ? 8 : N);

        /* only power-of-two scales are SIMD accelerated in turbo */
        if (N == 3) {
            N = 4;
        } else if (N > 4 && N < 8) {
            N = 8;
        }

        ci.scale_num = (unsigned)N;
        ci.scale_denom = 8;
    }

    if (fast) {
        ci.dct_method = JDCT_IFAST;
        ci.do_fancy_upsampling = FALSE;
    } else {
        ci.dct_method = JDCT_ISLOW;
    }

    jpeg_start_decompress(&ci);

    if (pz_alloc(img, (int)ci.output_width, (int)ci.output_height)) {
        longjmp(je.jb, 1);
    }

    img->h = 0; /* rows actually decoded, for truncated files */
    int H = (int)ci.output_height;

    if (cmyk) {
        cmyk_row = malloc(ci.output_width * 4);

        while ((int)ci.output_scanline < H) {
            JSAMPROW rp = cmyk_row;
            jpeg_read_scanlines(&ci, &rp, 1);
            uint8_t* d = (uint8_t*)(img->px + (size_t)img->h * img->w);
            int inv = ci.saw_Adobe_marker;

            for (unsigned x = 0; x < ci.output_width; x++) {
                int c = cmyk_row[4 * x], mm = cmyk_row[4 * x + 1], y = cmyk_row[4 * x + 2], k = cmyk_row[4 * x + 3];

                if (!inv) {
                    c = 255 - c;
                    mm = 255 - mm;
                    y = 255 - y;
                    k = 255 - k;
                }

                d[4 * x + 2] = (uint8_t)(c * k / 255);
                d[4 * x + 1] = (uint8_t)(mm * k / 255);
                d[4 * x + 0] = (uint8_t)(y * k / 255);
                d[4 * x + 3] = 255;
            }

            img->h++;
        }

        free(cmyk_row);
        cmyk_row = NULL;
    } else {
        JSAMPROW rows[16];

        while ((int)ci.output_scanline < H) {
            int k;

            for (k = 0; k < 16; k++) {
                rows[k] = (JSAMPROW)(img->px + (size_t)(ci.output_scanline + k) * img->w);
            }

            int got = (int)jpeg_read_scanlines(&ci, rows, (JDIMENSION)PZ_MIN(16, H - (int)ci.output_scanline));
            img->h += got;

            if (got == 0) {
                break;
            }
        }
    }

    jpeg_finish_decompress(&ci);
    jpeg_destroy_decompress(&ci);

    if (img->h != H) {
        img->h = H; /* rows past the truncation stay as allocated */
    }

    return 0;
}

int pz_encode_jpeg_mem(const pz_image* img, int quality, unsigned char** out, unsigned long* outlen) {
    struct jpeg_compress_struct ci;
    struct pz_jerr je;
    *out = NULL;
    *outlen = 0;
    ci.err = jpeg_std_error(&je.pub);
    je.pub.error_exit = pz_jerr_exit;
    je.pub.output_message = pz_jerr_msg;

    if (setjmp(je.jb)) {
        jpeg_destroy_compress(&ci);
        free(*out);
        *out = NULL;
        return -1;
    }

    jpeg_create_compress(&ci);
    jpeg_mem_dest(&ci, out, outlen);
    ci.image_width = (JDIMENSION)img->w;
    ci.image_height = (JDIMENSION)img->h;
    ci.input_components = 4;
    ci.in_color_space = JCS_EXT_BGRA;
    jpeg_set_defaults(&ci);
    jpeg_set_quality(&ci, quality, TRUE);
    ci.dct_method = JDCT_ISLOW;

    if (quality >= 90) { /* 4:4:4 for final output */
        ci.comp_info[0].h_samp_factor = 1;
        ci.comp_info[0].v_samp_factor = 1;
    }

    jpeg_start_compress(&ci, TRUE);

    while (ci.next_scanline < ci.image_height) {
        JSAMPROW r = (JSAMPROW)(img->px + (size_t)ci.next_scanline * img->w);
        jpeg_write_scanlines(&ci, &r, 1);
    }

    jpeg_finish_compress(&ci);
    jpeg_destroy_compress(&ci);
    return 0;
}

int pz_save_jpeg(const char* path, const pz_image* img, int quality) {
    unsigned char* buf;
    unsigned long len;

    if (pz_encode_jpeg_mem(img, quality, &buf, &len)) {
        return -1;
    }

    FILE* f = fopen(path, "wb");

    if (!f) {
        free(buf);
        return -2;
    }

    size_t w = fwrite(buf, 1, len, f);
    fclose(f);
    free(buf);
    return w == len ? 0 : -3;
}

/* swap target box for images that will be rotated by 90 degrees */
static void oriented_box(int o, int* maxw, int* maxh) {
    if (o >= 5 && o <= 8) {
        int t = *maxw;
        *maxw = *maxh;
        *maxh = t;
    }
}

static void crop_to_aspect(pz_image* img, int full_w, int full_h);

/* size of a JPEG from its SOF marker, without decoding */
static int jpeg_dims(const uint8_t* b, size_t n, int* w, int* h) {
    pz_meta mm;
    memset(&mm, 0, sizeof(mm));

    if (n < 4 || b[0] != 0xFF || b[1] != 0xD8) {
        return -1;
    }

    jpeg_scan(b, n, &mm, NULL);
    *w = mm.width;
    *h = mm.height;
    return *w > 0 ? 0 : -1;
}

static int load_jpeg(const char* path, int maxw, int maxh, int flags, pz_image* img, pz_meta* m) {
    size_t len;
    unsigned char* buf;
    tiff_scan sc;
    memset(&sc, 0, sizeof(sc));

    if (flags & PZ_THUMB) {
        /* thumbnails: the EXIF thumbnail (510x384 on Pixel phones) is often
         * enough, and it sits in the first few KB of the file */
        size_t hl = 192 * 1024;
        buf = read_file(path, hl, &len);

        if (!buf) {
            return -2;
        }

        jpeg_scan(buf, len, m, &sc);

        if (!m->orientation) {
            m->orientation = 1;
        }

        int bw = maxw, bh = maxh;
        oriented_box(m->orientation, &bw, &bh);

        for (int k = 0; k < sc.ncand; k++) {
            prev_cand* pc = &sc.cand[k];
            int tw, th;

            if (pc->off + pc->len > len || jpeg_dims(buf + pc->off, pc->len, &tw, &th)) {
                continue;
            }

            /* must cover ~90% of the box once fitted */
            double need = PZ_MIN((double)bw / PZ_MAX(m->width, 1), (double)bh / PZ_MAX(m->height, 1));

            if (m->width <= 0 || m->height <= 0) {
                need = 1.0;
            }

            if (tw < 0.9 * PZ_MIN(bw, m->width * need) && th < 0.9 * PZ_MIN(bh, m->height * need)) {
                continue;
            }

            if (pz_decode_jpeg_mem(buf + pc->off, pc->len, bw, bh, 1, img) < 0) {
                continue;
            }

            free(buf);

            if (m->width > 0) {
                crop_to_aspect(img, m->width, m->height);
            }

            fit_into(img, bw, bh);
            pz_orient(img, m->orientation);

            if (m->orientation >= 5) {
                int t = m->width;
                m->width = m->height;
                m->height = t;
            }

            return 0;
        }

        if (len < hl) { /* whole file already read */
            memset(m, 0, sizeof(*m));
            goto have_buf;
        }

        free(buf);
        memset(m, 0, sizeof(*m));
        memset(&sc, 0, sizeof(sc));
    }

    buf = read_file(path, 0, &len);

    if (!buf) {
        return -2;
    }

have_buf:
    memset(&sc, 0, sizeof(sc));
    jpeg_scan(buf, len, m, &sc);

    if (!m->orientation) {
        m->orientation = 1;
    }

    int bw = maxw, bh = maxh;
    oriented_box(m->orientation, &bw, &bh);
    int rc = pz_decode_jpeg_mem(buf, len, bw, bh, flags & PZ_THUMB, img);
    free(buf);

    if (rc < 0) {
        return rc;
    }

    fit_into(img, bw, bh);
    pz_orient(img, m->orientation);

    if (m->orientation >= 5) {
        int t = m->width;
        m->width = m->height;
        m->height = t;
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/* PNG / GIF / WebP / HEIF                                             */
/* ------------------------------------------------------------------ */

static int load_png(const char* path, int maxw, int maxh, pz_image* img, pz_meta* m) {
    png_image pi;
    memset(&pi, 0, sizeof(pi));
    pi.version = PNG_IMAGE_VERSION;

    if (!png_image_begin_read_from_file(&pi, path)) {
        return -3;
    }

    pi.format = PNG_FORMAT_BGRA;

    if (pz_alloc(img, (int)pi.width, (int)pi.height)) {
        png_image_free(&pi);
        return -1;
    }

    if (!png_image_finish_read(&pi, NULL, img->px, 0, NULL)) {
        png_image_free(&pi);
        pz_free(img);
        return -3;
    }

    /* composite over white so transparent art stays readable */
    size_t n = (size_t)img->w * img->h;
    uint8_t* p = (uint8_t*)img->px;

    for (size_t i = 0; i < n; i++, p += 4) {
        unsigned a = p[3];

        if (a != 255) {
            p[0] = (uint8_t)((p[0] * a + 255 * (255 - a)) / 255);
            p[1] = (uint8_t)((p[1] * a + 255 * (255 - a)) / 255);
            p[2] = (uint8_t)((p[2] * a + 255 * (255 - a)) / 255);
            p[3] = 255;
        }
    }

    m->width = img->w;
    m->height = img->h;
    m->orientation = 1;
    return fit_into(img, maxw, maxh);
}

static int load_gif(const char* path, int maxw, int maxh, pz_image* img, pz_meta* m) {
    int err = 0;
    GifFileType* g = DGifOpenFileName(path, &err);

    if (!g) {
        return -3;
    }

    if (DGifSlurp(g) != GIF_OK || g->ImageCount < 1) {
        DGifCloseFile(g, &err);
        return -3;
    }

    int W = g->SWidth, H = g->SHeight;
    SavedImage* si = &g->SavedImages[0];

    if (W <= 0 || H <= 0) {
        W = si->ImageDesc.Width;
        H = si->ImageDesc.Height;
    }

    ColorMapObject* cm = si->ImageDesc.ColorMap ? si->ImageDesc.ColorMap : g->SColorMap;
    int trans = -1;
    GraphicsControlBlock gcb;

    if (DGifSavedExtensionToGCB(g, 0, &gcb) == GIF_OK) {
        trans = gcb.TransparentColor;
    }

    if (!cm || pz_alloc(img, W, H)) {
        DGifCloseFile(g, &err);
        return -3;
    }

    for (size_t i = 0; i < (size_t)W * H; i++) {
        img->px[i] = 0xFFFFFFFFu;
    }

    int L = si->ImageDesc.Left, T = si->ImageDesc.Top, w = si->ImageDesc.Width, h = si->ImageDesc.Height;

    for (int y = 0; y < h; y++) {
        if (y + T < 0 || y + T >= H) {
            continue;
        }

        for (int x = 0; x < w; x++) {
            if (x + L < 0 || x + L >= W) {
                continue;
            }

            int c = si->RasterBits[y * w + x];

            if (c == trans || c >= cm->ColorCount) {
                continue;
            }

            GifColorType col = cm->Colors[c];
            img->px[(size_t)(y + T) * W + x + L] =
                0xFF000000u | (uint32_t)col.Red << 16 | (uint32_t)col.Green << 8 | col.Blue;
        }
    }

    DGifCloseFile(g, &err);
    m->width = W;
    m->height = H;
    m->orientation = 1;
    return fit_into(img, maxw, maxh);
}

static int load_webp(const char* path, int maxw, int maxh, pz_image* img, pz_meta* m) {
    size_t len;
    unsigned char* buf = read_file(path, 0, &len);

    if (!buf) {
        return -2;
    }

    int w, h;

    if (!WebPGetInfo(buf, len, &w, &h) || pz_alloc(img, w, h)) {
        free(buf);
        return -3;
    }

    if (!WebPDecodeBGRAInto(buf, len, (uint8_t*)img->px, (size_t)w * h * 4, w * 4)) {
        free(buf);
        pz_free(img);
        return -3;
    }

    free(buf);
    fill_opaque(img);
    m->width = w;
    m->height = h;
    m->orientation = 1;
    return fit_into(img, maxw, maxh);
}

static int load_heif(const char* path, int maxw, int maxh, int flags, pz_image* img, pz_meta* m) {
    struct heif_context* ctx = heif_context_alloc();
    struct heif_image_handle* hd = NULL;
    struct heif_image* hi = NULL;
    int rc = -3;

    if (heif_context_read_from_file(ctx, path, NULL).code != heif_error_Ok) {
        goto done;
    }

    if (heif_context_get_primary_image_handle(ctx, &hd).code != heif_error_Ok) {
        goto done;
    }

    m->width = heif_image_handle_get_width(hd);
    m->height = heif_image_handle_get_height(hd);
    m->orientation = 1; /* libheif applies irot/imir itself */
    struct heif_image_handle* src = hd, *th = NULL;

    if (flags & PZ_THUMB) { /* use embedded thumbnail when big enough */
        heif_item_id ids[4];
        int nt = heif_image_handle_get_list_of_thumbnail_IDs(hd, ids, 4);

        if (nt > 0 && heif_image_handle_get_thumbnail(hd, ids[0], &th).code == heif_error_Ok) {
            if (heif_image_handle_get_width(th) >= maxw * 3 / 4 || heif_image_handle_get_height(th) >= maxh * 3 / 4) {
                src = th;
            }
        }
    }

    if (heif_decode_image(src, &hi, heif_colorspace_RGB, heif_chroma_interleaved_RGBA, NULL).code != heif_error_Ok) {
        if (th) {
            heif_image_handle_release(th);
        }

        goto done;
    }

    {
        int stride;
        const uint8_t* p = heif_image_get_plane_readonly(hi, heif_channel_interleaved, &stride);
        int w = heif_image_get_width(hi, heif_channel_interleaved), h = heif_image_get_height(hi, heif_channel_interleaved);

        if (p && !pz_alloc(img, w, h)) {
            for (int y = 0; y < h; y++) {
                const uint8_t* s = p + (size_t)y * stride;
                uint8_t* d = (uint8_t*)(img->px + (size_t)y * w);

                for (int x = 0; x < w; x++) {
                    d[4 * x] = s[4 * x + 2];
                    d[4 * x + 1] = s[4 * x + 1];
                    d[4 * x + 2] = s[4 * x];
                    d[4 * x + 3] = 255;
                }
            }

            rc = fit_into(img, maxw, maxh);
        }
    }

    heif_image_release(hi);

    if (th) {
        heif_image_handle_release(th);
    }

done:

    if (hd) {
        heif_image_handle_release(hd);
    }

    heif_context_free(ctx);
    return rc;
}

/* ------------------------------------------------------------------ */
/* RAW                                                                 */
/* ------------------------------------------------------------------ */

static int libraw_flip_to_exif(int flip) {
    switch (flip) {
        case 3:
            return 3;

        case 5:
            return 8;

        case 6:
            return 6;

        default:
            return 1;
    }
}

/* crop black letterbox bars from a preview whose aspect differs from the raw */
static void crop_to_aspect(pz_image* img, int full_w, int full_h) {
    if (full_w <= 0 || full_h <= 0 || img->w <= 0 || img->h <= 0) {
        return;
    }

    double ar = (double)full_w / full_h, pr = (double)img->w / img->h;

    if ((ar > 1) != (pr > 1)) { /* preview not in the same orientation, leave it */
        return;
    }

    if (fabs(ar / pr - 1.0) < 0.02) {
        return;
    }

    int w = img->w, h = img->h, x0 = 0, y0 = 0;

    if (ar > pr) { /* bars top/bottom */
        h = (int)lround(img->w / ar);
        y0 = (img->h - h) / 2;
    } else {
        w = (int)lround(img->h * ar);
        x0 = (img->w - w) / 2;
    }

    pz_crop(img, (float)x0 / img->w, (float)y0 / img->h, (float)(x0 + w) / img->w, (float)(y0 + h) / img->h);
}

/* parse a TIFF-based raw header (DNG, PEF, NEF, ARW, CR2, ...) */
static int raw_scan_header(int fd, pz_meta* m, tiff_scan* sc) {
    size_t hl = 256 * 1024;
    unsigned char* hb = malloc(hl);

    if (!hb) {
        return -1;
    }

    ssize_t n = pread(fd, hb, hl, 0);

    if (n < 16) {
        free(hb);
        return -1;
    }

    int rc = parse_tiff(hb, (size_t)n, 0, m, sc);
    free(hb);
    return rc;
}

static int load_raw_preview(const char* path, int maxw, int maxh, pz_image* img, pz_meta* m, int need_full_size) {
    int fd = open(path, O_RDONLY);

    if (fd < 0) {
        return -2;
    }

    tiff_scan sc;
    memset(&sc, 0, sizeof(sc));
    int rc = raw_scan_header(fd, m, &sc);

    for (int k = 0; k < sc.ncand; k++)
        if (sc.cand[k].w * sc.cand[k].h > sc.prev_w * sc.prev_h) {
            sc.prev_w = sc.cand[k].w;
            sc.prev_h = sc.cand[k].h;
            sc.prev_off = sc.cand[k].off;
            sc.prev_len = sc.cand[k].len;
        }

    if (rc || !sc.prev_len) {
        close(fd);
        return -4;
    }

    int fw = sc.crop_w ? sc.crop_w : sc.main_w, fh = sc.crop_h ? sc.crop_h : sc.main_h;

    if (!m->orientation) {
        m->orientation = 1;
    }

    int bw = maxw, bh = maxh;
    oriented_box(m->orientation, &bw, &bh);

    if (need_full_size && (sc.prev_w < bw * 9 / 10 && sc.prev_h < bh * 9 / 10)) {
        close(fd);
        return -5; /* preview too small for this request */
    }

    /* smallest candidate that still covers the box, else the largest */
    prev_cand best = {sc.prev_off, sc.prev_len, sc.prev_w, sc.prev_h};

    for (int k = 0; k < sc.ncand && (bw > 0 || bh > 0); k++) {
        prev_cand* pc = &sc.cand[k];
        int covers = (bw <= 0 || pc->w >= bw) || (bh <= 0 || pc->h >= bh);
        int bcovers = (bw <= 0 || best.w >= bw) || (bh <= 0 || best.h >= bh);

        if (covers && (!bcovers || pc->w * pc->h < best.w * best.h)) {
            best = *pc;
        }
    }

    unsigned char* jb = read_range(fd, best.off, best.len);
    close(fd);

    if (!jb) {
        return -2;
    }

    /* decode at reduced DCT scale; slack for the letterbox crop that follows */
    rc = pz_decode_jpeg_mem(jb, best.len, bw > 0 ? bw * 11 / 10 : 0, bh > 0 ? bh * 11 / 10 : 0, need_full_size ? 0 : 1, img);
    free(jb);

    if (rc < 0) {
        return rc;
    }

    crop_to_aspect(img, fw, fh);
    fit_into(img, bw, bh);
    pz_orient(img, m->orientation);
    m->width = fw;
    m->height = fh;

    if (m->orientation >= 5) {
        int t = m->width;
        m->width = m->height;
        m->height = t;
    }

    m->is_raw = 1;
    return 0;
}

static void meta_from_libraw(libraw_data_t* lr, pz_meta* m) {
    snprintf(m->make, sizeof(m->make), "%s", lr->idata.make);
    snprintf(m->model, sizeof(m->model), "%s", lr->idata.model);
    snprintf(m->lens, sizeof(m->lens), "%s", lr->lens.Lens);
    m->iso = lr->other.iso_speed;
    m->exposure = lr->other.shutter;
    m->fnumber = lr->other.aperture;
    m->focal = lr->other.focal_len;

    if (lr->other.timestamp) { /* libraw gives UTC epoch of local wall time via mktime */
        struct tm tm;
        time_t ts = lr->other.timestamp;
        localtime_r(&ts, &tm);
        m->taken = days_from_civil(tm.tm_year + 1900, (unsigned)tm.tm_mon + 1, (unsigned)tm.tm_mday) * 86400 +
                   tm.tm_hour * 3600 + tm.tm_min * 60 + tm.tm_sec;
    }

    m->orientation = libraw_flip_to_exif(lr->sizes.flip);
    m->width = lr->sizes.iwidth << lr->params.half_size;
    m->height = lr->sizes.iheight << lr->params.half_size;

    if (lr->sizes.flip == 5 || lr->sizes.flip == 6) {
        int t = m->width;
        m->width = m->height;
        m->height = t;
    }

    m->is_raw = 1;
}

/* libraw-only thumbnail path for formats our TIFF walker cannot handle */
static int load_raw_libraw_thumb(const char* path, int maxw, int maxh, pz_image* img, pz_meta* m) {
    libraw_data_t* lr = libraw_init(0);

    if (!lr) {
        return -1;
    }

    int rc = -4;

    if (libraw_open_file(lr, path) == LIBRAW_SUCCESS && libraw_unpack_thumb(lr) == LIBRAW_SUCCESS) {
        meta_from_libraw(lr, m);
        int bw = maxw, bh = maxh;
        oriented_box(m->orientation, &bw, &bh);

        if (lr->thumbnail.tformat == LIBRAW_THUMBNAIL_JPEG) {
            rc = pz_decode_jpeg_mem((unsigned char*)lr->thumbnail.thumb, lr->thumbnail.tlength, bw > 0 ? bw * 11 / 10 : 0, bh > 0 ? bh * 11 / 10 : 0, 1, img);
        } else if (lr->thumbnail.tformat == LIBRAW_THUMBNAIL_BITMAP && lr->thumbnail.tcolors == 3) {
            int w = lr->thumbnail.twidth, h = lr->thumbnail.theight;

            if (!pz_alloc(img, w, h)) {
                const uint8_t* s = (const uint8_t*)lr->thumbnail.thumb;

                for (int i = 0; i < w * h; i++) {
                    img->px[i] = 0xFF000000u | (uint32_t)s[3 * i] << 16 | (uint32_t)s[3 * i + 1] << 8 | s[3 * i + 2];
                }

                rc = 0;
            }
        }

        if (rc >= 0) {
            int fw = m->width, fh = m->height;

            if (m->orientation >= 5) {
                fw = m->height;
                fh = m->width;
            }

            crop_to_aspect(img, fw, fh);
            fit_into(img, bw, bh);
            pz_orient(img, m->orientation);
            rc = 0;
        }
    }

    libraw_close(lr);
    return rc;
}

static int load_raw_decode(const char* path, int maxw, int maxh, int flags, pz_image* img, pz_meta* m) {
    libraw_data_t* lr = libraw_init(0);

    if (!lr) {
        return -1;
    }

    int full = (flags & PZ_RAW_FULL) != 0;
    lr->params.use_camera_wb = 1;
    lr->params.output_bps = 8;
    lr->params.user_flip = 0;
    lr->params.half_size = full ? 0 : 1;
    lr->params.user_qual = full ? 3 : 0; /* AHD for full res, half-size needs none */
    int rc = -4;

    if (libraw_open_file(lr, path) != LIBRAW_SUCCESS) {
        goto out;
    }

    /* if half size is still far bigger than needed, nothing more to do in libraw */
    if (libraw_unpack(lr) != LIBRAW_SUCCESS) {
        goto out;
    }

    if (libraw_dcraw_process(lr) != LIBRAW_SUCCESS) {
        goto out;
    }

    int err = 0;
    libraw_processed_image_t* pi = libraw_dcraw_make_mem_image(lr, &err);

    if (!pi) {
        goto out;
    }

    if (pi->colors == 3 && pi->bits == 8 && !pz_alloc(img, pi->width, pi->height)) {
        const uint8_t* s = pi->data;
        size_t n = (size_t)pi->width * pi->height;
        #pragma omp parallel for schedule(static) if (PZ_PAR(n))

        for (size_t i = 0; i < n; i++) {
            img->px[i] = 0xFF000000u | (uint32_t)s[3 * i] << 16 | (uint32_t)s[3 * i + 1] << 8 | s[3 * i + 2];
        }

        rc = 0;
    }

    libraw_dcraw_clear_mem(pi);

    if (rc == 0) {
        meta_from_libraw(lr, m);
        int bw = maxw, bh = maxh;
        oriented_box(m->orientation, &bw, &bh);
        fit_into(img, bw, bh);
        pz_orient(img, m->orientation);

        if (!full) { /* report the true sensor size, not the half-size output */
            m->width = lr->sizes.width;
            m->height = lr->sizes.height;

            if (m->orientation >= 5) {
                int t = m->width;
                m->width = m->height;
                m->height = t;
            }
        }
    }

out:
    libraw_close(lr);
    return rc;
}

static int load_raw(const char* path, int maxw, int maxh, int flags, pz_image* img, pz_meta* m) {
    if (!(flags & PZ_NO_PREVIEW)) {
        int thumb = (flags & (PZ_THUMB | PZ_PREVIEW_ONLY)) != 0;
        pz_meta mm = *m;

        if (load_raw_preview(path, maxw, maxh, img, &mm, !thumb) == 0) {
            *m = mm;
            return 0;
        }

        if (thumb) {
            mm = *m;

            if (load_raw_libraw_thumb(path, maxw, maxh, img, &mm) == 0) {
                *m = mm;
                return 0;
            }

            if (flags & PZ_PREVIEW_ONLY) {
                return -5;
            }
        }
    }

    int rc = load_raw_decode(path, maxw, maxh, flags, img, m);

    if (rc == 0) { /* keep the EXIF date from our walker if libraw had none */
        pz_meta mm;
        memset(&mm, 0, sizeof(mm));
        int fd = open(path, O_RDONLY);

        if (fd >= 0) {
            tiff_scan sc;
            memset(&sc, 0, sizeof(sc));

            if (!raw_scan_header(fd, &mm, &sc) && mm.taken) {
                m->taken = mm.taken;
            }

            close(fd);
        }
    }

    return rc;
}

/* ------------------------------------------------------------------ */
/* public loaders                                                      */
/* ------------------------------------------------------------------ */

int pz_load(const char* path, int maxw, int maxh, int flags, pz_image* img, pz_meta* meta) {
    pz_meta tmp;
    pz_meta* m = meta ? meta : &tmp;
    memset(m, 0, sizeof(*m));
    img->px = NULL;
    img->w = img->h = 0;
    int fmt = pz_format_of(path);
    int rc;

    switch (fmt) {
        case PZ_FMT_JPEG:
            rc = load_jpeg(path, maxw, maxh, flags, img, m);
            break;

        case PZ_FMT_PNG:
            rc = load_png(path, maxw, maxh, img, m);
            break;

        case PZ_FMT_GIF:
            rc = load_gif(path, maxw, maxh, img, m);
            break;

        case PZ_FMT_WEBP:
            rc = load_webp(path, maxw, maxh, img, m);
            break;

        case PZ_FMT_HEIF:
            rc = load_heif(path, maxw, maxh, flags, img, m);
            fmt = PZ_FMT_TIFF;
            break;

        case PZ_FMT_RAW:
        case PZ_FMT_TIFF:
            rc = load_raw(path, maxw, maxh, flags, img, m);
            break;

        default:
            rc = -10;
    }

    m->format = fmt;
    return rc;
}

int pz_probe(const char* path, pz_meta* m) {
    memset(m, 0, sizeof(*m));
    int fmt = pz_format_of(path);
    m->format = fmt;

    if (fmt == PZ_FMT_JPEG) {
        size_t len;
        unsigned char* b = read_file(path, 256 * 1024, &len);

        if (!b) {
            return -2;
        }

        tiff_scan sc;
        memset(&sc, 0, sizeof(sc));
        int rc = jpeg_scan(b, len, m, &sc);
        free(b);

        if (!m->orientation) {
            m->orientation = 1;
        }

        if (m->orientation >= 5) {
            int t = m->width;
            m->width = m->height;
            m->height = t;
        }

        return rc;
    }

    if (fmt == PZ_FMT_RAW || fmt == PZ_FMT_TIFF) {
        int fd = open(path, O_RDONLY);

        if (fd < 0) {
            return -2;
        }

        tiff_scan sc;
        memset(&sc, 0, sizeof(sc));
        int rc = raw_scan_header(fd, m, &sc);
        close(fd);
        m->width = sc.crop_w ? sc.crop_w : sc.main_w;
        m->height = sc.crop_h ? sc.crop_h : sc.main_h;

        if (!m->orientation) {
            m->orientation = 1;
        }

        if (m->orientation >= 5) {
            int t = m->width;
            m->width = m->height;
            m->height = t;
        }

        m->is_raw = fmt == PZ_FMT_RAW;
        return rc;
    }

    /* others: decode tiny */
    pz_image img;
    int rc = pz_load(path, 64, 64, PZ_THUMB, &img, m);
    pz_free(&img);
    return rc;
}

/* ------------------------------------------------------------------ */
/* filters                                                             */
/* ------------------------------------------------------------------ */

void pz_lut_identity(pz_lut* l) {
    for (int c = 0; c < 3; c++)
        for (int i = 0; i < 256; i++) {
            l->lut[c][i] = (uint8_t)i;
        }
}

void pz_apply_lut(pz_image* img, const pz_lut* l) {
    size_t n = (size_t)img->w * img->h;
    uint8_t* p = (uint8_t*)img->px;
    #pragma omp parallel for schedule(static) if (PZ_PAR(n))

    for (size_t i = 0; i < n; i++) {
        uint8_t* q = p + 4 * i;
        q[0] = l->lut[0][q[0]];
        q[1] = l->lut[1][q[1]];
        q[2] = l->lut[2][q[2]];
    }
}

static inline int luma8(const uint8_t* q) {
    return (q[0] * 29 + q[1] * 150 + q[2] * 77 + 128) >> 8;
}

void pz_histogram(const pz_image* img, uint32_t hist[4][256]) {
    memset(hist, 0, sizeof(uint32_t) * 4 * 256);
    size_t n = (size_t)img->w * img->h;
    const uint8_t* p = (const uint8_t*)img->px;
    /* subsample large images, the histogram only steers auto adjustments */
    size_t step = n > 2000000 ? 3 : 1;

    for (size_t i = 0; i < n; i += step) {
        const uint8_t* q = p + 4 * i;
        hist[0][q[0]]++;
        hist[1][q[1]]++;
        hist[2][q[2]]++;
        hist[3][luma8(q)]++;
    }
}

/* luminance-preserving tone curve: Y -> f(Y), RGB scaled by f(Y)/Y.
 * This keeps hues stable while lifting shadows, like Picasa's fill light. */
static void apply_luma_curve(pz_image* img, const float* curve /* 256 */) {
    int32_t gain[256]; /* 12-bit fixed point gain per luma level */

    for (int i = 0; i < 256; i++) {
        float y = i / 255.0f, f = curve[i];
        float g = i == 0 ? (f > 0 ? 64.0f : 1.0f) : f / y;

        if (g > 64.0f) {
            g = 64.0f;
        }

        gain[i] = (int32_t)lrintf(g * 4096.0f);
    }

    int add0 = (int)lrintf(curve[0] * 255.0f); /* black point lift for pure black */
    size_t n = (size_t)img->w * img->h;
    uint8_t* p = (uint8_t*)img->px;
    #pragma omp parallel for schedule(static) if (PZ_PAR(n))

    for (size_t i = 0; i < n; i++) {
        uint8_t* q = p + 4 * i;
        int y = luma8(q);
        int32_t g = gain[y];
        int b = (q[0] * g + 2048) >> 12, gg = (q[1] * g + 2048) >> 12, r = (q[2] * g + 2048) >> 12;

        if (y == 0) {
            b = gg = r = add0;
        }

        /* soft desaturate on clipping so highlights roll off instead of hue-shifting */
        int mx = PZ_MAX(r, PZ_MAX(gg, b));

        if (mx > 255) {
            int yy = (int)lrintf(curve[y] * 255.0f);
            float t = (255.0f - yy) / (float)(mx - yy > 0 ? mx - yy : 1);
            b = yy + (int)((b - yy) * t);
            gg = yy + (int)((gg - yy) * t);
            r = yy + (int)((r - yy) * t);
        }

        q[0] = (uint8_t)CLAMP255(b);
        q[1] = (uint8_t)CLAMP255(gg);
        q[2] = (uint8_t)CLAMP255(r);
    }
}

void pz_tone(pz_image* img, float fill, float highlights, float shadows, float brightness, float contrast) {
    if (fill == 0 && highlights == 0 && shadows == 0 && brightness == 0 && contrast == 0) {
        return;
    }

    float curve[256];
    float bp = shadows * 0.30f;          /* Picasa "shadows" darkens: raise black point */
    float wp = 1.0f - highlights * 0.35f; /* "highlights" brightens: lower white point */
    float gam = powf(2.0f, -brightness * 1.2f);
    float ck = tanf((PZ_MAX(-0.95f, PZ_MIN(0.95f, contrast)) + 1.0f) * (float)M_PI / 4.0f);

    for (int i = 0; i < 256; i++) {
        float x = i / 255.0f;

        /* fill light: gamma lift with a small toe so pure black stays black and
         * noise isn't amplified; strong in the shadows, gentler in midtones,
         * close to Picasa's look (fill 1 ~ gamma 1/3) */
        if (fill > 0) {
            const float e = 0.02f;
            float g = 1.0f / (1.0f + 2.0f * fill);
            float e0 = powf(e, g), e1 = powf(1.0f + e, g);
            x = (powf(x + e, g) - e0) / (e1 - e0);
        }

        /* levels */
        x = (x - bp) / (wp - bp);

        if (x < 0) {
            x = 0;
        }

        if (x > 1) {
            x = 1;
        }

        if (brightness != 0) {
            x = powf(x, gam);
        }

        if (contrast != 0) {
            x = 0.5f + (x - 0.5f) * ck;

            if (x < 0) {
                x = 0;
            }

            if (x > 1) {
                x = 1;
            }
        }

        curve[i] = x;
    }

    apply_luma_curve(img, curve);
}

void pz_color(pz_image* img, float temperature, uint32_t neutral) {
    float gb = 1, gg = 1, gr = 1;

    if (neutral & 0x00FFFFFFu) {
        float nr = (float)((neutral >> 16) & 255), ng = (float)((neutral >> 8) & 255), nb = (float)(neutral & 255);
        float avg = (nr + ng + nb) / 3.0f;

        if (nr > 0 && ng > 0 && nb > 0) {
            gr = avg / nr;
            gg = avg / ng;
            gb = avg / nb;
        }
    }

    if (temperature != 0) {
        gr *= 1.0f + 0.25f * temperature;
        gg *= 1.0f + 0.04f * temperature;
        gb *= 1.0f - 0.25f * temperature;
    }

    if (gb == 1 && gg == 1 && gr == 1) {
        return;
    }

    pz_lut l;

    for (int i = 0; i < 256; i++) {
        l.lut[0][i] = (uint8_t)CLAMP255((int)lrintf(i * gb));
        l.lut[1][i] = (uint8_t)CLAMP255((int)lrintf(i * gg));
        l.lut[2][i] = (uint8_t)CLAMP255((int)lrintf(i * gr));
    }

    pz_apply_lut(img, &l);
}

static void percentiles(const uint32_t* h, double lo, double hi, int* plo, int* phi) {
    uint64_t tot = 0;

    for (int i = 0; i < 256; i++) {
        tot += h[i];
    }

    uint64_t a = 0;
    int L = 0, H = 255;

    for (int i = 0; i < 256; i++) {
        a += h[i];

        if (a > tot * lo) {
            L = i;
            break;
        }
    }

    a = 0;

    for (int i = 255; i >= 0; i--) {
        a += h[i];

        if (a > tot * (1.0 - hi)) {
            H = i;
            break;
        }
    }

    *plo = L;
    *phi = H;
}

void pz_autolight(pz_image* img) {
    uint32_t h[4][256];
    pz_histogram(img, h);
    int lo, hi;
    percentiles(h[3], 0.005, 0.995, &lo, &hi);

    if (hi - lo < 16) {
        return;
    }

    /* don't stretch more than needed and keep a little headroom */
    float curve[256];

    for (int i = 0; i < 256; i++) {
        float x = (i - lo) / (float)(hi - lo);
        curve[i] = x < 0 ? 0 : (x > 1 ? 1 : x);
    }

    apply_luma_curve(img, curve);
}

void pz_autocolor(pz_image* img) {
    uint32_t h[4][256];
    pz_histogram(img, h);
    int lo[3], hi[3];

    for (int c = 0; c < 3; c++) {
        percentiles(h[c], 0.003, 0.997, &lo[c], &hi[c]);
    }

    /* neutralise the cast by aligning channel ranges toward the mean range,
     * at partial strength so colourful scenes (sunsets) survive */
    float mlo = (lo[0] + lo[1] + lo[2]) / 3.0f, mhi = (hi[0] + hi[1] + hi[2]) / 3.0f;
    pz_lut l;

    for (int c = 0; c < 3; c++) {
        float tlo = lo[c] + (mlo - lo[c]) * 0.7f, thi = hi[c] + (mhi - hi[c]) * 0.7f;
        float s = (thi - tlo) / (float)PZ_MAX(hi[c] - lo[c], 1);

        for (int i = 0; i < 256; i++) {
            l.lut[c][i] = (uint8_t)CLAMP255((int)lrintf(tlo + (i - lo[c]) * s));
        }
    }

    pz_apply_lut(img, &l);
}

void pz_saturation(pz_image* img, float f) {
    if (f == 1.0f) {
        return;
    }

    int32_t k = (int32_t)lrintf(f * 256.0f);
    size_t n = (size_t)img->w * img->h;
    uint8_t* p = (uint8_t*)img->px;
    #pragma omp parallel for schedule(static) if (PZ_PAR(n))

    for (size_t i = 0; i < n; i++) {
        uint8_t* q = p + 4 * i;
        int y = luma8(q);
        q[0] = (uint8_t)CLAMP255(y + (((q[0] - y) * k) >> 8));
        q[1] = (uint8_t)CLAMP255(y + (((q[1] - y) * k) >> 8));
        q[2] = (uint8_t)CLAMP255(y + (((q[2] - y) * k) >> 8));
    }
}

void pz_boost(pz_image* img, float a) {
    if (a <= 0) {
        return;
    }

    pz_tone(img, 0, 0, 0, 0, 0.25f * a);
    pz_saturation(img, 1.0f + 0.6f * a);
}

void pz_bw(pz_image* img) {
    pz_saturation(img, 0.0f);
}

void pz_sepia(pz_image* img) {
    size_t n = (size_t)img->w * img->h;
    uint8_t* p = (uint8_t*)img->px;
    #pragma omp parallel for schedule(static) if (PZ_PAR(n))

    for (size_t i = 0; i < n; i++) {
        uint8_t* q = p + 4 * i;
        int y = luma8(q);
        q[2] = (uint8_t)CLAMP255(y * 255 / 235 + 8);
        q[1] = (uint8_t)CLAMP255(y * 220 / 255 + 6);
        q[0] = (uint8_t)CLAMP255(y * 170 / 255);
    }
}

void pz_warm(pz_image* img) {
    pz_color(img, 0.35f, 0);
}

/* separable box blur, radius r, used for unsharp masking and soft focus.
 * Both passes walk memory row-wise (the vertical pass keeps one running sum
 * per column) so they stay cache friendly on 20+ MP images. */
static void box_blur(const pz_image* src, pz_image* dst, int r) {
    int w = src->w, h = src->h;
    uint32_t* tmp = malloc((size_t)w * h * 4);

    if (!tmp) {
        return;
    }

    const int div = 2 * r + 1;
    const uint32_t mul = (uint32_t)((1u << 24) / div + 1);
    #pragma omp parallel for schedule(static) if (PZ_PAR((size_t)w * h))

    for (int y = 0; y < h; y++) {
        const uint8_t* s = (const uint8_t*)(src->px + (size_t)y * w);
        uint8_t* d = (uint8_t*)(tmp + (size_t)y * w);
        uint32_t a0 = 0, a1 = 0, a2 = 0;

        for (int k = -r; k <= r; k++) {
            int xx = k < 0 ? 0 : (k >= w ? w - 1 : k);
            a0 += s[4 * xx];
            a1 += s[4 * xx + 1];
            a2 += s[4 * xx + 2];
        }

        for (int x = 0; x < w; x++) {
            d[4 * x] = (uint8_t)((a0 * mul) >> 24);
            d[4 * x + 1] = (uint8_t)((a1 * mul) >> 24);
            d[4 * x + 2] = (uint8_t)((a2 * mul) >> 24);
            d[4 * x + 3] = 255;
            int xo = x - r < 0 ? 0 : x - r, xi = x + r + 1 >= w ? w - 1 : x + r + 1;
            a0 += s[4 * xi] - s[4 * xo];
            a1 += s[4 * xi + 1] - s[4 * xo + 1];
            a2 += s[4 * xi + 2] - s[4 * xo + 2];
        }
    }

    /* vertical: split into column bands, each thread keeps running sums */
    int nb = omp_get_max_threads() * 2;
    int band = (w + nb - 1) / nb;
    #pragma omp parallel for schedule(dynamic) if (PZ_PAR((size_t)w * h))

    for (int b = 0; b < nb; b++) {
        int x0 = b * band, x1 = PZ_MIN(w, x0 + band);

        if (x0 >= x1) {
            continue;
        }

        int bw = x1 - x0;
        uint32_t* acc = calloc((size_t)bw * 3, sizeof(uint32_t));

        if (!acc) {
            continue;
        }

        for (int k = -r; k <= r; k++) {
            int yy = k < 0 ? 0 : (k >= h ? h - 1 : k);
            const uint8_t* s = (const uint8_t*)(tmp + (size_t)yy * w + x0);

            for (int x = 0; x < bw; x++) {
                acc[3 * x] += s[4 * x];
                acc[3 * x + 1] += s[4 * x + 1];
                acc[3 * x + 2] += s[4 * x + 2];
            }
        }

        for (int y = 0; y < h; y++) {
            uint8_t* d = (uint8_t*)(dst->px + (size_t)y * w + x0);
            int yo = y - r < 0 ? 0 : y - r, yi = y + r + 1 >= h ? h - 1 : y + r + 1;
            const uint8_t* so = (const uint8_t*)(tmp + (size_t)yo * w + x0);
            const uint8_t* si = (const uint8_t*)(tmp + (size_t)yi * w + x0);

            for (int x = 0; x < bw; x++) {
                d[4 * x] = (uint8_t)((acc[3 * x] * mul) >> 24);
                d[4 * x + 1] = (uint8_t)((acc[3 * x + 1] * mul) >> 24);
                d[4 * x + 2] = (uint8_t)((acc[3 * x + 2] * mul) >> 24);
                d[4 * x + 3] = 255;
                acc[3 * x] += si[4 * x] - so[4 * x];
                acc[3 * x + 1] += si[4 * x + 1] - so[4 * x + 1];
                acc[3 * x + 2] += si[4 * x + 2] - so[4 * x + 2];
            }
        }

        free(acc);
    }

    free(tmp);
}

void pz_sharpen(pz_image* img, float amount, float radius) {
    if (amount <= 0) {
        return;
    }

    int r = (int)lrintf(radius);

    if (r < 1) {
        r = 1;
    }

    pz_image bl;

    if (pz_alloc(&bl, img->w, img->h)) {
        return;
    }

    box_blur(img, &bl, r);
    box_blur(&bl, &bl, r); /* two box passes ~ gaussian */
    int k = (int)lrintf(amount * 256.0f);
    size_t n = (size_t)img->w * img->h;
    uint8_t* p = (uint8_t*)img->px, *b = (uint8_t*)bl.px;
    #pragma omp parallel for schedule(static) if (PZ_PAR(n))

    for (size_t i = 0; i < n; i++) {
        for (int c = 0; c < 3; c++) {
            int v = p[4 * i + c], d = v - b[4 * i + c];
            p[4 * i + c] = (uint8_t)CLAMP255(v + ((d * k) >> 8));
        }
    }

    pz_free(&bl);
}

void pz_softfocus(pz_image* img, float amount) {
    if (amount <= 0) {
        return;
    }

    pz_image bl;

    if (pz_alloc(&bl, img->w, img->h)) {
        return;
    }

    int r = PZ_MAX(2, PZ_MAX(img->w, img->h) / 150);
    box_blur(img, &bl, r);
    box_blur(&bl, &bl, r);
    float cx = img->w / 2.0f, cy = img->h / 2.0f, R = 0.35f * PZ_MIN(img->w, img->h);
    int k = (int)lrintf(amount * 256.0f);
    #pragma omp parallel for schedule(static) if (PZ_PAR((size_t)img->w * img->h))

    for (int y = 0; y < img->h; y++) {
        uint8_t* p = (uint8_t*)(img->px + (size_t)y * img->w), *b = (uint8_t*)(bl.px + (size_t)y * img->w);

        for (int x = 0; x < img->w; x++) {
            float d = hypotf(x - cx, y - cy) / R - 1.0f;
            int t = d <= 0 ? 0 : (d >= 1 ? k : (int)(d * k));

            for (int c = 0; c < 3; c++) {
                p[4 * x + c] = (uint8_t)(p[4 * x + c] + (((b[4 * x + c] - p[4 * x + c]) * t) >> 8));
            }
        }
    }

    pz_free(&bl);
}

void pz_vignette(pz_image* img, float amount) {
    if (amount <= 0) {
        return;
    }

    float cx = img->w / 2.0f, cy = img->h / 2.0f, R = hypotf(cx, cy);
    #pragma omp parallel for schedule(static) if (PZ_PAR((size_t)img->w * img->h))

    for (int y = 0; y < img->h; y++) {
        uint8_t* p = (uint8_t*)(img->px + (size_t)y * img->w);

        for (int x = 0; x < img->w; x++) {
            float d = hypotf(x - cx, y - cy) / R;
            float g = 1.0f - amount * d * d * d * 1.2f;
            int k = (int)(PZ_MAX(g, 0.0f) * 256.0f);

            for (int c = 0; c < 3; c++) {
                p[4 * x + c] = (uint8_t)((p[4 * x + c] * k) >> 8);
            }
        }
    }
}

int pz_crop(pz_image* img, float l, float t, float r, float b) {
    if (l < 0) {
        l = 0;
    }

    if (t < 0) {
        t = 0;
    }

    if (r > 1) {
        r = 1;
    }

    if (b > 1) {
        b = 1;
    }

    int x0 = (int)lrintf(l * img->w), y0 = (int)lrintf(t * img->h);
    int x1 = (int)lrintf(r * img->w), y1 = (int)lrintf(b * img->h);

    if (x1 - x0 < 1 || y1 - y0 < 1) {
        return -1;
    }

    if (x0 == 0 && y0 == 0 && x1 == img->w && y1 == img->h) {
        return 0;
    }

    pz_image d;

    if (pz_alloc(&d, x1 - x0, y1 - y0)) {
        return -1;
    }

    for (int y = 0; y < d.h; y++) {
        memcpy(d.px + (size_t)y * d.w, img->px + (size_t)(y + y0) * img->w + x0, (size_t)d.w * 4);
    }

    pz_free(img);
    *img = d;
    return 0;
}

int pz_tilt(pz_image* img, float deg) {
    if (fabsf(deg) < 1e-3f) {
        return 0;
    }

    double th = deg * M_PI / 180.0, c = cos(th), s = sin(th);
    int w = img->w, h = img->h;
    /* zoom so the rotated image still covers the whole frame */
    double z = PZ_MAX((w * fabs(c) + h * fabs(s)) / w, (w * fabs(s) + h * fabs(c)) / h);
    pz_image d;

    if (pz_alloc(&d, w, h)) {
        return -1;
    }

    double cx = w / 2.0, cy = h / 2.0;
    #pragma omp parallel for schedule(static) if (PZ_PAR((size_t)w * h))

    for (int y = 0; y < h; y++) {
        uint32_t* o = d.px + (size_t)y * w;

        for (int x = 0; x < w; x++) {
            double dx = (x + 0.5 - cx) / z, dy = (y + 0.5 - cy) / z;
            double sx = c * dx + s * dy + cx - 0.5, sy = -s * dx + c * dy + cy - 0.5;
            int ix = (int)floor(sx), iy = (int)floor(sy);
            float fx = (float)(sx - ix), fy = (float)(sy - iy);

            if (ix < 0) {
                ix = 0;
                fx = 0;
            }

            if (iy < 0) {
                iy = 0;
                fy = 0;
            }

            if (ix >= w - 1) {
                ix = w - 2;
                fx = 1;
            }

            if (iy >= h - 1) {
                iy = h - 2;
                fy = 1;
            }

            if (ix < 0) {
                ix = 0;
            }

            if (iy < 0) {
                iy = 0;
            }

            const uint8_t* p00 = (const uint8_t*)(img->px + (size_t)iy * w + ix);
            const uint8_t* p10 = p00 + 4, *p01 = p00 + (size_t)w * 4, *p11 = p01 + 4;
            uint8_t* q = (uint8_t*)(o + x);

            for (int ch = 0; ch < 4; ch++) {
                float a = p00[ch] + (p10[ch] - p00[ch]) * fx;
                float bb = p01[ch] + (p11[ch] - p01[ch]) * fx;
                q[ch] = (uint8_t)(a + (bb - a) * fy + 0.5f);
            }
        }
    }

    pz_free(img);
    *img = d;
    return 0;
}

void pz_dot_i8(const int8_t* m, const float* scale, int n, int d, const float* q, float* out) {
    int i;
    #pragma omp parallel for schedule(static) if (n > 20000)

    for (i = 0; i < n; i++) {
        const int8_t* r = m + (size_t)i * d;
        float acc = 0.f;
        int k;

        for (k = 0; k < d; k++) {
            acc += r[k] * q[k];
        }

        out[i] = acc * scale[i];
    }
}

int pz_save_png_gray(const char* path, int w, int h, const unsigned char* px) {
    FILE* f = fopen(path, "wb");
    png_structp png;
    png_infop info;
    int y;

    if (!f) {
        return -1;
    }

    png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    info = png ? png_create_info_struct(png) : NULL;

    if (!png || !info || setjmp(png_jmpbuf(png))) {
        if (png) {
            png_destroy_write_struct(&png, info ? &info : NULL);
        }

        fclose(f);
        return -1;
    }

    png_init_io(png, f);
    png_set_IHDR(png, info, w, h, 8, PNG_COLOR_TYPE_GRAY, PNG_INTERLACE_NONE,
                 PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);

    for (y = 0; y < h; y++) {
        png_write_row(png, (png_const_bytep)(px + (size_t)y * w));
    }

    png_write_end(png, NULL);
    png_destroy_write_struct(&png, &info);
    fclose(f);
    return 0;
}
