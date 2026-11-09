/*
 * pzai.cpp - MNN-backed neural image operations (see pzai.h).
 *
 * The MNN set-up follows siamize's engine_mnn.cpp: OpenCL with FAST
 * auto-tuning (its sweep found FAST as fast as WIDE where WIDE wins and much
 * faster to tune), fp16 on the GPU, a per-model tuning cache file, and a
 * RESIZE_STATUS check because resizeSession reports out-of-memory only there.
 */
#include "pzai.h"

/* makes MNNDeviceContext visible, for choosing one of several GPUs */
#define MNN_USER_SET_DEVICE
#include <MNN/Interpreter.hpp>
#include <MNN/MNNSharedContext.h>
#include <MNN/Tensor.hpp>
#include <MNN/expr/ExprCreator.hpp>
#include <MNN/expr/Module.hpp>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <map>
#include <sstream>
#include <unordered_map>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static thread_local std::string g_err;
static std::string g_cache_dir;

static int fail(const std::string& msg) {
    g_err = msg;
    return -1;
}

struct pz_ai {
    std::shared_ptr<MNN::Interpreter> net;
    MNN::Session* sess = nullptr;
    MNN::Tensor* in = nullptr;
    MNN::Tensor* out = nullptr;
    std::unique_ptr<MNN::Tensor> hin, hout;
    int tile = 0, scale = 1;
    std::string backend = "cpu";
    bool cache_dirty = false;
    MNNDeviceContext dev{};
    MNN::BackendConfig bcfg;
    /* embedding models */
    bool generic = false;
    int dim = 0;
    std::vector<int> in_shape;
    std::unordered_map<std::string, int> vocab;
    std::map<std::pair<std::string, std::string>, int> ranks;
    std::string byte2u[256];
    std::unordered_map<std::string, std::vector<int>> bpe_cache;
    /* models with data-dependent shapes (SAM's decoder) run as an Express
       Module instead of a session */
    std::shared_ptr<MNN::Express::Module> mod[8]; /* SAM: by point count */
    std::string dec_base;
};

extern "C" int pz_ai_available(void) {
    return 1;
}

extern "C" const char* pz_ai_error(void) {
    return g_err.c_str();
}

extern "C" void pz_ai_set_cache_dir(const char* dir) {
    g_cache_dir = dir ? dir : "";
}

static void mkdirs(const std::string& p) {
    std::string cur;

    for (size_t i = 0; i < p.size(); i++) {
        cur += p[i];

        if (p[i] == '/' && cur.size() > 1) {
            mkdir(cur.c_str(), 0755);
        }
    }

    mkdir(p.c_str(), 0755);
}

static std::string cache_file(const char* model, const char* backend) {
    std::string dir = g_cache_dir;

    if (dir.empty()) {
        const char* home = getenv("HOME");

        if (!home) {
            return "";
        }

        dir = std::string(home) + "/.cache/pizzicato/mnn";
    }

    mkdirs(dir);
    std::string base = model;
    size_t k = base.find_last_of('/');

    if (k != std::string::npos) {
        base = base.substr(k + 1);
    }

    const char* g = getenv("PZ_AI_GPU");
    const char* bf = getenv("PZ_AI_BUFFER");
    char host[64] = "";
    gethostname(host, sizeof(host) - 1);
    /* tuning differs per GPU and memory layout: one cache each */
    return dir + "/" + base + "-" + backend + "-" + host + (g ? std::string("-g") + g : "") +
           (bf ? std::string("-b") + bf : "") + ".cache";
}

/* build the session on one backend; false (and the interpreter untouched
 * for a retry) when this backend cannot run the model */
static bool make_session(pz_ai* h, const char* model, int device, int tile, int threads) {
    MNN::ScheduleConfig cfg;
    bool gpu = device == PZ_AI_OPENCL || device == PZ_AI_VULKAN;
    cfg.type = device == PZ_AI_OPENCL ? MNN_FORWARD_OPENCL :
               device == PZ_AI_VULKAN ? MNN_FORWARD_VULKAN : MNN_FORWARD_CPU;
    cfg.backupType = MNN_FORWARD_CPU;

    if (gpu) {
        cfg.mode = device == PZ_AI_VULKAN ? MNN_GPU_TUNING_WIDE : MNN_GPU_TUNING_FAST;
        /* PZ_AI_TUNE=none|fast|normal|wide|heavy, PZ_AI_BUFFER=1: for experiments */
        const char* tn = getenv("PZ_AI_TUNE");

        if (tn && *tn) {
            cfg.mode = !strcmp(tn, "none") ? MNN_GPU_TUNING_NONE : !strcmp(tn, "normal") ? MNN_GPU_TUNING_NORMAL :
                       !strcmp(tn, "wide") ? MNN_GPU_TUNING_WIDE : !strcmp(tn, "heavy") ? MNN_GPU_TUNING_HEAVY :
                       MNN_GPU_TUNING_FAST;
        }

        const char* bf = getenv("PZ_AI_BUFFER");

        /* buffers, not images: 4x faster for SCUNet on NVIDIA's OpenCL */
        if (bf && *bf == '0') {
            cfg.mode |= MNN_GPU_MEMORY_IMAGE;
        } else if (device == PZ_AI_OPENCL) {
            cfg.mode |= MNN_GPU_MEMORY_BUFFER;
        }
    } else {
        cfg.numThread = threads > 0 ? threads :
                        std::max(1, std::min(8, (int)sysconf(_SC_NPROCESSORS_ONLN)));
    }

    h->bcfg.precision = gpu ? MNN::BackendConfig::Precision_Low :
                        MNN::BackendConfig::Precision_Normal;
    h->bcfg.memory = MNN::BackendConfig::Memory_Normal;
    h->bcfg.power = MNN::BackendConfig::Power_High;
    /* PZ_AI_GPU=n picks the n-th OpenCL GPU (a machine may have several) */
    const char* g = getenv("PZ_AI_GPU");

    if (device == PZ_AI_OPENCL && g && *g) {
        /* "d" or "platform:device" (a CPU OpenCL such as PoCL may be platform 0) */
        const char* c = strchr(g, ':');
        h->dev.platformId = c ? (uint32_t)atoi(g) : 0;
        h->dev.deviceId = (uint32_t)atoi(c ? c + 1 : g);
        h->bcfg.sharedContext = &h->dev;
    }

    cfg.backendConfig = &h->bcfg;
    const char* bname = device == PZ_AI_OPENCL ? "opencl" : device == PZ_AI_VULKAN ? "vulkan" : "cpu";

    if (gpu) {
        std::string cf = cache_file(model, bname);

        if (!cf.empty()) {
            h->net->setCacheFile(cf.c_str());
        }
    }

    h->sess = h->net->createSession(cfg);

    if (!h->sess) {
        return false;
    }

    h->in = h->net->getSessionInput(h->sess, nullptr);

    if (!h->in && tile < 0) { /* several inputs: the calls name theirs */
        const auto& all = h->net->getSessionInputAll(h->sess);

        if (!all.empty()) {
            h->in = all.begin()->second;
        }
    }

    if (!h->in) {
        g_err = "the model has no input";
        return false;
    }

    if (tile < 0) { /* an embedding model: the caller sizes the input */
        h->generic = true;
        h->out = h->net->getSessionOutput(h->sess, nullptr);

        if (!h->out) {
            const auto& all = h->net->getSessionOutputAll(h->sess);

            if (!all.empty()) {
                h->out = all.begin()->second;
            }
        }
        int fwd = cfg.type;
        h->net->getSessionInfo(h->sess, MNN::Interpreter::BACKENDS, &fwd);
        h->backend = fwd == MNN_FORWARD_OPENCL ? "opencl" : fwd == MNN_FORWARD_VULKAN ? "vulkan" : "cpu";
        h->cache_dirty = gpu;
        return h->out != nullptr;
    }

    std::vector<int> shp = h->in->shape();
    int fixed = (shp.size() == 4 && shp[2] > 0 && shp[2] == shp[3]) ? shp[2] : 0;

    if (tile <= 0) {
        tile = fixed > 0 ? fixed : 256;
    }

    if (fixed > 0 && tile != fixed) {
        tile = fixed; /* fixed-shape export: its own size only */
    }

    h->net->resizeTensor(h->in, {1, 3, tile, tile});
    h->net->resizeSession(h->sess);
    int status = 0;
    h->net->getSessionInfo(h->sess, MNN::Interpreter::RESIZE_STATUS, &status);

    if (status != 0) {
        g_err = "out of memory for a " + std::to_string(tile) + " px tile";
        h->net->releaseSession(h->sess);
        h->sess = nullptr;
        return false;
    }

    h->out = h->net->getSessionOutput(h->sess, nullptr);
    std::vector<int> os = h->out ? h->out->shape() : std::vector<int>();

    if (os.size() != 4 || os[1] != 3 || os[2] % tile != 0) {
        g_err = "the model's output is not a 3-channel image";
        return false;
    }

    h->tile = tile;
    h->scale = os[2] / tile;
    h->hin.reset(MNN::Tensor::create<float>({1, 3, tile, tile}, nullptr, MNN::Tensor::CAFFE));
    h->hout.reset(MNN::Tensor::create<float>(os, nullptr, MNN::Tensor::CAFFE));
    /* which backend really runs it: MNN may put the whole graph on the CPU */
    int fwd = cfg.type;
    h->net->getSessionInfo(h->sess, MNN::Interpreter::BACKENDS, &fwd);
    h->backend = fwd == MNN_FORWARD_OPENCL ? "opencl" : fwd == MNN_FORWARD_VULKAN ? "vulkan" : "cpu";
    h->cache_dirty = gpu;
    return true;
}

