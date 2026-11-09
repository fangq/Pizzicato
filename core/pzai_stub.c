/*
 * pzai_stub.c - the pzai.h API when Pizzicato is built without MNN
 * (plain `make`): nothing is available, every call reports that.
 */
#include "pzai.h"

#include <stddef.h>

static const char* MSG = "built without AI support (rebuild with make AI=1)";

int pz_ai_available(void) {
    return 0;
}

const char* pz_ai_error(void) {
    return MSG;
}

void pz_ai_set_cache_dir(const char* dir) {
    (void)dir;
}

int pz_ai_open(const char* model, int device, int tile, int threads, pz_ai** h) {
    (void)model;
    (void)device;
    (void)tile;
    (void)threads;
    *h = NULL;
    return -1;
}

void pz_ai_close(pz_ai* h) {
    (void)h;
}

const char* pz_ai_backend(const pz_ai* h) {
    (void)h;
    return "";
}

int pz_ai_tile(const pz_ai* h) {
    (void)h;
    return 0;
}

int pz_ai_scale(const pz_ai* h) {
    (void)h;
    return 1;
}

int pz_ai_run_tiled(pz_ai* h, const pz_image* in, pz_image* out, int overlap,
                    int rx, int ry, int rw, int rh, pz_ai_progress cb, void* user) {
    (void)h;
    (void)in;
    (void)out;
    (void)overlap;
    (void)rx;
    (void)ry;
    (void)rw;
    (void)rh;
    (void)cb;
    (void)user;
    return -1;
}

int pz_ai_run_raw(pz_ai* h, const float* in, float* out) {
    (void)h;
    (void)in;
    (void)out;
    return -1;
}
