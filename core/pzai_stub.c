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

int pz_ai_dim(const pz_ai* h) {
    (void)h;
    return 0;
}

int pz_ai_clip_image(pz_ai* h, const pz_image* img, float* emb) {
    (void)h;
    (void)img;
    (void)emb;
    return -1;
}

int pz_ai_clip_load_bpe(pz_ai* h, const char* vocab_json, const char* merges_txt) {
    (void)h;
    (void)vocab_json;
    (void)merges_txt;
    return -1;
}

int pz_ai_clip_tokenize(pz_ai* h, const char* text, int* ids, int max) {
    (void)h;
    (void)text;
    (void)ids;
    (void)max;
    return -1;
}

int pz_ai_clip_text(pz_ai* h, const char* text, float* emb) {
    (void)h;
    (void)text;
    (void)emb;
    return -1;
}

int pz_ai_faces(pz_ai* det, const pz_image* img, int size, float thresh, pz_face* faces, int max) {
    (void)det;
    (void)img;
    (void)size;
    (void)thresh;
    (void)faces;
    (void)max;
    return -1;
}

int pz_ai_face_embed(pz_ai* rec, const pz_image* img, const pz_face* f, float* emb) {
    (void)rec;
    (void)img;
    (void)f;
    (void)emb;
    return -1;
}