extern "C" int pz_ai_open(const char* model, int device, int tile, int threads, pz_ai** out) {
    *out = nullptr;
    g_err.clear();
    std::unique_ptr<pz_ai> h(new pz_ai());

    if (tile < 0 && strstr(model, "_dec")) {
        /* SAM's decoder, converted once per point count (MNN mis-converts
           its dynamic shapes): <base>2.mnn .. <base>6.mnn, loaded as needed */
        std::string b = model;

        if (b.size() > 4 && b.compare(b.size() - 4, 4, ".mnn") == 0) {
            b.resize(b.size() - 4);
        }

        h->dec_base = b;

        if (access((b + "2.mnn").c_str(), R_OK) != 0) {
            return fail("cannot find " + b + "2.mnn");
        }

        h->generic = true;
        h->backend = "cpu";
        *out = h.release();
        return 0;
    }

    h->net.reset(MNN::Interpreter::createFromFile(model), MNN::Interpreter::destroy);

    if (!h->net) {
        return fail(std::string("cannot load model ") + model);
    }

    if (!make_session(h.get(), model, device, tile, threads)) {
        if (device == PZ_AI_CPU) {
            return fail(g_err.empty() ? "cannot create an MNN session" : g_err);
        }

        /* the GPU cannot run it: fall back to the CPU */
        h->net.reset(MNN::Interpreter::createFromFile(model), MNN::Interpreter::destroy);

        if (!h->net || !make_session(h.get(), model, PZ_AI_CPU, tile, threads)) {
            return fail(g_err.empty() ? "cannot create an MNN session" : g_err);
        }
    }

    *out = h.release();
    return 0;
}

extern "C" void pz_ai_close(pz_ai* h) {
    if (!h) {
        return;
    }

    if (h->sess && h->cache_dirty) {
        h->net->updateCacheFile(h->sess);
    }

    h->hin.reset();
    h->hout.reset();
    for (auto& m : h->mod) {
        m.reset();
    }

    if (h->sess) {
        h->net->releaseSession(h->sess);
    }

    delete h;
}

extern "C" const char* pz_ai_backend(const pz_ai* h) {
    return h ? h->backend.c_str() : "";
}

extern "C" int pz_ai_tile(const pz_ai* h) {
    return h ? h->tile : 0;
}

extern "C" int pz_ai_scale(const pz_ai* h) {
    return h ? h->scale : 1;
}

static int forward(pz_ai* h) {
    if (!h->in->copyFromHostTensor(h->hin.get())) {
        return fail("cannot upload a tile");
    }

    if (h->net->runSession(h->sess) != MNN::NO_ERROR) {
        return fail("MNN runSession failed");
    }

    if (!h->out->copyToHostTensor(h->hout.get())) {
        return fail("cannot download a tile");
    }

    if (h->cache_dirty) {
        /* save the GPU tuning after the first run, so it survives a crash */
        h->net->updateCacheFile(h->sess);
        h->cache_dirty = false;
    }

    return 0;
}

extern "C" int pz_ai_run_raw(pz_ai* h, const float* in, float* out) {
    size_t n = 3ull * h->tile * h->tile;
    memcpy(h->hin->host<float>(), in, n * sizeof(float));

    if (forward(h) != 0) {
        return -1;
    }

    size_t m = n * h->scale * h->scale;
    memcpy(out, h->hout->host<float>(), m * sizeof(float));
    return 0;
}

/* tile origins along one axis: 0, step, 2 step, ... with the last flush
 * against the far edge; a single tile at 0 when the image is smaller */
static std::vector<int> origins(int len, int tile, int step) {
    std::vector<int> v;

    if (len <= tile) {
        v.push_back(0);
        return v;
    }

    for (int x = 0;; x += step) {
        if (x + tile >= len) {
            v.push_back(len - tile);
            break;
        }

        v.push_back(x);
    }

    return v;
}

static inline int mirror(int i, int n) {
    if (n == 1) {
        return 0;
    }

    while (i < 0 || i >= n) {
        i = i < 0 ? -i - 1 : 2 * n - i - 1;
    }

    return i;
}

/* feathering weight across a tile: a ramp over the overlap on the sides
 * that meet another tile, flat on the sides at the image edge */
static inline float ramp(int d, int len, int ov, bool lo_edge, bool hi_edge) {
    float w = 1.f;

    if (ov > 0) {
        if (!lo_edge && d < ov) {
            w = std::min(w, (d + 0.5f) / ov);
        }

        if (!hi_edge && len - 1 - d < ov) {
            w = std::min(w, (len - d - 0.5f) / ov);
        }
    }

    return w;
}

