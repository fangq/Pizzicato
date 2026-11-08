/* pzbench: time pzcore loaders on real files.
 *   pzbench thumb|view|raw|full|filters [-o out.jpg] [-j N] files...
 * thumb : 320px thumbnails (embedded previews for raw), parallel with -j
 * view  : fit 2560x1440 (raw: embedded preview if big enough, else half decode)
 * raw   : fit 2560x1440 forcing a half-size raw decode
 * full  : full resolution (raw: full AHD demosaic)
 */
#include "pzcore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <omp.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: pzbench thumb|view|raw|full|filters [-o out.jpg] [-j N] files...\n");
        return 1;
    }

    const char* mode = argv[1], *out = NULL;
    int jobs = 1, i = 2;

    for (; i < argc && argv[i][0] == '-'; i++) {
        if (!strcmp(argv[i], "-o")) {
            out = argv[++i];
        } else if (!strcmp(argv[i], "-j")) {
            jobs = atoi(argv[++i]);
        }
    }

    int nfiles = argc - i;
    char** files = argv + i;
    int maxw = 2560, maxh = 1440, flags = 0;

    if (!strcmp(mode, "thumb")) {
        maxw = maxh = 320;
        flags = PZ_THUMB;
    } else if (!strcmp(mode, "raw")) {
        flags = PZ_NO_PREVIEW;
    } else if (!strcmp(mode, "full")) {
        maxw = maxh = 0;
        flags = PZ_NO_PREVIEW | PZ_RAW_FULL;
    }

    if (jobs > 1) {
        pz_set_threads(1);    /* parallelism across files instead */
    }

    double t0 = now(), worst = 0;
    long bytes = 0;
    int ok = 0;
    #pragma omp parallel for num_threads(jobs) schedule(dynamic) reduction(+ : ok, bytes) reduction(max : worst)

    for (int k = 0; k < nfiles; k++) {
        pz_image img;
        pz_meta m;
        double a = now();
        int rc = pz_load(files[k], maxw, maxh, flags, &img, &m);
        double dt = now() - a;

        if (rc >= 0) {
            ok++;

            if (!strcmp(mode, "filters")) {
                double b = now();
                pz_tone(&img, 0.4f, 0.1f, 0.1f, 0, 0);
                double b1 = now();
                pz_autolight(&img);
                pz_autocolor(&img);
                double b2 = now();
                pz_saturation(&img, 1.3f);
                pz_sharpen(&img, 0.6f, 1);
                double b3 = now();
                pz_tilt(&img, 2.5f);
                double b4 = now();
                printf("filters %dx%d: tone %.1fms auto %.1fms sat+sharp %.1fms tilt %.1fms\n", img.w, img.h,
                       (b1 - b) * 1e3, (b2 - b1) * 1e3, (b3 - b2) * 1e3, (b4 - b3) * 1e3);
            }

            unsigned char* jb;
            unsigned long jl;

            if (!strcmp(mode, "thumb") && pz_encode_jpeg_mem(&img, 82, &jb, &jl) == 0) {
                bytes += (long)jl;
                pz_free_mem(jb);
            }

            if (nfiles <= 20)
                printf("%-60s %5dx%-5d (%dx%d o=%d raw=%d %s %s) %.1f ms\n", files[k], img.w, img.h, m.width,
                       m.height, m.orientation, m.is_raw, m.make, m.model, dt * 1e3);

            if (out && k == 0) {
                pz_save_jpeg(out, &img, 92);
            }

            pz_free(&img);
        } else {
            printf("FAIL %s rc=%d\n", files[k], rc);
        }

        if (dt > worst) {
            worst = dt;
        }
    }

    double t = now() - t0;
    printf("%s: %d/%d ok, %.1f ms total, %.2f ms/file avg, %.1f files/s, worst %.1f ms", mode, ok, nfiles, t * 1e3,
           t * 1e3 / nfiles, nfiles / t, worst * 1e3);

    if (bytes) {
        printf(", thumb jpeg avg %.1f KB", bytes / 1024.0 / ok);
    }

    printf("\n");
    return 0;
}
