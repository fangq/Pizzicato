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

#include <algorithm>
#include <cmath>
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

    if (!h->in) {
        return false;
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