extern "C" int pz_ai_run_tiled(pz_ai* h, const pz_image* in, pz_image* out, int overlap,
                               int rx, int ry, int rw, int rh,
                               pz_ai_progress cb, void* user) {
    g_err.clear();

    if (!h || !in || !in->px || in->w <= 0 || in->h <= 0) {
        return fail("no image");
    }

    const int T = h->tile, s = h->scale, W = in->w, H = in->h;
    const int OW = W * s, OH = H * s;
    overlap = std::max(0, std::min(overlap, T / 2));
    const int step = T - overlap;

    if (!out->px) {
        if (pz_alloc(out, OW, OH) != 0) {
            return fail("out of memory");
        }

        if (s == 1) {
            memcpy(out->px, in->px, (size_t)W * H * 4);
        }

        rw = 0; /* a fresh output needs every tile */
    } else if (out->w != OW || out->h != OH) {
        return fail("the output has the wrong size");
    }

    if (rw <= 0 || rh <= 0) {
        rx = 0;
        ry = 0;
        rw = W;
        rh = H;
    }

    rx = std::max(0, rx);
    ry = std::max(0, ry);
    rw = std::min(rw, W - rx);
    rh = std::min(rh, H - ry);

    if (rw <= 0 || rh <= 0) {
        return 0;
    }

    std::vector<int> xs0 = origins(W, T, step), ys0 = origins(H, T, step), xs, ys;

    for (int x : xs0) if (x < rx + rw && x + T > rx) {
            xs.push_back(x);
        }

    for (int y : ys0) if (y < ry + rh && y + T > ry) {
            ys.push_back(y);
        }

    const int total = (int)(xs.size() * ys.size());
    /* accumulate one band of tile rows at a time: rows of out above the
     * next tile row are final and get written out, so memory stays at
     * about one tile row even for a 4x upscale of a large photo */
    const int ax0 = xs.front() * s, ax1 = std::min(OW, (xs.back() + T) * s);
    const int AW = ax1 - ax0, AH = T * s;
    std::vector<float> acc((size_t)AW * AH * 3, 0.f), wsum((size_t)AW * AH, 0.f);
    int base = ys.front() * s; /* output row of acc's first row */
    const int ox0 = rx * s, ox1 = (rx + rw) * s, oy0 = ry * s, oy1 = (ry + rh) * s;
    float* tin = h->hin->host<float>();
    const size_t plane = (size_t)T * T, oplane = (size_t)T * s * T * s;
    int done = 0;

    auto flush = [&](int upto) { /* write out rows [base, upto) */
        upto = std::min(upto, OH);

        for (int y = base; y < upto; y++) {
            if (y < oy0 || y >= oy1) {
                continue;
            }

            const float* a = &acc[(size_t)(y - base) * AW * 3];
            const float* ws = &wsum[(size_t)(y - base) * AW];
            uint32_t* o = out->px + (size_t)y * OW;

            for (int x = std::max(ax0, ox0); x < std::min(ax1, ox1); x++) {
                int i = x - ax0;
                float w = ws[i] > 0 ? 1.f / ws[i] : 0.f;
                int r = (int)lrintf(std::min(1.f, std::max(0.f, a[i * 3] * w)) * 255.f);
                int g = (int)lrintf(std::min(1.f, std::max(0.f, a[i * 3 + 1] * w)) * 255.f);
                int b = (int)lrintf(std::min(1.f, std::max(0.f, a[i * 3 + 2] * w)) * 255.f);
                o[x] = (uint32_t)b | ((uint32_t)g << 8) | ((uint32_t)r << 16) | (o[x] & 0xFF000000u);

                if (s > 1) {
                    o[x] |= 0xFF000000u;
                }
            }
        }

        int keep = base + AH - upto;

        if (upto > base && keep > 0) {
            memmove(&acc[0], &acc[(size_t)(upto - base) * AW * 3], (size_t)keep * AW * 3 * sizeof(float));
            memmove(&wsum[0], &wsum[(size_t)(upto - base) * AW], (size_t)keep * AW * sizeof(float));
            std::fill(acc.begin() + (size_t)keep * AW * 3, acc.end(), 0.f);
            std::fill(wsum.begin() + (size_t)keep * AW, wsum.end(), 0.f);
        } else if (upto > base) {
            std::fill(acc.begin(), acc.end(), 0.f);
            std::fill(wsum.begin(), wsum.end(), 0.f);
        }

        base = std::max(base, upto);
    };

    for (size_t j = 0; j < ys.size(); j++) {
        const int ty = ys[j];
        flush(ty * s);

        for (size_t i = 0; i < xs.size(); i++) {
            const int tx = xs[i];

            /* BGRA -> planar RGB in [0,1], mirrored past the image edge */
            for (int y = 0; y < T; y++) {
                const uint32_t* row = in->px + (size_t)mirror(ty + y, H) * W;

                for (int x = 0; x < T; x++) {
                    uint32_t p = row[mirror(tx + x, W)];
                    size_t k = (size_t)y * T + x;
                    tin[k] = ((p >> 16) & 255) * (1.f / 255.f);
                    tin[plane + k] = ((p >> 8) & 255) * (1.f / 255.f);
                    tin[2 * plane + k] = (p & 255) * (1.f / 255.f);
                }
            }

            if (forward(h) != 0) {
                return -1;
            }

            const float* to = h->hout->host<float>();
            const int TS = T * s, ovs = overlap * s;
            const bool l = tx == 0, r = tx + T >= W, t = ty == 0, b = ty + T >= H;

            for (int y = 0; y < TS; y++) {
                const int oy = ty * s + y;

                if (oy >= OH) {
                    break;
                }

                const float wy = ramp(y, TS, ovs, t, b);
                float* a = &acc[(size_t)(oy - base) * AW * 3];
                float* ws = &wsum[(size_t)(oy - base) * AW];

                for (int x = 0; x < TS; x++) {
                    const int ox = tx * s + x;

                    if (ox >= OW) {
                        break;
                    }

                    const float w = wy * ramp(x, TS, ovs, l, r);
                    const size_t k = (size_t)y * TS + x;
                    const int ai = ox - ax0;
                    a[ai * 3] += w * to[k];
                    a[ai * 3 + 1] += w * to[oplane + k];
                    a[ai * 3 + 2] += w * to[2 * oplane + k];
                    ws[ai] += w;
                }
            }

            done++;

            if (cb && cb(user, done, total)) {
                return 1;
            }
        }
    }

    flush(base + AH);
    return 0;
}

/* ---------------- embedding models ---------------- */

extern "C" int pz_ai_dim(const pz_ai* h) {
    return h ? h->dim : 0;
}

/* size the input once (a fixed shape keeps the GPU from re-tuning) */
static int shape_input(pz_ai* h, const std::vector<int>& shp) {
    if (h->in_shape == shp) {
        return 0;
    }

    h->net->resizeTensor(h->in, shp);
    h->net->resizeSession(h->sess);
    int status = 0;
    h->net->getSessionInfo(h->sess, MNN::Interpreter::RESIZE_STATUS, &status);

    if (status != 0) {
        return fail("cannot allocate the model's buffers");
    }

    h->out = h->net->getSessionOutput(h->sess, nullptr);
    h->in_shape = shp;
    h->hin.reset(MNN::Tensor::create(shp, h->in->getType(), nullptr, MNN::Tensor::CAFFE));
    h->hout.reset(new MNN::Tensor(h->out, MNN::Tensor::CAFFE));
    std::vector<int> os = h->out->shape();
    h->dim = os.empty() ? 0 : os.back();
    return 0;
}

