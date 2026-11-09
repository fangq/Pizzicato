/*
 * pzai - neural-network image operations for Pizzicato (denoise,
 * super-resolution, subject masks, ...) on MNN, with its OpenCL backend on
 * the GPU and its CPU backend as the fallback.
 *
 * Plain C ABI, like pzcore.h. Built from pzai.cpp with `make AI=1`; without
 * it pzai_stub.c provides the same symbols and pz_ai_available() is 0.
 *
 * Images are pzcore's BGRA pz_image. Models take NCHW RGB float in [0,1].
 * A handle is not thread-safe: use one per thread (Pizzicato runs all AI
 * work on one GPU worker thread).
 */
#ifndef PZAI_H
#define PZAI_H

#include "pzcore.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pz_ai pz_ai;

enum { PZ_AI_CPU = 0, PZ_AI_OPENCL = 1, PZ_AI_VULKAN = 2 };

/* progress callback: done and total tiles; return nonzero to cancel */
typedef int (*pz_ai_progress)(void* user, int done, int total);

/* 1 when built with MNN */
int pz_ai_available(void);
/* the last error of this thread, "" if none */
const char* pz_ai_error(void);
/* where MNN keeps its GPU auto-tuning caches (default ~/.cache/pizzicato/mnn) */
void pz_ai_set_cache_dir(const char* dir);

/* Load a .mnn model for tiles of tile x tile pixels (0 = the model's own
 * fixed input size). device: PZ_AI_*; a GPU that cannot run the model
 * falls back to the CPU. threads: CPU threads (0 = auto). */
int  pz_ai_open(const char* model, int device, int tile, int threads, pz_ai** h);
void pz_ai_close(pz_ai* h);
/* the backend actually in use: "opencl", "vulkan" or "cpu" */
const char* pz_ai_backend(const pz_ai* h);
/* the model's input tile and its output scale (1 for denoise, 4 for x4 SR) */
int  pz_ai_tile(const pz_ai* h);
int  pz_ai_scale(const pz_ai* h);

/* Run the model over in, tile by tile with overlap pixels of feathered
 * overlap, into out (in.w*scale x in.h*scale). When out->px is NULL it is
 * allocated; otherwise it must have that size, and only the tiles covering
 * the region of interest (rx,ry,rw,rh in input pixels; rw <= 0 = all) are
 * computed into it, so a caller can do the visible part first.
 * Returns 0, 1 when cancelled, negative on error. */
int  pz_ai_run_tiled(pz_ai* h, const pz_image* in, pz_image* out, int overlap,
                     int rx, int ry, int rw, int rh,
                     pz_ai_progress cb, void* user);

/* One raw forward pass on a float NCHW RGB tile (3 x tile x tile) into
 * out (3 x tile*scale x tile*scale), for parity tests against onnxruntime. */
int  pz_ai_run_raw(pz_ai* h, const float* in, float* out);

/* ---- embedding models (CLIP) ----
 * pz_ai_open with tile < 0 opens a model without the image-to-image
 * set-up; these calls then size its input themselves. Embeddings are
 * L2-normalised; dim = pz_ai_dim(h) floats. */
int  pz_ai_dim(const pz_ai* h);
/* CLIP image tower: shortest edge to 224, centre crop, CLIP's mean/std */
int  pz_ai_clip_image(pz_ai* h, const pz_image* img, float* emb);
/* CLIP text tower: load the byte-level BPE (vocab.json, merges.txt) once */
int  pz_ai_clip_load_bpe(pz_ai* h, const char* vocab_json, const char* merges_txt);
int  pz_ai_clip_tokenize(pz_ai* h, const char* text, int* ids, int max);
int  pz_ai_clip_text(pz_ai* h, const char* text, float* emb);

/* ---- faces: YuNet detection, SFace recognition (OpenCV zoo models) ---- */
typedef struct {
    float x, y, w, h;   /* box in image pixels */
    float score;
    float lm[10];       /* eyes, nose tip, mouth corners (x, y) */
} pz_face;

/* faces in img, best first, at most max; size: the detector's input edge
 * (a multiple of 32; larger finds smaller faces). Returns the count. */
int  pz_ai_faces(pz_ai* det, const pz_image* img, int size, float thresh, pz_face* faces, int max);
/* a face's 128-d identity embedding (L2-normalised; same person: cos > ~0.36) */
int  pz_ai_face_embed(pz_ai* rec, const pz_image* img, const pz_face* f, float* emb);

#ifdef __cplusplus
}
#endif

#endif
