/*
 * pzai_cli - run a Pizzicato AI model from the command line, for testing
 * and timing (built with make AI=1):
 *
 *   pzai_cli [-d cpu|opencl|vulkan] [-t tile] [-o overlap] [-q quality]
 *            model.mnn in.(jpg|dng|...) out.jpg
 *   pzai_cli [-d ...] [-t tile] --raw model.mnn in.f32 out.f32
 *   pzai_cli [-d ...] --clip-image vision.mnn photo.jpg out.f32
 *   pzai_cli [-d ...] --clip-text text.mnn vocab.json merges.txt "words" out.f32
 *   pzai_cli [-d ...] --faces yunet.mnn sface.mnn photo out.txt   (boxes + embeddings)
 *
 * --raw runs one forward pass on a float NCHW RGB tile, for parity tests
 * against onnxruntime (tests/ai_parity.py).
 */
#include "pzai.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static int progress(void* user, int done, int total) {
    (void)user;
    fprintf(stderr, "\r  tile %d / %d", done, total);

    if (done == total) {
        fputc('\n', stderr);
    }

    return 0;
}

int main(int argc, char** argv) {
    int device = PZ_AI_OPENCL, tile = 0, overlap = 32, quality = 95, raw = 0, clip = 0, i;
    const char* a[5];
    int na = 0;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-d") && i + 1 < argc) {
            i++;
            device = !strcmp(argv[i], "cpu") ? PZ_AI_CPU : !strcmp(argv[i], "vulkan") ? PZ_AI_VULKAN : PZ_AI_OPENCL;
        } else if (!strcmp(argv[i], "-t") && i + 1 < argc) {
            tile = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            overlap = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "-q") && i + 1 < argc) {
            quality = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--raw")) {
            raw = 1;
        } else if (!strcmp(argv[i], "--clip-image")) {
            clip = 1;
        } else if (!strcmp(argv[i], "--clip-text")) {
            clip = 2;
        } else if (!strcmp(argv[i], "--faces")) {
            clip = 3;
        } else if (na < 5) {
            a[na++] = argv[i];
        }
    }

    if (na < 3) {
        fprintf(stderr, "usage: pzai_cli [-d cpu|opencl|vulkan] [-t tile] [-o overlap] [--raw] model.mnn in out\n");
        return 2;
    }

    if (!pz_ai_available()) {
        fprintf(stderr, "%s\n", pz_ai_error());
        return 1;
    }

    double t0 = now();
    pz_ai* h;

    if (clip == 3) {
        pz_ai* rec;
        pz_image img = {0, 0, NULL};
        pz_meta meta;
        pz_face fc[64];
        float emb[128];
        int n, k, j;

        if (na < 4 || pz_ai_open(a[0], device, -1, 0, &h) != 0 || pz_ai_open(a[1], device, -1, 0, &rec) != 0) {
            fprintf(stderr, "open: %s\n", pz_ai_error());
            return 1;
        }

        if (pz_load(a[2], 1600, 1600, 0, &img, &meta) != 0) {
            fprintf(stderr, "cannot load %s\n", a[2]);
            return 1;
        }

        for (k = 0; k < 3; k++) {
            t0 = now();
            n = pz_ai_faces(h, &img, tile > 0 ? tile : 960, 0.7f, fc, 64);
            fprintf(stderr, "  detect %d: %d faces, %.1f ms (%s)\n", k, n, (now() - t0) * 1e3, pz_ai_backend(h));
        }

        FILE* f = fopen(a[3], "w");
        fprintf(f, "%d %d\n", img.w, img.h);

        for (k = 0; k < n; k++) {
            t0 = now();

            if (pz_ai_face_embed(rec, &img, &fc[k], emb) != 0) {
                fprintf(stderr, "embed: %s\n", pz_ai_error());
                return 1;
            }

            fprintf(f, "%.1f %.1f %.1f %.1f %.3f", fc[k].x, fc[k].y, fc[k].w, fc[k].h, fc[k].score);

            for (j = 0; j < 10; j++) {
                fprintf(f, " %.1f", fc[k].lm[j]);
            }

            for (j = 0; j < 128; j++) {
                fprintf(f, " %.5f", emb[j]);
            }

            fprintf(f, "\n");

            if (k == 0) {
                fprintf(stderr, "  embed: %.1f ms\n", (now() - t0) * 1e3);
            }
        }

        fclose(f);
        pz_free(&img);
        pz_ai_close(rec);
        pz_ai_close(h);
        return 0;
    }

    if (clip) {
        float emb[1024];
        int k, rc = -1;

        if (pz_ai_open(a[0], device, -1, 0, &h) != 0) {
            fprintf(stderr, "open: %s\n", pz_ai_error());
            return 1;
        }

        fprintf(stderr, "model %s: backend %s, open %.0f ms\n", a[0], pz_ai_backend(h), (now() - t0) * 1e3);

        for (k = 0; k < 3; k++) {
            t0 = now();

            if (clip == 1) {
                pz_image img = {0, 0, NULL};
                pz_meta meta;

                if (pz_load(a[1], 0, 0, 0, &img, &meta) != 0) {
                    fprintf(stderr, "cannot load %s\n", a[1]);
                    return 1;
                }

                rc = pz_ai_clip_image(h, &img, emb);
                pz_free(&img);
            } else {
                if (na < 5 || (k == 0 && pz_ai_clip_load_bpe(h, a[1], a[2]) != 0)) {
                    fprintf(stderr, "bpe: %s\n", pz_ai_error());
                    return 1;
                }

                if (k == 0) {
                    int ids[77], n = pz_ai_clip_tokenize(h, a[3], ids, 77), j;
                    printf("tokens:");

                    for (j = 0; j < n; j++) {
                        printf(" %d", ids[j]);
                    }

                    printf("\n");
                }

                rc = pz_ai_clip_text(h, a[3], emb);
            }

            if (rc != 0) {
                fprintf(stderr, "run: %s\n", pz_ai_error());
                return 1;
            }

            fprintf(stderr, "  embed %d: %.1f ms\n", k, (now() - t0) * 1e3);
        }

        FILE* f = fopen(a[clip == 1 ? 2 : 4], "wb");
        fwrite(emb, sizeof(float), pz_ai_dim(h), f);
        fclose(f);
        pz_ai_close(h);
        return 0;
    }

    if (pz_ai_open(a[0], device, tile, 0, &h) != 0) {
        fprintf(stderr, "open: %s\n", pz_ai_error());
        return 1;
    }

    fprintf(stderr, "model %s: backend %s, tile %d, scale %d, open %.0f ms\n", a[0],
            pz_ai_backend(h), pz_ai_tile(h), pz_ai_scale(h), (now() - t0) * 1e3);

    if (raw) {
        size_t n = 3ul * pz_ai_tile(h) * pz_ai_tile(h), m = n * pz_ai_scale(h) * pz_ai_scale(h);
        float* in = malloc(n * sizeof(float)), *out = malloc(m * sizeof(float));
        FILE* f = fopen(a[1], "rb");

        if (!f || fread(in, sizeof(float), n, f) != n) {
            fprintf(stderr, "cannot read %zu floats from %s\n", n, a[1]);
            return 1;
        }

        fclose(f);
        int k;

        for (k = 0; k < 3; k++) { /* the first runs include GPU tuning */
            t0 = now();

            if (pz_ai_run_raw(h, in, out) != 0) {
                fprintf(stderr, "run: %s\n", pz_ai_error());
                return 1;
            }

            fprintf(stderr, "  forward %d: %.1f ms\n", k, (now() - t0) * 1e3);
        }

        f = fopen(a[2], "wb");
        fwrite(out, sizeof(float), m, f);
        fclose(f);
        pz_ai_close(h);
        return 0;
    }

    pz_image img = {0, 0, NULL}, out = {0, 0, NULL};
    pz_meta meta;
    t0 = now();

    if (pz_load(a[1], 0, 0, PZ_RAW_FULL, &img, &meta) != 0) {
        fprintf(stderr, "cannot load %s\n", a[1]);
        return 1;
    }

    fprintf(stderr, "image %dx%d, load %.0f ms\n", img.w, img.h, (now() - t0) * 1e3);
    t0 = now();
    int rc = pz_ai_run_tiled(h, &img, &out, overlap, 0, 0, 0, 0, progress, NULL);

    if (rc != 0) {
        fprintf(stderr, "run: %s\n", pz_ai_error());
        return 1;
    }

    double dt = now() - t0;
    fprintf(stderr, "run %.0f ms (%.1f ms/MP of input)\n", dt * 1e3, dt * 1e3 / (img.w * (double)img.h / 1e6));
    pz_save_jpeg(a[2], &out, quality);
    pz_free(&img);
    pz_free(&out);
    pz_ai_close(h);
    return 0;
}