static int run_embed(pz_ai* h, float* emb) {
    if (forward(h) != 0) {
        return -1;
    }

    const float* o = h->hout->host<float>();
    double n2 = 0;

    for (int i = 0; i < h->dim; i++) {
        n2 += (double)o[i] * o[i];
    }

    float inv = n2 > 0 ? (float)(1.0 / std::sqrt(n2)) : 0.f;

    for (int i = 0; i < h->dim; i++) {
        emb[i] = o[i] * inv;
    }

    return 0;
}

extern "C" int pz_ai_clip_image(pz_ai* h, const pz_image* img, float* emb) {
    g_err.clear();

    if (!h || !img || !img->px || img->w < 2 || img->h < 2) {
        return fail("no image");
    }

    const int S = 224;

    if (shape_input(h, {1, 3, S, S}) != 0) {
        return -1;
    }

    /* shortest edge to 224, then the centre 224 x 224 */
    double f = (double)S / std::min(img->w, img->h);
    int w = std::max(S, (int)lrint(img->w * f)), hh = std::max(S, (int)lrint(img->h * f));
    pz_image r = {0, 0, NULL};

    if (pz_resize(img, w, hh, &r) != 0) {
        return fail("out of memory");
    }

    const float mean[3] = {0.48145466f, 0.4578275f, 0.40821073f};
    const float stdv[3] = {0.26862954f, 0.26130258f, 0.27577711f};
    float* t = h->hin->host<float>();
    const int x0 = (w - S) / 2, y0 = (hh - S) / 2;

    for (int y = 0; y < S; y++) {
        for (int x = 0; x < S; x++) {
            uint32_t p = r.px[(size_t)(y0 + y) * w + x0 + x];
            float c[3] = {((p >> 16) & 255) / 255.f, ((p >> 8) & 255) / 255.f, (p & 255) / 255.f};

            for (int k = 0; k < 3; k++) {
                t[(size_t)k * S * S + y * S + x] = (c[k] - mean[k]) / stdv[k];
            }
        }
    }

    pz_free(&r);
    return run_embed(h, emb);
}

/* JSON string body -> UTF-8 (\uXXXX, surrogate pairs and the usual escapes) */
static void put_utf8(std::string& o, unsigned cp) {
    if (cp < 0x80) {
        o += (char)cp;
    } else if (cp < 0x800) {
        o += (char)(0xC0 | (cp >> 6));
        o += (char)(0x80 | (cp & 63));
    } else if (cp < 0x10000) {
        o += (char)(0xE0 | (cp >> 12));
        o += (char)(0x80 | ((cp >> 6) & 63));
        o += (char)(0x80 | (cp & 63));
    } else {
        o += (char)(0xF0 | (cp >> 18));
        o += (char)(0x80 | ((cp >> 12) & 63));
        o += (char)(0x80 | ((cp >> 6) & 63));
        o += (char)(0x80 | (cp & 63));
    }
}

extern "C" int pz_ai_clip_load_bpe(pz_ai* h, const char* vocab_json, const char* merges_txt) {
    g_err.clear();
    std::ifstream fv(vocab_json, std::ios::binary);

    if (!fv) {
        return fail(std::string("cannot read ") + vocab_json);
    }

    std::stringstream ss;
    ss << fv.rdbuf();
    const std::string js = ss.str();
    size_t i = 0;

    while (true) {
        i = js.find('"', i);

        if (i == std::string::npos) {
            break;
        }

        std::string key;
        i++;

        while (i < js.size() && js[i] != '"') {
            if (js[i] == '\\' && i + 1 < js.size()) {
                char e = js[++i];

                if (e == 'u') {
                    unsigned cp = (unsigned)strtoul(js.substr(i + 1, 4).c_str(), nullptr, 16);
                    i += 4;

                    if (cp >= 0xD800 && cp < 0xDC00 && js.compare(i + 1, 2, "\\u") == 0) {
                        unsigned lo = (unsigned)strtoul(js.substr(i + 3, 4).c_str(), nullptr, 16);
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    }

                    put_utf8(key, cp);
                } else {
                    key += e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e == 'b' ? '\b' : e == 'f' ? '\f' : e;
                }
            } else {
                key += js[i];
            }

            i++;
        }

        size_t c = js.find(':', i);

        if (c == std::string::npos) {
            break;
        }

        h->vocab[key] = atoi(js.c_str() + c + 1);
        i = js.find_first_of(",}", c);

        if (i == std::string::npos) {
            break;
        }
    }

    std::ifstream fm(merges_txt);

    if (!fm) {
        return fail(std::string("cannot read ") + merges_txt);
    }

    std::string line;
    int rank = 0;

    while (std::getline(fm, line)) {
        if (line.empty() || line[0] == '#') {
            continue;
        }

        size_t sp = line.find(' ');

        if (sp == std::string::npos) {
            continue;
        }

        h->ranks[ {line.substr(0, sp), line.substr(sp + 1)}] = rank++;
    }

    /* GPT-2's byte -> printable unicode map */
    std::vector<int> bs;

    for (int b = '!'; b <= '~'; b++) {
        bs.push_back(b);
    }

    for (int b = 0xA1; b <= 0xAC; b++) {
        bs.push_back(b);
    }

    for (int b = 0xAE; b <= 0xFF; b++) {
        bs.push_back(b);
    }

    std::vector<int> cs = bs;
    int n = 0;

    for (int b = 0; b < 256; b++) {
        if (std::find(bs.begin(), bs.end(), b) == bs.end()) {
            bs.push_back(b);
            cs.push_back(256 + n++);
        }
    }

    for (size_t k = 0; k < bs.size(); k++) {
        h->byte2u[bs[k]].clear();
        put_utf8(h->byte2u[bs[k]], (unsigned)cs[k]);
    }

    if (h->vocab.empty() || h->ranks.empty()) {
        return fail("empty CLIP vocabulary");
    }

    return 0;
}

/* split UTF-8 into code points */
static std::vector<std::pair<unsigned, std::string>> codepoints(const std::string& s) {
    std::vector<std::pair<unsigned, std::string>> v;

    for (size_t i = 0; i < s.size();) {
        unsigned char c = s[i];
        int n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        unsigned cp = n == 1 ? c : n == 2 ? c & 31 : n == 3 ? c & 15 : c & 7;

        for (int k = 1; k < n && i + k < s.size(); k++) {
            cp = (cp << 6) | (s[i + k] & 63);
        }

        v.push_back({cp, s.substr(i, n)});
        i += n;
    }

    return v;
}

static bool is_space(unsigned cp) {
    return cp == ' ' || (cp >= 9 && cp <= 13) || cp == 0xA0 || cp == 0x3000 || (cp >= 0x2000 && cp <= 0x200A);
}

/* letters: ASCII letters and, approximately, every non-ASCII code point that
 * is not a space or a common punctuation block */
static bool is_letter(unsigned cp) {
    if (cp < 128) {
        return isalpha((int)cp) != 0;
    }

    return !(cp >= 0x2010 && cp <= 0x206F) && !(cp >= 0x3000 && cp <= 0x303F) && !(cp >= 0xFF00 && cp <= 0xFF0F)
           && !(cp >= 0xA1 && cp <= 0xBF) && cp != 0xD7 && cp != 0xF7;
}

static void bpe_word(pz_ai* h, const std::string& word, std::vector<int>& out) {
    auto it = h->bpe_cache.find(word);

    if (it != h->bpe_cache.end()) {
        out.insert(out.end(), it->second.begin(), it->second.end());
        return;
    }

    std::vector<std::string> sym;

    for (unsigned char b : word) {
        sym.push_back(h->byte2u[b]);
    }

    if (sym.empty()) {
        return;
    }

    sym.back() += "</w>";

    while (sym.size() > 1) {
        int best = -1, bi = -1;

        for (size_t k = 0; k + 1 < sym.size(); k++) {
            auto r = h->ranks.find({sym[k], sym[k + 1]});

            if (r != h->ranks.end() && (best < 0 || r->second < best)) {
                best = r->second;
                bi = (int)k;
            }
        }

        if (bi < 0) {
            break;
        }

        /* merge every occurrence of that pair, left to right */
        const std::string a = sym[bi], b = sym[bi + 1];
        std::vector<std::string> ns;

        for (size_t k = 0; k < sym.size(); k++) {
            if (k + 1 < sym.size() && sym[k] == a && sym[k + 1] == b) {
                ns.push_back(a + b);
                k++;
            } else {
                ns.push_back(sym[k]);
            }
        }

        sym.swap(ns);
    }

    std::vector<int> ids;

    for (auto& t : sym) {
        auto v = h->vocab.find(t);

        if (v != h->vocab.end()) {
            ids.push_back(v->second);
        }
    }

    h->bpe_cache[word] = ids;
    out.insert(out.end(), ids.begin(), ids.end());
}

extern "C" int pz_ai_clip_tokenize(pz_ai* h, const char* text, int* ids, int max) {
    if (!h || h->vocab.empty()) {
        return fail("no CLIP vocabulary loaded");
    }

    /* lower case, then CLIP's pre-tokenizer: contractions, letter runs,
     * single digits, runs of other symbols */
    std::string low;

    for (const char* p = text; *p; p++) {
        low += (char)tolower((unsigned char)*p);
    }

    auto cps = codepoints(low);
    std::vector<int> tok = {49406};
    size_t i = 0;

    while (i < cps.size()) {
        unsigned cp = cps[i].first;

        if (is_space(cp)) {
            i++;
            continue;
        }

        std::string w;

        if (cp == '\'' && i + 1 < cps.size()) {
            static const char* con[] = {"s", "t", "re", "ve", "m", "ll", "d"};
            bool hit = false;

            for (const char* c : con) {
                size_t n = strlen(c), k;

                for (k = 0; k < n && i + 1 + k < cps.size() && cps[i + 1 + k].first == (unsigned char)c[k]; k++);

                if (k == n) {
                    w = std::string("'") + c;
                    i += 1 + n;
                    hit = true;
                    break;
                }
            }

            if (hit) {
                bpe_word(h, w, tok);
                continue;
            }
        }

        if (is_letter(cp)) {
            while (i < cps.size() && is_letter(cps[i].first)) {
                w += cps[i++].second;
            }
        } else if (cp < 128 && isdigit((int)cp)) {
            w = cps[i++].second;
        } else {
            while (i < cps.size() && !is_space(cps[i].first) && !is_letter(cps[i].first) &&
                    !(cps[i].first < 128 && isdigit((int)cps[i].first))) {
                w += cps[i++].second;
            }
        }

        bpe_word(h, w, tok);
    }

    tok.push_back(49407);

    if ((int)tok.size() > max) { /* keep the end-of-text token */
        tok.resize(max);
        tok[max - 1] = 49407;
    }

    for (size_t k = 0; k < tok.size(); k++) {
        ids[k] = tok[k];
    }

    return (int)tok.size();
}

extern "C" int pz_ai_clip_text(pz_ai* h, const char* text, float* emb) {
    g_err.clear();
    int ids[77];
    int n = pz_ai_clip_tokenize(h, text, ids, 77);

    if (n <= 0) {
        return -1;
    }

    /* the exact length: run this tower on the CPU (MNN's OpenCL gives the
     * same embedding for every query here), where a new length is cheap */
    const int L = n;

    if (shape_input(h, {1, L}) != 0) {
        return -1;
    }

    halide_type_t t = h->hin->getType();

    for (int k = 0; k < L; k++) {
        int v = k < n ? ids[k] : 49407;

        if (t.code == halide_type_int && t.bits == 64) {
            h->hin->host<int64_t>()[k] = v;
        } else if (t.code == halide_type_float) {
            h->hin->host<float>()[k] = (float)v;
        } else {
            h->hin->host<int32_t>()[k] = v;
        }
    }

    return run_embed(h, emb);
}

/* ---------------- faces ---------------- */

static MNN::Tensor* named_out(pz_ai* h, const char* name, std::vector<std::unique_ptr<MNN::Tensor>>& keep) {
    MNN::Tensor* t = h->net->getSessionOutput(h->sess, name);

    if (!t) {
        return nullptr;
    }

    keep.emplace_back(new MNN::Tensor(t, MNN::Tensor::CAFFE));
    t->copyToHostTensor(keep.back().get());
    return keep.back().get();
}

static float iou(const pz_face& a, const pz_face& b) {
    float x0 = std::max(a.x, b.x), y0 = std::max(a.y, b.y);
    float x1 = std::min(a.x + a.w, b.x + b.w), y1 = std::min(a.y + a.h, b.y + b.h);
    float in = std::max(0.f, x1 - x0) * std::max(0.f, y1 - y0);
    float u = a.w * a.h + b.w * b.h - in;
    return u > 0 ? in / u : 0.f;
}

extern "C" int pz_ai_faces(pz_ai* h, const pz_image* img, int size, float thresh, pz_face* faces, int max) {
    g_err.clear();

    if (!h || !img || !img->px || img->w < 8 || img->h < 8) {
        return fail("no image");
    }

    size = std::max(160, (size + 31) / 32 * 32);

    if (shape_input(h, {1, 3, size, size}) != 0) {
        return -1;
    }

    /* letterbox: the long edge to size, padded right and bottom */
    double f = (double)size / std::max(img->w, img->h);
    int w = std::max(1, (int)lrint(img->w * f)), hh = std::max(1, (int)lrint(img->h * f));
    pz_image r = {0, 0, NULL};

    if (pz_resize(img, w, hh, &r) != 0) {
        return fail("out of memory");
    }

    float* t = h->hin->host<float>();
    const size_t pl = (size_t)size * size;
    std::fill(t, t + 3 * pl, 0.f);

    for (int y = 0; y < hh; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t p = r.px[(size_t)y * w + x];
            size_t k = (size_t)y * size + x;
            t[k] = (float)(p & 255);              /* B */
            t[pl + k] = (float)((p >> 8) & 255);  /* G */
            t[2 * pl + k] = (float)((p >> 16) & 255); /* R */
        }
    }

    pz_free(&r);

    if (!h->in->copyFromHostTensor(h->hin.get()) || h->net->runSession(h->sess) != MNN::NO_ERROR) {
        return fail("MNN runSession failed");
    }

    if (h->cache_dirty) {
        h->net->updateCacheFile(h->sess);
        h->cache_dirty = false;
    }

    std::vector<pz_face> cand;
    std::vector<std::unique_ptr<MNN::Tensor>> keep;
    const int strides[3] = {8, 16, 32};

    for (int si = 0; si < 3; si++) {
        const int st = strides[si], cols = size / st, rows = size / st;
        char n[16];
        snprintf(n, sizeof(n), "cls_%d", st);
        MNN::Tensor* cls = named_out(h, n, keep);
        snprintf(n, sizeof(n), "obj_%d", st);
        MNN::Tensor* obj = named_out(h, n, keep);
        snprintf(n, sizeof(n), "bbox_%d", st);
        MNN::Tensor* box = named_out(h, n, keep);
        snprintf(n, sizeof(n), "kps_%d", st);
        MNN::Tensor* kps = named_out(h, n, keep);

        if (!cls || !obj || !box || !kps) {
            return fail("not a YuNet model");
        }

        const float* c = cls->host<float>(), *o = obj->host<float>(), *b = box->host<float>(), *k = kps->host<float>();

        for (int i = 0; i < rows * cols; i++) {
            float sc = std::sqrt(std::min(1.f, std::max(0.f, c[i])) * std::min(1.f, std::max(0.f, o[i])));

            if (sc < thresh) {
                continue;
            }

            const int cx = i % cols, cy = i / cols;
            pz_face fc;
            float bw = std::exp(b[i * 4 + 2]) * st, bh = std::exp(b[i * 4 + 3]) * st;
            float px = (cx + b[i * 4]) * st, py = (cy + b[i * 4 + 1]) * st;
            fc.x = (float)((px - bw / 2) / f);
            fc.y = (float)((py - bh / 2) / f);
            fc.w = (float)(bw / f);
            fc.h = (float)(bh / f);
            fc.score = sc;

            for (int j = 0; j < 5; j++) {
                fc.lm[2 * j] = (float)((k[i * 10 + 2 * j] + cx) * st / f);
                fc.lm[2 * j + 1] = (float)((k[i * 10 + 2 * j + 1] + cy) * st / f);
            }

            cand.push_back(fc);
        }
    }

    std::sort(cand.begin(), cand.end(), [](const pz_face & a, const pz_face & b) {
        return a.score > b.score;
    });
    int n = 0;

    for (size_t i = 0; i < cand.size() && n < max; i++) {
        bool dup = false;

        for (int j = 0; j < n && !dup; j++) {
            dup = iou(cand[i], faces[j]) > 0.3f;
        }

        if (!dup) {
            faces[n++] = cand[i];
        }
    }

    return n;
}

extern "C" int pz_ai_face_embed(pz_ai* h, const pz_image* img, const pz_face* f, float* emb) {
    g_err.clear();

    if (!h || !img || !img->px || !f) {
        return fail("no face");
    }

    if (shape_input(h, {1, 3, 112, 112}) != 0) {
        return -1;
    }

    /* the similarity transform taking the 5 landmarks onto ArcFace's 112 px
     * template (least squares, Umeyama without reflection) */
    static const float T[10] = {38.2946f, 51.6963f, 73.5318f, 51.5014f, 56.0252f, 71.7366f,
                                41.5493f, 92.3655f, 70.7299f, 92.2041f
                               };
    double mx = 0, my = 0, tx = 0, ty = 0;

    for (int i = 0; i < 5; i++) {
        mx += f->lm[2 * i];
        my += f->lm[2 * i + 1];
        tx += T[2 * i];
        ty += T[2 * i + 1];
    }

    mx /= 5;
    my /= 5;
    tx /= 5;
    ty /= 5;
    double sxx = 0, a = 0, b = 0;

    for (int i = 0; i < 5; i++) {
        double px = f->lm[2 * i] - mx, py = f->lm[2 * i + 1] - my;
        double qx = T[2 * i] - tx, qy = T[2 * i + 1] - ty;
        sxx += px * px + py * py;
        a += px * qx + py * qy;
        b += px * qy - py * qx;
    }

    if (sxx <= 0) {
        return fail("degenerate landmarks");
    }

    a /= sxx;
    b /= sxx; /* q = [a -b; b a] (p - m) + t */
    /* inverse: p = [a b; -b a] (q - t) / (a^2 + b^2) + m */
    const double d = a * a + b * b;
    float* in = h->hin->host<float>();
    const size_t pl = 112 * 112;

    for (int y = 0; y < 112; y++) {
        for (int x = 0; x < 112; x++) {
            double qx = x - tx, qy = y - ty;
            double sx = (a * qx + b * qy) / d + mx, sy = (-b * qx + a * qy) / d + my;
            int x0 = (int)std::floor(sx), y0 = (int)std::floor(sy);
            double fx = sx - x0, fy = sy - y0;
            double acc[3] = {0, 0, 0};

            for (int k = 0; k < 4; k++) {
                int xx = x0 + (k & 1), yy = y0 + (k >> 1);
                double w = ((k & 1) ? fx : 1 - fx) * ((k >> 1) ? fy : 1 - fy);
                uint32_t p = 0;

                if (xx >= 0 && yy >= 0 && xx < img->w && yy < img->h) {
                    p = img->px[(size_t)yy * img->w + xx];
                }

                acc[0] += w * ((p >> 16) & 255);
                acc[1] += w * ((p >> 8) & 255);
                acc[2] += w * (p & 255);
            }

            /* RGB, 0..255 (OpenCV's FaceRecognizerSF: swapRB, no scaling) */
            for (int c = 0; c < 3; c++) {
                in[c * pl + (size_t)y * 112 + x] = (float)acc[c];
            }
        }
    }

    return run_embed(h, emb);
}

/* ---------------- SAM and LaMa ---------------- */

/* fill a named input from floats (resizing it to shp first) */
static int set_input(pz_ai* h, const char* name, const std::vector<int>& shp, const float* data,
                     bool resize) {
    MNN::Tensor* t = h->net->getSessionInput(h->sess, name);

    if (!t) {
        return fail(std::string("the model has no input ") + name);
    }

    if (resize) {
        h->net->resizeTensor(t, shp);
    }

    (void)data;
    return 0;
}

static int copy_input(pz_ai* h, const char* name, const std::vector<int>& shp, const float* data) {
    MNN::Tensor* t = h->net->getSessionInput(h->sess, name);

    if (!t) {
        return fail(std::string("the model has no input ") + name);
    }

    std::unique_ptr<MNN::Tensor> host(MNN::Tensor::create<float>(shp, nullptr, MNN::Tensor::CAFFE));
    size_t n = 1;

    for (int d : shp) {
        n *= d;
    }

    memcpy(host->host<float>(), data, n * sizeof(float));
    return t->copyFromHostTensor(host.get()) ? 0 : fail("cannot upload an input");
}

static int run_resized(pz_ai* h) {
    h->net->resizeSession(h->sess);
    int status = 0;
    h->net->getSessionInfo(h->sess, MNN::Interpreter::RESIZE_STATUS, &status);
    return status == 0 ? 0 : fail("cannot allocate the model's buffers");
}

extern "C" int pz_ai_sam_encode(pz_ai* h, const pz_image* img, float* emb) {
    g_err.clear();

    if (!h || !img || !img->px) {
        return fail("no image");
    }

    double f = 1024.0 / std::max(img->w, img->h);
    int w = std::max(1, (int)lrint(img->w * f)), hh = std::max(1, (int)lrint(img->h * f));
    pz_image r = {0, 0, NULL};

    if (pz_resize(img, w, hh, &r) != 0) {
        return fail("out of memory");
    }

    /* always 1024 x 1024: the model normalises, then pads with zeros, so
       padding here with SAM's mean colour is the same -- and keeps MNN's
       shape-dependent padding out of it */
    const int S = 1024;
    std::vector<int> shp = {S, S, 3};

    if (h->in_shape != shp) {
        set_input(h, nullptr, shp, nullptr, true);

        if (run_resized(h) != 0) {
            pz_free(&r);
            return -1;
        }

        h->in_shape = shp;
    }

    std::vector<float> buf((size_t)S * S * 3);

    for (size_t i = 0; i < (size_t)S * S; i++) {
        buf[i * 3] = 123.675f;
        buf[i * 3 + 1] = 116.28f;
        buf[i * 3 + 2] = 103.53f;
    }

    for (int y = 0; y < hh; y++) {
        for (int x = 0; x < w; x++) { /* HWC RGB 0..255 */
            uint32_t p = r.px[(size_t)y * w + x];
            float* q = &buf[((size_t)y * S + x) * 3];
            q[0] = (float)((p >> 16) & 255);
            q[1] = (float)((p >> 8) & 255);
            q[2] = (float)(p & 255);
        }
    }

    pz_free(&r);
    MNN::Tensor* in = h->net->getSessionInput(h->sess, nullptr);
    /* a plain H x W x 3 buffer: the host tensor takes the input's own
       layout, so nothing gets reordered on the way in */
    std::unique_ptr<MNN::Tensor> host(new MNN::Tensor(in, in->getDimensionType()));
    memcpy(host->host<float>(), buf.data(), buf.size() * sizeof(float));

    if (!in->copyFromHostTensor(host.get()) || h->net->runSession(h->sess) != MNN::NO_ERROR) {
        return fail("MNN runSession failed");
    }

    MNN::Tensor* out = h->net->getSessionOutput(h->sess, nullptr);
    std::unique_ptr<MNN::Tensor> ho(new MNN::Tensor(out, MNN::Tensor::CAFFE));
    out->copyToHostTensor(ho.get());

    if (ho->elementSize() != PZ_SAM_EMB) {
        return fail("unexpected SAM embedding size");
    }

    memcpy(emb, ho->host<float>(), PZ_SAM_EMB * sizeof(float));

    if (getenv("PZ_AI_DEBUG")) {
        double m = 0, q = 0;

        for (int i = 0; i < PZ_SAM_EMB; i++) {
            m += emb[i];
            q += (double)emb[i] * emb[i];
        }

        m /= PZ_SAM_EMB;
        fprintf(stderr, "[sam] input %dx%d, emb mean %g std %g\n", w, hh, m, std::sqrt(q / PZ_SAM_EMB - m * m));
    }

    if (h->cache_dirty) {
        h->net->updateCacheFile(h->sess);
        h->cache_dirty = false;
    }

    return 0;
}

extern "C" int pz_ai_sam_mask(pz_ai* h, const float* emb, int w, int hgt, const float* pts,
                              const int* labels, int n, unsigned char* mask) {
    using namespace MNN::Express;
    g_err.clear();

    if (!h || h->dec_base.empty() || !emb || n <= 0 || w <= 0 || hgt <= 0) {
        return fail("nothing to select");
    }

    /* SAM's points live in the 1024 px frame; a padding point (-1) goes
     * last when there is no box */
    const double f = 1024.0 / std::max(w, hgt);
    /* the clicks (up to 5), then SAM's one padding point (label -1) */
    n = std::min(n, 5);
    const int NP = n + 1;

    if (!h->mod[NP]) {
        h->mod[NP].reset(MNN::Express::Module::load({"image_embeddings", "point_coords", "point_labels",
                         "mask_input", "has_mask_input", "orig_im_size"}, {"low_res_masks"},
                         (h->dec_base + std::to_string(NP) + ".mnn").c_str()));

        if (!h->mod[NP]) {
            return fail("cannot load the SAM decoder for " + std::to_string(n) + " points");
        }
    }

    VARP E = _Input({1, 256, 64, 64}, NCHW), P = _Input({1, NP, 2}, NCHW), L = _Input({1, NP}, NCHW);
    VARP MI = _Input({1, 1, 256, 256}, NCHW), HM = _Input({1}, NCHW), OS = _Input({2}, NCHW);
    memcpy(E->writeMap<float>(), emb, PZ_SAM_EMB * sizeof(float));
    float* pc = P->writeMap<float>(), *pl = L->writeMap<float>();

    for (int i = 0; i < n; i++) {
        pc[i * 2] = (float)((pts[i * 2] + 0.5) * f);
        pc[i * 2 + 1] = (float)((pts[i * 2 + 1] + 0.5) * f);
        pl[i] = (float)labels[i];
    }

    for (int i = n; i < NP; i++) {
        pc[i * 2] = 0;
        pc[i * 2 + 1] = 0;
        pl[i] = -1;
    }

    memset(MI->writeMap<float>(), 0, 256 * 256 * sizeof(float));
    HM->writeMap<float>()[0] = 0;
    OS->writeMap<float>()[0] = (float)hgt;
    OS->writeMap<float>()[1] = (float)w;
    std::vector<VARP> outs = h->mod[NP]->onForward({E, P, L, MI, HM, OS});

    if (outs.empty()) {
        return fail("the SAM decoder failed");
    }

    /* the low-res logits (256 px over the padded 1024 frame), upsampled
     * here to w x hgt */
    VARP lo = _Convert(outs[0], NCHW);
    const float* Lg = lo->readMap<float>();

    if (!Lg || lo->getInfo()->size < 256 * 256) {
        return fail("unexpected SAM decoder output");
    }

    if (getenv("PZ_AI_DEBUG")) {
        auto info = lo->getInfo();
        float mn = 1e9f, mx = -1e9f;
        int pos = 0;

        for (int i = 0; i < 256 * 256; i++) {
            mn = std::min(mn, Lg[i]);
            mx = std::max(mx, Lg[i]);
            pos += Lg[i] > 0;
        }

        fprintf(stderr, "[sam] low-res dims %d x %d x %d x %d, range %g..%g, %.1f%% > 0\n",
                info->dim.size() > 0 ? info->dim[0] : -1, info->dim.size() > 1 ? info->dim[1] : -1,
                info->dim.size() > 2 ? info->dim[2] : -1, info->dim.size() > 3 ? info->dim[3] : -1, mn, mx,
                pos * 100.0 / 65536);
    }

    for (int y = 0; y < hgt; y++) {
        for (int x = 0; x < w; x++) {
            double sx = (x + 0.5) * f / 4.0 - 0.5, sy = (y + 0.5) * f / 4.0 - 0.5;
            int x0 = std::max(0, std::min(255, (int)std::floor(sx))), y0 = std::max(0, std::min(255, (int)std::floor(sy)));
            int x1 = std::min(255, x0 + 1), y1 = std::min(255, y0 + 1);
            double fx = std::max(0.0, std::min(1.0, sx - x0)), fy = std::max(0.0, std::min(1.0, sy - y0));
            double v = (Lg[y0 * 256 + x0] * (1 - fx) + Lg[y0 * 256 + x1] * fx) * (1 - fy) +
                       (Lg[y1 * 256 + x0] * (1 - fx) + Lg[y1 * 256 + x1] * fx) * fy;
            mask[(size_t)y * w + x] = v > 0 ? 255 : 0;
        }
    }

    return 0;
}

extern "C" int pz_ai_inpaint(pz_ai* h, pz_image* img, const unsigned char* mask) {
    g_err.clear();

    if (!h || !img || !img->px || !mask) {
        return fail("nothing to remove");
    }

    const int W = img->w, H = img->h;
    int x0 = W, y0 = H, x1 = -1, y1 = -1;

    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            if (mask[(size_t)y * W + x]) {
                x0 = std::min(x0, x);
                x1 = std::max(x1, x);
                y0 = std::min(y0, y);
                y1 = std::max(y1, y);
            }
        }
    }

    if (x1 < 0) {
        return 0; /* empty mask */
    }

    /* a square of context around the mask, about twice its size */
    int side = std::max(x1 - x0 + 1, y1 - y0 + 1);
    side = std::min(std::max(W, H), std::max(64, side * 2));
    int cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    int bx = std::max(0, std::min(W - std::min(side, W), cx - side / 2));
    int by = std::max(0, std::min(H - std::min(side, H), cy - side / 2));
    int bw = std::min(side, W), bh = std::min(side, H);
    const int S = 512;
    /* the crop and its mask (grown a little: SAM's edges are tight) */
    pz_image crop = {0, 0, NULL}, cs = {0, 0, NULL};

    if (pz_alloc(&crop, bw, bh) != 0) {
        return fail("out of memory");
    }

    for (int y = 0; y < bh; y++) {
        memcpy(crop.px + (size_t)y * bw, img->px + (size_t)(by + y) * W + bx, (size_t)bw * 4);
    }

    if (pz_resize(&crop, S, S, &cs) != 0) {
        pz_free(&crop);
        return fail("out of memory");
    }

    pz_free(&crop);
    std::vector<float> im(3 * S * S), mk(S * S);
    const int grow = std::max(2, S / 64);
    std::vector<unsigned char> m512(S * S, 0);

    for (int y = 0; y < S; y++) {
        for (int x = 0; x < S; x++) {
            int sx = bx + (int)((x + 0.5) * bw / S), sy = by + (int)((y + 0.5) * bh / S);
            m512[y * S + x] = mask[(size_t)std::min(H - 1, sy) * W + std::min(W - 1, sx)] ? 1 : 0;
        }
    }

    for (int y = 0; y < S; y++) {
        for (int x = 0; x < S; x++) {
            bool on = false;

            for (int dy = -grow; dy <= grow && !on; dy++) {
                for (int dx = -grow; dx <= grow && !on; dx++) {
                    int yy = y + dy, xx = x + dx;
                    on = yy >= 0 && xx >= 0 && yy < S && xx < S && m512[yy * S + xx];
                }
            }

            mk[y * S + x] = on ? 1.f : 0.f;
            uint32_t p = cs.px[y * S + x];
            im[y * S + x] = ((p >> 16) & 255) / 255.f;
            im[S * S + y * S + x] = ((p >> 8) & 255) / 255.f;
            im[2 * S * S + y * S + x] = (p & 255) / 255.f;
        }
    }

    pz_free(&cs);

    if (h->in_shape.empty()) {
        set_input(h, "image", {1, 3, S, S}, nullptr, true);
        set_input(h, "mask", {1, 1, S, S}, nullptr, true);

        if (run_resized(h) != 0) {
            return -1;
        }

        h->in_shape = {1, 3, S, S};
    }

    if (copy_input(h, "image", {1, 3, S, S}, im.data()) || copy_input(h, "mask", {1, 1, S, S}, mk.data())) {
        return -1;
    }

    if (h->net->runSession(h->sess) != MNN::NO_ERROR) {
        return fail("MNN runSession failed");
    }

    MNN::Tensor* out = h->net->getSessionOutput(h->sess, nullptr);
    std::unique_ptr<MNN::Tensor> ho(new MNN::Tensor(out, MNN::Tensor::CAFFE));
    out->copyToHostTensor(ho.get());

    if (h->cache_dirty) {
        h->net->updateCacheFile(h->sess);
        h->cache_dirty = false;
    }

    const float* o = ho->host<float>();
    /* LaMa's 512 px result back at the crop's size, then blended in where
     * the (grown) mask is, with a soft edge */
    pz_image res = {0, 0, NULL}, rb = {0, 0, NULL};
    pz_alloc(&res, S, S);

    for (int i = 0; i < S * S; i++) {
        int r = (int)std::min(255.f, std::max(0.f, o[i])), g = (int)std::min(255.f, std::max(0.f, o[S * S + i])),
            b = (int)std::min(255.f, std::max(0.f, o[2 * S * S + i]));
        res.px[i] = 0xFF000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
    }

    if (pz_resize(&res, bw, bh, &rb) != 0) {
        pz_free(&res);
        return fail("out of memory");
    }

    pz_free(&res);
    const int feather = std::max(2, grow * bw / S);

    for (int y = 0; y < bh; y++) {
        for (int x = 0; x < bw; x++) {
            /* the grown 512 px mask, sampled at this pixel, softened */
            double a = 0;
            int nn = 0;

            for (int dy = -feather; dy <= feather; dy += std::max(1, feather / 2)) {
                for (int dx = -feather; dx <= feather; dx += std::max(1, feather / 2)) {
                    int mx = (int)((x + dx + 0.5) * S / bw), my = (int)((y + dy + 0.5) * S / bh);

                    if (mx >= 0 && my >= 0 && mx < S && my < S) {
                        a += mk[my * S + mx];
                    }

                    nn++;
                }
            }

            a /= std::max(1, nn);

            if (a <= 0) {
                continue;
            }

            uint32_t& d = img->px[(size_t)(by + y) * W + bx + x];
            uint32_t s2 = rb.px[(size_t)y * bw + x];
            uint32_t v = d & 0xFF000000u;

            for (int c = 0; c < 24; c += 8) {
                double q = ((d >> c) & 255) * (1 - a) + ((s2 >> c) & 255) * a;
                v |= (uint32_t)lrint(q) << c;
            }

            d = v;
        }
    }

    pz_free(&rb);
    return 0;
}
