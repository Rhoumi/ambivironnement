#include "engine.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>

// flush denormals to zero in the audio thread (decaying filter / reverb tails cost a lot of CPU otherwise)
#if defined(__SSE__) || defined(__x86_64__)
#include <xmmintrin.h>
#define AMBI_FTZ() _mm_setcsr(_mm_getcsr() | 0x8040)
#elif defined(__aarch64__)   // ARM64 (Apple Silicon...): FZ bit of the FPCR register
#define AMBI_FTZ() do { unsigned long long fpcr; __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr)); \
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr | (1ull << 24))); } while (0)
#else
#define AMBI_FTZ()
#endif

using namespace dsp;

Meters::Meters() {
    for (auto& s : src) for (auto& v : s) v.store(0.f);
    for (auto& v : spk) v.store(0.f);
    for (auto& v : field) v.store(0.f);
    for (auto& v : lfo) v.store(0.f);
    for (auto& v : env) v.store(0.f);
    for (auto& v : io) v.store(0.f);
    for (auto& v : in) v.store(0.f);
    for (auto& v : lim) v.store(1.f);
}

static int cbProcess(jack_nframes_t n, void* arg) { return static_cast<Engine*>(arg)->process(n); }
static int cbSr(jack_nframes_t n, void* arg) { static_cast<Engine*>(arg)->onSampleRate(n); return 0; }
static int cbBuf(jack_nframes_t n, void* arg) { static_cast<Engine*>(arg)->onBufferSize(n); return 0; }
static int cbXrun(void* arg) { static_cast<Engine*>(arg)->xruns.fetch_add(1); return 0; }
static void cbShutdown(void* arg) { static_cast<Engine*>(arg)->shutdown.store(true); }

static inline float lvl01(float rms) {
    if (rms <= 1e-6f) return 0.f;
    return clampf((20.f * std::log10(rms) + 60.f) / 60.f, 0.f, 1.f);
}

Engine::Engine() {
    inL_.assign(MAX_BLOCK, 0.f); inR_.assign(MAX_BLOCK, 0.f);
    bass_.assign(MAX_BLOCK, 0.f); rest_.assign(MAX_BLOCK, 0.f);
    sigL_.assign(MAX_BLOCK, 0.f); sigR_.assign(MAX_BLOCK, 0.f); sigC_.assign(MAX_BLOCK, 0.f);
    tmp_.assign(MAX_BLOCK, 0.f);
    for (int c = 0; c < 2; ++c) bin_[c].assign(MAX_BLOCK, 0.f);
    for (int s = 0; s < MAX_SRC; ++s) { srcL_[s].assign(MAX_BLOCK, 0.f); srcR_[s].assign(MAX_BLOCK, 0.f); }
    for (auto& h : hoa_) h.assign(MAX_BLOCK, 0.f);
    for (auto& h : rotHoa_) h.assign(MAX_BLOCK, 0.f);
    for (auto& sd : dopBuf_) for (auto& c : sd) c.assign(DOP_LEN, 0.f);
    dopL_.assign(MAX_BLOCK, 0.f);
    dopR_.assign(MAX_BLOCK, 0.f);
    for (int k = 0; k < HOA_N; ++k) rotPrev_[k][k] = 1.f;
    spkDl_.assign((size_t)MAX_SPK * SPK_DL, 0.f);
    binDl_.assign((size_t)BIN_V * BIN_DL, 0.f);
    for (auto& b : pwBuf_) b.assign(MAX_BLOCK, 0.f);
    dfDl_.assign((size_t)PW_V * 3 * DF_DL, 0.f);
    fxDl_.assign((size_t)PW_V * FX_DL, 0.f);
    rvDl_.assign((size_t)PW_V * 2 * RV_DL, 0.f);

    for (int s = 0; s < MAX_SRC; ++s) {
        base_[s][P_DIST] = 1; base_[s][P_WIDTH] = 40; base_[s][P_WIDER] = 1; base_[s][P_JRATE] = 0.5f;
        smode_[s] = SM_MIRROR;
        jit_[s][0].r1 = rng_.bipolar(); jit_[s][1].r1 = rng_.bipolar();
        for (auto& d : decayS_[s]) d = 0.3f;
    }
    const float xo[MAX_SRC - 1] = {150, 600, 2500, 6000, 9000, 11000, 12500, 14000, 15000, 16000, 17000, 17500, 18000, 18500, 19000};
    std::memcpy(xover_, xo, sizeof xover_);
    gbase_[G_FWIDER] = 1.f;
    gbase_[G_RM_FREQ] = 220.f; gbase_[G_RM_SPREAD] = 1.f;
    gbase_[G_AM_SHARP] = 2.f;
    gbase_[G_CR_RATE] = 8000.f; gbase_[G_CR_BITS] = 8.f;
    gbase_[G_DF_SIZE] = 0.5f;
    gbase_[G_DL_TIME] = 0.375f; gbase_[G_DL_FB] = 0.4f; gbase_[G_DL_SPREAD] = 0.3f;
    gbase_[G_RV_SIZE] = 0.6f; gbase_[G_RV_DAMP] = 0.4f;
    for (auto& d : decayG_) d = 0.3f;
    set_[S_MASTER] = 1; set_[S_SPK] = 1; set_[S_BIN] = 1; set_[S_INPUT] = 1; set_[S_BINON] = 1;
    set_[S_MODE] = 1; set_[S_BASSON] = 1; set_[S_BASSFREQ] = 80; set_[S_ENVATK] = 0.01f; set_[S_ENVREL] = 0.25f;
    set_[S_CLOCK] = 0; set_[S_RMMODEL] = 1; set_[S_DLSYNC] = 0;
    for (int i = 0; i < NUM_LFO; ++i) { lfo_[i].rate = 0.25f; lfo_[i].r1 = rng_.bipolar(); }

    // field meter (same Fibonacci directions as Godot)
    auto dirs = ambi::fibonacciSphere(FIELD_DIRS);
    fieldDec_ = ambi::samplingDecoder3D(dirs, 3, ambi::OPT_MAXRE, false);
    {
        float Y[HOA_N];
        sh3<float>((float)dirs[0][0], (float)dirs[0][1], (float)dirs[0][2], Y);
        float o = 0;
        for (int k = 0; k < HOA_N; ++k) o += fieldDec_[k] * Y[k];
        if (o > 1e-6f) for (auto& v : fieldDec_) v /= o;
    }

    auto toSpk = [](const std::vector<ambi::V3>& ds) {
        std::vector<ambi::Speaker> vs;
        for (auto& d : ds) {
            ambi::Speaker s;
            s.az = std::atan2(d[1], d[0]) * 180.0 / PI;
            s.el = std::asin(d[2]) * 180.0 / PI;
            vs.push_back(s);
        }
        return vs;
    };
    // binaural virtual speakers
    binDirs_ = ambi::fibonacciSphere(BIN_V);
    binDec_ = ambi::buildDecoder(toSpk(binDirs_), ambi::DEC_MODEMATCH, ambi::OPT_MAXRE, 3).D;
    {
        // ears sum virtual speakers coherently at LF: unity pressure for a plane wave
        float Y[HOA_N];
        sh3<float>(1.f, 0.f, 0.f, Y);
        float P = 0;
        for (int v = 0; v < BIN_V; ++v)
            for (int k = 0; k < HOA_N; ++k) P += binDec_[v * HOA_N + k] * Y[k];
        if (P > 1e-6f) for (auto& d : binDec_) d /= P;
    }

    // plane-wave domain: decode with pinv, re-encode with Y -> ~identity round trip
    pwDirs_ = ambi::fibonacciSphere(PW_V);
    pwDec_ = ambi::buildDecoder(toSpk(pwDirs_), ambi::DEC_MODEMATCH, ambi::OPT_BASIC, 3).D;
    pwEnc_.assign(HOA_N * PW_V, 0.f);
    for (int v = 0; v < PW_V; ++v) {
        float Y[HOA_N];
        sh3<float>((float)pwDirs_[v][0], (float)pwDirs_[v][1], (float)pwDirs_[v][2], Y);
        for (int k = 0; k < HOA_N; ++k) pwEnc_[k * PW_V + v] = Y[k];
    }
    {
        double tr = 0;
        for (int k = 0; k < HOA_N; ++k)
            for (int v = 0; v < PW_V; ++v) tr += pwEnc_[k * PW_V + v] * pwDec_[v * HOA_N + k];
        float sc = float(HOA_N / tr);
        for (auto& d : pwDec_) d *= sc;
    }
    for (int v = 0; v < PW_V; ++v) {
        pwHash_[v] = rng_.bipolar();
        float best = 2; int bi = v;
        for (int u = 0; u < PW_V; ++u) {
            float d = float(pwDirs_[v][0] * pwDirs_[u][0] + pwDirs_[v][1] * pwDirs_[u][1] + pwDirs_[v][2] * pwDirs_[u][2]);
            if (d < best) { best = d; bi = u; }
        }
        pwOpp_[v] = bi;
        amPrev_[v] = 1.f;
    }

    // field mirror signs: Y_k(x,-y,z) = s * Y_k(x,y,z) etc.
    {
        const float x = 0.31f, y = 0.47f, z = 0.83f;
        float Y[HOA_N], Yx[HOA_N], Yy[HOA_N], Yz[HOA_N];
        sh3<float>(x, y, z, Y); sh3<float>(-x, y, z, Yx); sh3<float>(x, -y, z, Yy); sh3<float>(x, y, -z, Yz);
        for (int k = 0; k < HOA_N; ++k) {
            mirSign_[0][k] = Yy[k] * Y[k] < 0 ? -1.f : 1.f;  // left/right
            mirSign_[1][k] = Yx[k] * Y[k] < 0 ? -1.f : 1.f;  // front/back
            mirSign_[2][k] = Yz[k] * Y[k] < 0 ? -1.f : 1.f;  // up/down
            mirPrev_[k] = 1.f;
        }
    }
}

Engine::~Engine() { close(); }

bool Engine::open(const std::string& name) {
    jack_status_t st;
    client_ = jack_client_open(name.c_str(), JackNoStartServer, &st);
    if (!client_) {
        std::fprintf(stderr, "[engine] cannot open JACK client (status 0x%x). Is PipeWire/JACK running?\n", st);
        return false;
    }
    jack_set_process_callback(client_, cbProcess, this);
    jack_set_sample_rate_callback(client_, cbSr, this);
    jack_set_buffer_size_callback(client_, cbBuf, this);
    jack_set_xrun_callback(client_, cbXrun, this);
    jack_on_shutdown(client_, cbShutdown, this);

    for (int i = 0; i < NUM_IN; ++i) {
        char nm[16];
        std::snprintf(nm, sizeof nm, "in_%dL", i + 1);
        inPorts_[2 * i] = jack_port_register(client_, nm, JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
        std::snprintf(nm, sizeof nm, "in_%dR", i + 1);
        inPorts_[2 * i + 1] = jack_port_register(client_, nm, JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
    }
    binPorts_[0] = jack_port_register(client_, "bin_L", JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0);
    binPorts_[1] = jack_port_register(client_, "bin_R", JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0);

    sr_ = (float)jack_get_sample_rate(client_);
    bufSize_.store((int)jack_get_buffer_size(client_));
    recomputeSr(sr_);

    link_ = std::make_unique<ableton::Link>(120.0);
    link_->enable(true);

    decode_.store(new DecodeState());
    if (jack_activate(client_)) {
        std::fprintf(stderr, "[engine] cannot activate client\n");
        return false;
    }
    std::printf("[engine] JACK client '%s' active, %.0f Hz, %d frames, Ableton Link on\n",
                jack_get_client_name(client_), sr_, bufSize_.load());
    return true;
}

void Engine::close() {
    if (client_) {
        jack_deactivate(client_);
        jack_client_close(client_);
        client_ = nullptr;
    }
    if (link_) { link_->enable(false); link_.reset(); }
    delete decode_.exchange(nullptr);
}

void Engine::setClockLink(bool on) {
    clockLink_.store(on);
    if (link_) link_->enable(on);
}

std::string Engine::ownPrefix() const { return std::string(jack_get_client_name(client_)) + ":"; }

void Engine::waitBlocks(int count) {
    uint64_t start = blocks_.load();
    auto t0 = std::chrono::steady_clock::now();
    while (blocks_.load() < start + (uint64_t)count) {
        if (std::chrono::steady_clock::now() - t0 > std::chrono::milliseconds(500)) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
}

void Engine::applyLayout(const std::vector<ambi::Speaker>& spkIn, int type, int optim, int order, bool distComp) {
    std::vector<ambi::Speaker> spk = spkIn;
    if ((int)spk.size() > MAX_SPK) spk.resize(MAX_SPK);
    const int L = (int)spk.size();

    // Subwoofers are left out of the decoder design: only the full-range speakers are decoded.
    std::vector<ambi::Speaker> mains;
    std::vector<int> mainRow(L, -1);
    int nsub = 0;
    for (int s = 0; s < L; ++s) {
        if (spk[s].sub) { ++nsub; continue; }
        mainRow[s] = (int)mains.size();
        mains.push_back(spk[s]);
    }
    ambi::DecoderResult res;
    if (!mains.empty()) {
        res = ambi::buildDecoder(mains, type, optim, order);
    } else {
        res.info = "no full-range speaker";
        res.order = order;
    }
    decoderInfo = res.info;
    if (nsub > 0) decoderInfo += " + " + std::to_string(nsub) + " sub" + (nsub > 1 ? "s" : "");
    decoderOrder = res.order;

    while ((int)spkPool_.size() < L) {
        char nm[32];
        std::snprintf(nm, sizeof nm, "spk_%02d", (int)spkPool_.size() + 1);
        jack_port_t* p = jack_port_register(client_, nm, JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0);
        if (!p) break;
        spkPool_.push_back(p);
    }
    auto* st = new DecodeState();
    st->nspk = std::min(L, (int)spkPool_.size());
    double maxd = 0, wsum = 0;
    for (auto& s : spk) maxd = std::max(maxd, s.dist);
    int nmainUsed = 0, nsubUsed = 0;
    for (int s = 0; s < st->nspk; ++s) {
        st->ports[s] = spkPool_[s];
        const int r = mainRow[s];
        if (r >= 0) {
            for (int k = 0; k < HOA_N; ++k) st->D[s][k] = res.D[r * HOA_N + k];
            wsum += res.D[r * HOA_N];
            ++nmainUsed;
        } else {
            ++nsubUsed;
        }
        // distance compensation applies to subwoofers too, so the bass stays time-aligned
        if (distComp && maxd > 0.01) {
            st->gain[s] = float(std::max(0.05, spk[s].dist) / maxd);
            st->delay[s] = std::clamp((int)std::lround((maxd - spk[s].dist) / 343.0 * sr_), 0, SPK_DL - 1);
        } else {
            st->gain[s] = 1.f;
            st->delay[s] = 0;
        }
    }
    // Mono bass: same total level as before, shared by the subwoofers if there are any,
    // otherwise by every speaker.
    if (nsubUsed > 0) {
        // no full-range speaker to measure the decoder level from: unity on the subs
        const float g = nmainUsed > 0 ? float(wsum / nsubUsed) : 1.f;
        for (int s = 0; s < st->nspk; ++s) st->bassGain[s] = mainRow[s] < 0 ? g : 0.f;
    } else if (nmainUsed > 0) {
        for (int s = 0; s < st->nspk; ++s) st->bassGain[s] = float(wsum / nmainUsed);
    }
    DecodeState* old = decode_.exchange(st);
    waitBlocks(2);
    delete old;
    while ((int)spkPool_.size() > L) {
        jack_port_unregister(client_, spkPool_.back());
        spkPool_.pop_back();
    }
    std::printf("[engine] layout: %s\n", decoderInfo.c_str());
}

std::vector<std::string> Engine::listPorts(bool outputs) {
    std::vector<std::string> r;
    const char** ports = jack_get_ports(client_, nullptr, JACK_DEFAULT_AUDIO_TYPE, outputs ? JackPortIsOutput : JackPortIsInput);
    if (!ports) return r;
    std::string own = ownPrefix();
    for (int i = 0; ports[i]; ++i)
        if (std::strncmp(ports[i], own.c_str(), own.size()) != 0) r.push_back(ports[i]);
    jack_free(ports);
    return r;
}

static std::vector<std::string> matchPorts(jack_client_t* c, const std::string& pattern, unsigned long flags, const std::string& own) {
    std::vector<std::string> r;
    const char** ports = jack_get_ports(c, pattern.empty() ? nullptr : pattern.c_str(), JACK_DEFAULT_AUDIO_TYPE, flags);
    if (!ports) return r;
    for (int i = 0; ports[i]; ++i)
        if (std::strncmp(ports[i], own.c_str(), own.size()) != 0) r.push_back(ports[i]);
    jack_free(ports);
    return r;
}

// Matching outputs connect in order: ports 1-2 -> in_1L/R, 3-4 -> in_2L/R ... (orbits mode)
void Engine::connectInputs(const std::string& pattern) {
    if (pattern.empty()) return;
    auto src = matchPorts(client_, pattern, JackPortIsOutput, ownPrefix());
    for (auto* p : inPorts_) jack_port_disconnect(client_, p);
    if (src.empty()) { std::printf("[engine] no output port matches '%s'\n", pattern.c_str()); return; }
    if (src.size() == 1) {
        jack_connect(client_, src[0].c_str(), jack_port_name(inPorts_[0]));
        jack_connect(client_, src[0].c_str(), jack_port_name(inPorts_[1]));
    } else {
        for (size_t i = 0; i < src.size() && i < (size_t)NUM_IN * 2; ++i)
            jack_connect(client_, src[i].c_str(), jack_port_name(inPorts_[i]));
    }
    std::printf("[engine] input <- %zu port(s) from '%s'\n", std::min(src.size(), (size_t)NUM_IN * 2), pattern.c_str());
}

void Engine::connectBinaural(const std::string& pattern) {
    std::vector<std::string> dst = pattern.empty()
        ? matchPorts(client_, "", JackPortIsInput | JackPortIsPhysical, ownPrefix())
        : matchPorts(client_, pattern, JackPortIsInput, ownPrefix());
    jack_port_disconnect(client_, binPorts_[0]);
    jack_port_disconnect(client_, binPorts_[1]);
    if (dst.empty()) { std::printf("[engine] no binaural destination\n"); return; }
    jack_connect(client_, jack_port_name(binPorts_[0]), dst[0].c_str());
    if (dst.size() > 1) jack_connect(client_, jack_port_name(binPorts_[1]), dst[1].c_str());
    std::printf("[engine] binaural -> %s ...\n", dst[0].c_str());
}

void Engine::connectSpeakers(const std::string& pattern) {
    std::vector<std::string> dst = pattern.empty()
        ? matchPorts(client_, "", JackPortIsInput | JackPortIsPhysical, ownPrefix())
        : matchPorts(client_, pattern, JackPortIsInput, ownPrefix());
    size_t n = 0;
    for (size_t i = 0; i < spkPool_.size(); ++i) {
        jack_port_disconnect(client_, spkPool_[i]);
        const size_t j = (i < spkMap_.size() && spkMap_[i] > 0) ? size_t(spkMap_[i] - 1) : i;
        if (j < dst.size()) { jack_connect(client_, jack_port_name(spkPool_[i]), dst[j].c_str()); ++n; }
    }
    std::printf("[engine] speakers -> %zu ports\n", n);
}

// ------------------------------------------------------------------ DSP setup

void Engine::recomputeSr(float sr) {
    sr_ = sr;
    recomputeCrossovers();
    recomputeBass();
    recomputeBinaural();
}

static void keepSet(Biquad& b, int kind, double f, double q, double sr) {
    float z1 = b.z1, z2 = b.z2;
    if (kind == 0) b.setLP(f, q, sr); else if (kind == 1) b.setHP(f, q, sr); else b.setAP(f, q, sr);
    b.z1 = z1; b.z2 = z2;
}

void Engine::recomputeCrossovers() {
    const double q = 0.70710678;
    float nyq = sr_ * 0.45f;
    for (int j = 0; j < MAX_SRC - 1; ++j) {
        double f = clampf(xover_[j], 20.f, nyq);
        for (int c = 0; c < 2; ++c) {
            for (int s = 0; s < 2; ++s) { keepSet(xlp_[c][j][s], 0, f, q, sr_); keepSet(xhp_[c][j][s], 1, f, q, sr_); }
            for (int b = 0; b < MAX_SRC; ++b) keepSet(xap_[c][b][j], 2, f, q, sr_);
        }
        keepSet(bassAp_[j], 2, f, q, sr_);
    }
}

void Engine::recomputeBass() {
    bassF_ = clampf(set_[S_BASSFREQ], 20.f, 500.f);
    for (int i = 0; i < NUM_IN; ++i)
        for (int s = 0; s < 2; ++s) {
            keepSet(bassHp_[i][0][s], 1, bassF_, 0.70710678, sr_);
            keepSet(bassHp_[i][1][s], 1, bassF_, 0.70710678, sr_);
            keepSet(bassLp_[i][s], 0, bassF_, 0.70710678, sr_);
        }
}

void Engine::resetBandFilters() {
    for (auto& ch : xlp_) for (auto& j : ch) for (auto& s : j) s.reset();
    for (auto& ch : xhp_) for (auto& j : ch) for (auto& s : j) s.reset();
    for (auto& ch : xap_) for (auto& b : ch) for (auto& s : b) s.reset();
}

// Spherical head model (Brown & Duda 1998): ITD + head shadow + pinna echoes.
void Engine::recomputeBinaural() {
    const float a = 0.0875f, c = 343.f;
    const float w0 = c / a;
    const float K = 2.f * sr_;
    const float rho[5] = {0.5f, -1.f, 0.5f, -0.25f, 0.25f};
    const float A[5] = {1, 5, 5, 5, 5};
    const float B[5] = {2, 4, 7, 11, 13};
    const float Dk[5] = {1.f, 0.5f, 0.5f, 0.5f, 0.5f};
    const float alphaMin = 0.1f, thetaMin = (float)(150.0 * PI / 180.0);
    const float srScale = sr_ / 44100.f;
    for (int v = 0; v < BIN_V; ++v) {
        float x = (float)binDirs_[v][0], y = (float)binDirs_[v][1], z = (float)binDirs_[v][2];
        float az = rad2deg(std::atan2(y, x));
        float el = rad2deg(std::asin(clampf(z, -1, 1)));
        rearHf_[v] = 1.f - 0.45f * std::max(0.f, -x);
        for (int e = 0; e < 2; ++e) {
            float earY = e == 0 ? 1.f : -1.f;
            float th = std::acos(clampf(y * earY, -1, 1));
            float itd = th < (float)(PI / 2) ? (a / c) * (1 - std::cos(th)) : (a / c) * (1 + th - (float)(PI / 2));
            float itdS = itd * sr_ + 1.f;
            float alpha = (1 + alphaMin / 2) + (1 - alphaMin / 2) * std::cos(th / thetaMin * (float)PI);
            OnePole& f = shadow_[v][e];
            float den = 2 * w0 + K;
            f.b0 = (2 * w0 + alpha * K) / den;
            f.b1 = (2 * w0 - alpha * K) / den;
            f.a1 = (2 * w0 - K) / den;
            float azEar = clampf(e == 0 ? az : -az, -90.f, 90.f);
            tapGain_[v][e][0] = 1.f;
            tapDelay_[v][e][0] = itdS;
            for (int k = 0; k < 5; ++k) {
                float tau = A[k] * std::cos(deg2rad(azEar) * 0.5f) * std::sin(deg2rad(Dk[k] * (90.f - el))) + B[k];
                tapGain_[v][e][k + 1] = rho[k] * 0.5f;
                tapDelay_[v][e][k + 1] = itdS + std::max(1.f, tau * srScale);
            }
        }
    }
    rearCoef_ = std::exp(-2.f * (float)PI * 4000.f / sr_);
}

// ------------------------------------------------------------------ commands

void Engine::handle(const Command& c) {
    switch (c.type) {
        case C_SRC:
            if (c.p < 0 || c.p >= NUM_SP) break;
            if (c.a >= 0 && c.a < MAX_SRC) base_[c.a][c.p] = c.x;
            else if (c.a == TARGET_ALL) for (auto& b : base_) b[c.p] = c.x;
            break;
        case C_SRCMODE:
            if (c.a >= 0 && c.a < MAX_SRC) {
                smode_[c.a] = std::clamp(c.b, 0, 1);
                mtype_[c.a] = std::clamp(c.p, 0, MT_NUM - 1);
            }
            break;
        case C_MUTE:
            if (c.a >= 0 && c.a < MAX_SRC) mute_[c.a] = c.x > 0.5f;
            break;
        case C_GLOBAL:
            if (c.p >= 0 && c.p < NUM_GP) gbase_[c.p] = c.x;
            break;
        case C_LFO:
            if (c.a < 0 || c.a >= NUM_LFO) break;
            switch (c.p) {
                case L_SHAPE: lfo_[c.a].shape = std::clamp((int)c.x, 0, LFO_NUM_SHAPES - 1); break;
                case L_RATE: lfo_[c.a].rate = c.x; break;
                case L_PHASE: lfo_[c.a].phase = c.x; break;
                case L_SYNC: lfo_[c.a].sync = c.x > 0.5f; break;
            }
            break;
        case C_LFO_RESET: {
            double b = meters.beat.load();
            if (c.a >= 0 && c.a < NUM_LFO) lfo_[c.a].reset(b);
            else if (c.a < 0) for (auto& l : lfo_) l.reset(b);
            break;
        }
        case C_MOD:
            if (c.a >= 0 && c.a < NUM_MOD) {
                ModSlot& m = mods_[c.a];
                m.on = c.b >= 0 && c.b < NUM_MODSRC;
                m.src = std::max(0, c.b);
                m.target = (int)c.y;
                m.param = c.p;
                m.amount = c.x;
            }
            break;
        case C_MOD_CLEAR:
            for (auto& m : mods_) m.on = false;
            break;
        case C_PULSE: {
            if (c.a == TARGET_GLOBAL) {
                if (c.p >= 0 && c.p < NUM_GP) { pulseG_[c.p] += c.x; decayG_[c.p] = std::max(0.005f, c.y); }
                break;
            }
            int t0 = c.a, t1 = c.a;
            if (c.a == TARGET_ALL) { t0 = 0; t1 = MAX_SRC - 1; }
            for (int t = t0; t <= t1; ++t) {
                if (t < 0 || t >= MAX_SRC || c.p < 0 || c.p >= NUM_SP) continue;
                pulseS_[t][c.p] += c.x;
                decayS_[t][c.p] = std::max(0.005f, c.y);
            }
            break;
        }
        case C_BANDCOUNT: {
            int nb = std::clamp(c.a, 1, MAX_SRC);
            if (nb != nbands_) { nbands_ = nb; resetBandFilters(); }
            break;
        }
        case C_XOVER:
            if (c.a >= 0 && c.a < MAX_SRC - 1) { xover_[c.a] = c.x; recomputeCrossovers(); }
            break;
        case C_SET:
            if (c.p >= 0 && c.p < NUM_SET) {
                set_[c.p] = c.x;
                if (c.p == S_BASSFREQ) recomputeBass();
            }
            break;
        case C_TEMPO:
            tempo_ = clampf(c.x, 20.f, 999.f);
            if (clockLink_.load()) { pendingLinkTempo_ = true; linkTempoReq_ = tempo_; }
            break;
    }
}

// ------------------------------------------------------------------ geometry

Vec3 Engine::transformDir(Vec3 v, const float* g) const {
    float a = clampf(g[G_FOCUS], -0.95f, 0.95f);
    if (std::fabs(a) > 1e-4f) {
        Vec3 fd = dirFromAzEl(g[G_FAZ], g[G_FEL]);
        float ct = clampf(v.x * fd.x + v.y * fd.y + v.z * fd.z, -1, 1);
        float th = std::acos(ct);
        if (th > 1e-4f && th < (float)PI - 1e-4f) {
            float th2 = 2.f * std::atan(std::tan(th * 0.5f) * (1 - a) / (1 + a));
            Vec3 u{v.x - ct * fd.x, v.y - ct * fd.y, v.z - ct * fd.z};
            float ln = std::sqrt(u.x * u.x + u.y * u.y + u.z * u.z);
            if (ln > 1e-6f) {
                u.x /= ln; u.y /= ln; u.z /= ln;
                float c2 = std::cos(th2), s2 = std::sin(th2);
                v = {c2 * fd.x + s2 * u.x, c2 * fd.y + s2 * u.y, c2 * fd.z + s2 * u.z};
            }
        }
    }
    float r = deg2rad(g[G_ROLL]), p = deg2rad(g[G_PITCH]), yw = deg2rad(g[G_YAW]);
    if (r != 0) { float c = std::cos(r), s = std::sin(r); v = {v.x, c * v.y - s * v.z, s * v.y + c * v.z}; }
    if (p != 0) { float c = std::cos(p), s = std::sin(p); v = {c * v.x - s * v.z, v.y, s * v.x + c * v.z}; }
    if (yw != 0) { float c = std::cos(yw), s = std::sin(yw); v = {c * v.x - s * v.y, s * v.x + c * v.y, v.z}; }
    return v;
}

static inline void vecToAzEl(const Vec3& v, float& az, float& el) {
    az = rad2deg(std::atan2(v.y, v.x));
    el = rad2deg(std::asin(clampf(v.z, -1, 1)));
}

// Rotates hoa_ for a listener whose head is turned by (yaw, pitch): the head-relative field
// f'(u) = f(R u). Matrix by exact quadrature (4 Gauss-Legendre nodes in z x 8 azimuths is
// exact for products of order-3 harmonics), independent of the SH normalisation:
//   M[k][k'] = sum_j w_j Y_k(d_j) Y_k'(R d_j) / sum_j w_j Y_k(d_j)^2
// Ramped from the previous block's matrix; skipped while both are identity.
void Engine::rotateField(int n) {
    const float yaw = deg2rad(set_[S_LYAW]), pitch = deg2rad(clampf(set_[S_LPITCH], -90, 90));
    const bool want = std::fabs(yaw) > 1e-5f || std::fabs(pitch) > 1e-5f;
    if (!want && !rotActive_) return;
    float M[HOA_N][HOA_N] = {};
    if (want) {
        static const float gz[4] = {-0.8611363116f, -0.3399810436f, 0.3399810436f, 0.8611363116f};
        static const float gw[4] = {0.3478548451f, 0.6521451549f, 0.6521451549f, 0.3478548451f};
        const float cy = std::cos(yaw), sy = std::sin(yaw), cp = std::cos(pitch), sp = std::sin(pitch);
        float G[HOA_N] = {};
        for (int iz = 0; iz < 4; ++iz) {
            const float z = gz[iz], rxy = std::sqrt(1.f - z * z);
            for (int ia = 0; ia < 8; ++ia) {
                const float a = (float)PI * 2.f * ia / 8.f;
                const Vec3 d{rxy * std::cos(a), rxy * std::sin(a), z};
                // head -> world: pitch about y (look up = +), then yaw about z (turn left = +)
                const Vec3 p{cp * d.x - sp * d.z, d.y, sp * d.x + cp * d.z};
                const Vec3 r{cy * p.x - sy * p.y, sy * p.x + cy * p.y, p.z};
                float Yd[HOA_N], Yr[HOA_N];
                sh3<float>(d.x, d.y, d.z, Yd);
                sh3<float>(r.x, r.y, r.z, Yr);
                const float w = gw[iz];
                for (int k = 0; k < HOA_N; ++k) {
                    G[k] += w * Yd[k] * Yd[k];
                    const int lk = acnDegree(k);
                    for (int k2 = lk * lk; k2 < (lk + 1) * (lk + 1); ++k2) M[k][k2] += w * Yd[k] * Yr[k2];
                }
            }
        }
        for (int k = 0; k < HOA_N; ++k)
            for (int k2 = 0; k2 < HOA_N; ++k2) M[k][k2] /= std::max(G[k], 1e-9f);
    } else {
        for (int k = 0; k < HOA_N; ++k) M[k][k] = 1.f;
    }
    const float invN = 1.f / n;
    for (int k = 0; k < HOA_N; ++k) {
        float* o = rotHoa_[k].data();
        std::memset(o, 0, n * sizeof(float));
        const int lk = acnDegree(k);
        for (int k2 = lk * lk; k2 < (lk + 1) * (lk + 1); ++k2) {   // rotations never mix degrees
            float c0 = rotPrev_[k][k2], c1 = M[k][k2];
            if (std::fabs(c0) + std::fabs(c1) < 1e-9f) continue;
            const float dc = (c1 - c0) * invN;
            const float* h = hoa_[k2].data();
            for (int i = 0; i < n; ++i) { o[i] += c0 * h[i]; c0 += dc; }
        }
    }
    for (int k = 0; k < HOA_N; ++k) {
        std::swap(hoa_[k], rotHoa_[k]);
        for (int k2 = 0; k2 < HOA_N; ++k2) rotPrev_[k][k2] = M[k][k2];
    }
    rotActive_ = want;
}

// 4-point Hermite read at fractional delay d (samples) behind write position w
static inline float dopRead(const float* buf, int w, float d, int mask) {
    const int di = (int)d;
    const float t = d - di;
    const int i0 = w - di;
    const float xm1 = buf[(i0 + 1) & mask], x0 = buf[i0 & mask], x1 = buf[(i0 - 1) & mask], x2 = buf[(i0 - 2) & mask];
    const float c1 = 0.5f * (x1 - xm1), c2 = xm1 - 2.5f * x0 + 2.f * x1 - 0.5f * x2;
    const float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

// Doppler: the source is heard through a delay of (distance x metres-per-unit / 343 m/s);
// a changing distance changes the delay and therefore the pitch, like the real thing.
// The delay glides at most +-0.5 sample per sample (pitch 0.5x..1.5x) so jumps (preset,
// teleport) glide instead of clicking; switching on/off crossfades with the dry signal.
// The input is always written to the ring so switching on has history to read from.
void Engine::dopplerSource(int s, int n, float dist, float metres, const float*& L, const float*& R) {
    const int mask = DOP_LEN - 1;
    float* bl = dopBuf_[s][0].data();
    float* br = dopBuf_[s][1].data();
    for (int i = 0; i < n; ++i) {
        const int w = (dopW_ + i) & mask;
        bl[w] = L[i]; br[w] = R[i];
    }
    const float m = clampf(metres, 0.f, 200.f);
    const bool want = m > 0.01f;
    if (!want && !dopOn_[s]) return;
    const float maxD = float(DOP_LEN - 8);
    float target = std::min(maxD, std::max(0.f, dist) * m / 343.f * sr_);
    float d0 = dopPrev_[s];
    float fadeIn = 1.f, fadeOut = 1.f;   // wet gain at block start / end
    if (want && !dopOn_[s]) { d0 = target; fadeIn = 0.f; }          // switch on: fade dry -> wet
    if (!want) { target = d0; fadeOut = 0.f; }                      // switch off: fade wet -> dry
    const float maxStep = 0.5f * n;
    const float d1 = std::clamp(target, d0 - maxStep, d0 + maxStep);
    const float invN = 1.f / n;
    for (int i = 0; i < n; ++i) {
        const float k = (i + 1) * invN;
        const float d = std::max(1.f, d0 + (d1 - d0) * k);
        const int w = (dopW_ + i) & mask;
        const float wet = fadeIn + (fadeOut - fadeIn) * k;
        dopL_[i] = L[i] + wet * (dopRead(bl, w, d, mask) - L[i]);
        dopR_[i] = R[i] + wet * (dopRead(br, w, d, mask) - R[i]);
    }
    dopPrev_[s] = want ? d1 : 0.f;
    dopOn_[s] = want;
    L = dopL_.data();
    R = dopR_.data();
}

void Engine::splitBands(int n, const float* L, const float* R) {
    const int nb = nbands_;
    for (int c = 0; c < 2; ++c) {
        const float* x = c == 0 ? L : R;
        std::vector<float>* dst = c == 0 ? srcL_ : srcR_;
        if (nb == 1) { std::memcpy(dst[0].data(), x, n * sizeof(float)); continue; }
        std::memcpy(rest_.data(), x, n * sizeof(float));
        for (int j = 0; j < nb - 1; ++j) {
            Biquad &l1 = xlp_[c][j][0], &l2 = xlp_[c][j][1], &h1 = xhp_[c][j][0], &h2 = xhp_[c][j][1];
            float* lo = dst[j].data();
            float* r = rest_.data();
            for (int i = 0; i < n; ++i) {
                float v = r[i];
                lo[i] = l2.process(l1.process(v));
                r[i] = h2.process(h1.process(v));
            }
        }
        std::memcpy(dst[nb - 1].data(), rest_.data(), n * sizeof(float));
        // phase alignment: band j gets the allpass of every later crossover
        for (int j = 0; j < nb - 2; ++j) {
            float* b = dst[j].data();
            for (int k = j + 1; k < nb - 1; ++k) {
                Biquad& ap = xap_[c][j][k];
                for (int i = 0; i < n; ++i) b[i] = ap.process(b[i]);
            }
        }
    }
}

// ------------------------------------------------------------------ plane-wave effects
// HOA -> 24 plane waves -> per-direction processing -> HOA (abclib projector/recomposer idea)

void Engine::processEffects(int n, const float* g, double beatsPerSec) {
    const float rmMix = clampf(g[G_RM_MIX], 0, 1);
    const float amDepth = clampf(g[G_AM_DEPTH], 0, 1);
    const float crMix = clampf(g[G_CR_MIX], 0, 1);
    const float dfMix = clampf(g[G_DF_MIX], 0, 1);
    const float dlMix = clampf(g[G_DL_MIX], 0, 1);
    const float rvMix = clampf(g[G_RV_MIX], 0, 1);
    const bool active = rmMix > 1e-3f || amDepth > 1e-3f || crMix > 1e-3f || dfMix > 1e-3f || dlMix > 1e-3f || rvMix > 1e-3f;
    bool amFading = false;
    for (float a : amPrev_) if (a != 1.f) amFading = true;
    if (!active && !amFading) {
        if (fxActive_) {  // effects just switched off: clear tails so they don't resurface later
            std::fill(fxDl_.begin(), fxDl_.end(), 0.f);
            std::fill(rvDl_.begin(), rvDl_.end(), 0.f);
            std::fill(dfDl_.begin(), dfDl_.end(), 0.f);
            fxActive_ = false;
        }
        return;
    }
    fxActive_ = true;

    for (int v = 0; v < PW_V; ++v) {
        float* x = pwBuf_[v].data();
        std::memset(x, 0, n * sizeof(float));
        const float* row = &pwDec_[v * HOA_N];
        for (int k = 0; k < HOA_N; ++k) {
            float d = row[k];
            const float* h = hoa_[k].data();
            for (int i = 0; i < n; ++i) x[i] += d * h[i];
        }
    }

    const float invN = 1.f / n;
    const int rmModel = std::clamp((int)set_[S_RMMODEL], 0, 3);
    const double rmF = std::max(0.f, g[G_RM_FREQ]);
    const float rmSpread = g[G_RM_SPREAD];
    const Vec3 amDir = dirFromAzEl(g[G_AM_AZ], g[G_AM_EL]);
    const float amSharp = clampf(g[G_AM_SHARP], 0.5f, 32.f);
    const float crRate = clampf(g[G_CR_RATE], 20.f, sr_);
    const float crLevels = std::pow(2.f, clampf(g[G_CR_BITS], 1.f, 16.f) - 1.f);
    const float crSpread = clampf(g[G_CR_SPREAD], 0.f, 3.f);
    const float dfScale = (0.25f + 1.75f * clampf(g[G_DF_SIZE], 0, 1)) * sr_ / 48000.f;
    static const float dfBase[3] = {113.f, 337.f, 541.f};
    float dlT = std::max(0.f, g[G_DL_TIME]);
    if (set_[S_DLSYNC] > 0.5f) dlT = float(dlT / std::max(0.1, beatsPerSec));  // beats -> seconds
    dlTimeSm_ += (dlT - dlTimeSm_) * 0.25f;
    const float dlFb = clampf(g[G_DL_FB], 0.f, 0.97f);
    const float dlSpread = clampf(g[G_DL_SPREAD], 0.f, 1.f);
    const float rvSize = clampf(g[G_RV_SIZE], 0, 1);
    const float rvFb = 0.72f + 0.26f * rvSize;
    const float rvDamp = clampf(g[G_RV_DAMP], 0, 0.99f);
    const float rvRot = clampf(g[G_RV_ROT], 0, 1);
    const float rvScale = (0.5f + 1.5f * rvSize) * sr_ / 48000.f;
    static const float rvBase[2] = {1423.f, 1877.f};
    const double w0 = 2 * PI * rmF / sr_;

    for (int v = 0; v < PW_V; ++v) {
        float* x = pwBuf_[v].data();
        const float vx = (float)pwDirs_[v][0], vy = (float)pwDirs_[v][1], vz = (float)pwDirs_[v][2];
        const float h = pwHash_[v];

        // ring modulator: carrier phase / frequency depends on the direction
        if (rmMix > 1e-3f) {
            double ph, w = w0;
            const float az = std::atan2(vy, vx), el = std::asin(clampf(vz, -1, 1));
            switch (rmModel) {
                case 0: ph = rmPhase0_; break;                                      // classic
                case 1: ph = rmPhase0_ + rmSpread * az; break;                      // rotating
                case 2: ph = rmPhase0_ + rmSpread * 2.0 * el; break;                // vertical
                default: w = w0 * std::pow(2.0, rmSpread * 0.5 * vx); ph = rmPhase_[v]; break;  // freq field
            }
            float cr = (float)std::cos(ph), ci = (float)std::sin(ph);
            const float wr = (float)std::cos(w), wi = (float)std::sin(w);
            for (int i = 0; i < n; ++i) {
                x[i] *= 1.f - rmMix + rmMix * cr;
                float t = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = t;
            }
            if (rmModel == 3) rmPhase_[v] = std::fmod(rmPhase_[v] + w * n, 2 * PI);
        }
        // spatial tremolo: gain lobe pointing at (am_az, am_el)
        if (amDepth > 1e-3f || amPrev_[v] != 1.f) {
            float dot = vx * amDir.x + vy * amDir.y + vz * amDir.z;
            float tgt = (1.f - amDepth) + amDepth * std::pow(0.5f * (1.f + dot), amSharp);
            if (amDepth <= 1e-3f) tgt = 1.f;
            float gcur = amPrev_[v], dg = (tgt - gcur) * invN;
            for (int i = 0; i < n; ++i) { x[i] *= gcur; gcur += dg; }
            amPrev_[v] = tgt;
        }
        // decimator / bitcrusher, rate spread per direction
        if (crMix > 1e-3f) {
            const float inc = crRate * std::pow(2.f, crSpread * h) / sr_;
            float ph = crPhase_[v], hold = crHold_[v];
            for (int i = 0; i < n; ++i) {
                ph += inc;
                if (ph >= 1.f) { ph -= std::floor(ph); hold = std::round(x[i] * crLevels) / crLevels; }
                x[i] += crMix * (hold - x[i]);
            }
            crPhase_[v] = ph; crHold_[v] = hold;
        }
        // diffuser: 3 allpasses in series per direction (different lengths per direction), which
        // decorrelates the field. The dry / diffused balance is set once, after the whole chain,
        // with an equal-power crossfade. (Mixing dry and wet inside each allpass stage cancels:
        // an allpass has a direct path in opposite phase, so mix 0.5 lost about 20 dB.)
        if (dfMix > 1e-3f) {
            float* wet = tmp_.data();
            std::memcpy(wet, x, n * sizeof(float));
            for (int a = 0; a < 3; ++a) {
                float* dl = &dfDl_[((size_t)v * 3 + a) * DF_DL];
                int len = std::clamp((int)(dfBase[a] * dfScale * (1.f + 0.3f * h)), 2, DF_DL - 1);
                const float gA = 0.62f;
                int w = dfW_;
                for (int i = 0; i < n; ++i, ++w) {
                    float d = dl[(w - len) & (DF_DL - 1)];
                    float in = wet[i] + gA * d;
                    dl[w & (DF_DL - 1)] = in;
                    wet[i] = d - gA * in;
                }
            }
            // decorrelated directions add up in power, not in amplitude, when re-encoded:
            // about -1.7 dB on average, made up here
            const float gDry = std::cos(dfMix * 1.5707963f);
            const float gWet = std::sin(dfMix * 1.5707963f) * 1.22f;
            for (int i = 0; i < n; ++i) x[i] = gDry * x[i] + gWet * wet[i];
        }
        // spatial delay: feedback comes from the opposite direction (ping-pong through the centre)
        if (dlMix > 1e-3f) {
            float* dl = &fxDl_[(size_t)v * FX_DL];
            const float* dlo = &fxDl_[(size_t)pwOpp_[v] * FX_DL];
            int d = std::clamp((int)(dlTimeSm_ * (1.f + dlSpread * 0.5f * h) * sr_), n, FX_DL - 1);
            int w = fxW_;
            for (int i = 0; i < n; ++i, ++w) {
                float own = dl[(w - d) & (FX_DL - 1)];
                float opp = dlo[(w - d) & (FX_DL - 1)];
                dl[w & (FX_DL - 1)] = x[i] + dlFb * opp;
                x[i] += dlMix * own;
            }
        }
        // diffuse reverb: 2 damped combs per direction, rot = feedback leaks to the neighbour direction
        if (rvMix > 1e-3f) {
            const int vn = (v + 1) % PW_V;
            float* wet = tmp_.data();
            std::memset(wet, 0, n * sizeof(float));
            for (int ci = 0; ci < 2; ++ci) {
                float* dl = &rvDl_[((size_t)v * 2 + ci) * RV_DL];
                const float* dln = &rvDl_[((size_t)vn * 2 + ci) * RV_DL];
                int len = std::clamp((int)(rvBase[ci] * rvScale * (1.f + 0.25f * h)), n, RV_DL - 1);
                float lp = rvLp_[v][ci];
                int w = rvW_;
                for (int i = 0; i < n; ++i, ++w) {
                    float own = dl[(w - len) & (RV_DL - 1)];
                    float nb = dln[(w - len) & (RV_DL - 1)];
                    float fb = own + rvRot * (nb - own);
                    lp = fb + rvDamp * (lp - fb);
                    dl[w & (RV_DL - 1)] = x[i] * 0.5f + rvFb * lp;
                    wet[i] += own;
                }
                rvLp_[v][ci] = lp;
            }
            for (int i = 0; i < n; ++i) x[i] += rvMix * 0.35f * wet[i];
        }
    }
    rmPhase0_ = std::fmod(rmPhase0_ + w0 * n, 2 * PI);
    dfW_ = (dfW_ + n) & (DF_DL - 1);
    fxW_ = (fxW_ + n) & (FX_DL - 1);
    rvW_ = (rvW_ + n) & (RV_DL - 1);

    for (int k = 0; k < HOA_N; ++k) {
        float* hk = hoa_[k].data();
        std::memset(hk, 0, n * sizeof(float));
        const float* row = &pwEnc_[k * PW_V];
        for (int v = 0; v < PW_V; ++v) {
            float e = row[v];
            const float* x = pwBuf_[v].data();
            for (int i = 0; i < n; ++i) hk[i] += e * x[i];
        }
    }
}

// ------------------------------------------------------------------ processing

int Engine::process(jack_nframes_t nframes) {
    AMBI_FTZ();
    const int n = std::min((int)nframes, MAX_BLOCK);
    if (int nsr = pendingSr_.exchange(0)) recomputeSr((float)nsr);

    Command cmd;
    while (cmds_.pop(cmd)) handle(cmd);

    DecodeState* ds = decode_.load(std::memory_order_acquire);
    const float dt = n / sr_;
    const float smooth = 1.f - std::exp(-dt / 0.08f);
    const float invN = 1.f / n;

    // ---- clock: Ableton Link (default) or manual
    double beat;
    if (clockLink_.load() && link_) {
        const auto t = link_->clock().micros();
        auto state = link_->captureAudioSessionState();
        if (pendingLinkTempo_) {
            state.setTempo(linkTempoReq_, t);
            link_->commitAudioSessionState(state);
            pendingLinkTempo_ = false;
        }
        tempo_ = state.tempo();
        beat = state.beatAtTime(t, 4.0);
        beat_ = beat;
    } else {
        beat_ += dt * tempo_ / 60.0;
        beat = beat_;
    }
    const double bps = tempo_ / 60.0;
    meters.tempo.store((float)tempo_, std::memory_order_relaxed);
    meters.beat.store((float)beat, std::memory_order_relaxed);

    // ---- modulation sources: LFOs then envelope followers (values of the previous block)
    for (int i = 0; i < NUM_LFO; ++i) {
        lfo_[i].advance(dt, beat, rng_);
        modsrc_[i] = lfo_[i].value();
        meters.lfo[i].store(modsrc_[i], std::memory_order_relaxed);
    }
    for (int e = 0; e < NUM_ENV; ++e) {
        modsrc_[NUM_LFO + e] = lvl01(envState_[e]);
        meters.env[e].store(modsrc_[NUM_LFO + e], std::memory_order_relaxed);
    }

    // ---- effective parameters
    float es[MAX_SRC][NUM_SP];
    float eg[NUM_GP];
    std::memcpy(es, base_, sizeof es);
    std::memcpy(eg, gbase_, sizeof eg);
    for (const ModSlot& m : mods_) {
        if (!m.on) continue;
        float v = modsrc_[m.src] * m.amount;
        if (m.target == TARGET_GLOBAL) { if (m.param >= 0 && m.param < NUM_GP) eg[m.param] += v; }
        else if (m.param >= 0 && m.param < NUM_SP) {
            if (m.target == TARGET_ALL) for (auto& e : es) e[m.param] += v;
            else if (m.target >= 0 && m.target < MAX_SRC) es[m.target][m.param] += v;
        }
    }
    for (int s = 0; s < MAX_SRC; ++s)
        for (int p = 0; p < NUM_SP; ++p) {
            float& pv = pulseS_[s][p];
            if (pv == 0.f) continue;
            es[s][p] += pv;
            pv *= std::exp(-dt / decayS_[s][p]);
            if (std::fabs(pv) < 1e-5f) pv = 0.f;
        }
    for (int p = 0; p < NUM_GP; ++p) {
        float& pv = pulseG_[p];
        if (pv == 0.f) continue;
        eg[p] += pv;
        pv *= std::exp(-dt / decayG_[p]);
        if (std::fabs(pv) < 1e-5f) pv = 0.f;
    }
    eg[G_FWIDER] = clampf(eg[G_FWIDER], 0, 1);

    // ---- input stage: bass split (mono below f) then bands or orbits
    const bool orbitMode = set_[S_MODE] > 0.5f;
    const bool bassOn = set_[S_BASSON] > 0.5f;
    const float ing = set_[S_INPUT];
    const float envA = 1.f - std::exp(-dt / std::max(0.001f, set_[S_ENVATK]));
    const float envR = 1.f - std::exp(-dt / std::max(0.001f, set_[S_ENVREL]));
    auto follow = [&](int idx, float rms) {
        float& e = envState_[idx];
        e += (rms - e) * (rms > e ? envA : envR);
    };
    std::memset(bass_.data(), 0, n * sizeof(float));
    const int nsrc = orbitMode ? NUM_IN : nbands_;
    meters.nsrc.store(nsrc, std::memory_order_relaxed);
    float inAccL = 0, inAccR = 0;
    const int nInputs = orbitMode ? NUM_IN : 1;
    for (int ip = 0; ip < nInputs; ++ip) {
        const float* pl = (const float*)jack_port_get_buffer(inPorts_[2 * ip], nframes);
        const float* pr = (const float*)jack_port_get_buffer(inPorts_[2 * ip + 1], nframes);
        float* L = orbitMode ? srcL_[ip].data() : inL_.data();
        float* R = orbitMode ? srcR_[ip].data() : inR_.data();
        float bg = 1.f;  // in orbits mode the bass follows the orbit's gain / mute
        if (orbitMode) bg = mute_[ip] ? 0.f : dbToLin(clampf(es[ip][P_GAIN], -90, 24));
        float acc = 0, aL = 0, aR = 0;
        for (int i = 0; i < n; ++i) {
            float l = pl[i] * ing, r = pr[i] * ing;
            aL += l * l; aR += r * r;
            acc += 0.5f * (l * l + r * r);
            if (bassOn) {
                float m = 0.70710678f * (l + r);
                bass_[i] += bg * bassLp_[ip][1].process(bassLp_[ip][0].process(m));
                l = bassHp_[ip][1][0].process(bassHp_[ip][0][0].process(l));
                r = bassHp_[ip][1][1].process(bassHp_[ip][0][1].process(r));
            }
            L[i] = l; R[i] = r;
            inAccL += l * l; inAccR += r * r;
        }
        follow(ip, std::sqrt(acc * invN));
        inRms_[2 * ip] += (std::sqrt(aL * invN) - inRms_[2 * ip]) * smooth;
        inRms_[2 * ip + 1] += (std::sqrt(aR * invN) - inRms_[2 * ip + 1]) * smooth;
    }
    for (int ip = nInputs; ip < NUM_IN; ++ip) { follow(ip, 0.f); inRms_[2 * ip] = inRms_[2 * ip + 1] = 0.f; }
    for (int c = 0; c < NUM_IN * 2; ++c) meters.in[c].store(inRms_[c], std::memory_order_relaxed);
    ioRms_[0] += (std::sqrt(inAccL * invN) - ioRms_[0]) * smooth;
    ioRms_[1] += (std::sqrt(inAccR * invN) - ioRms_[1]) * smooth;
    if (!orbitMode) {
        splitBands(n, inL_.data(), inR_.data());
        if (bassOn && nbands_ > 1)
            for (int j = 0; j < nbands_ - 1; ++j) {
                Biquad& ap = bassAp_[j];
                for (int i = 0; i < n; ++i) bass_[i] = ap.process(bass_[i]);
            }
    }

    for (int k = 0; k < HOA_N; ++k) std::memset(hoa_[k].data(), 0, n * sizeof(float));

    // ---- encode sources (L / R images + optional centre point)
    const Vec3 lpos{clampf(set_[S_LX], -50, 50), clampf(set_[S_LY], -50, 50), clampf(set_[S_LZ], -50, 50)};
    const bool listenerMoved = std::fabs(lpos.x) + std::fabs(lpos.y) + std::fabs(lpos.z) > 1e-4f;
    for (int s = 0; s < nsrc; ++s) {
        float* e = es[s];
        jit_[s][0].advance(std::max(0.f, e[P_JRATE]), dt, rng_);
        jit_[s][1].advance(std::max(0.f, e[P_JRATE]) * 0.77, dt, rng_);
        const float az = e[P_AZ] + e[P_JITTER] * jit_[s][0].value();
        const float el = clampf(e[P_EL] + e[P_JITTER] * 0.5f * jit_[s][1].value(), -90, 90);
        const float dist = std::max(0.f, e[P_DIST]);
        const float width = e[P_WIDTH];
        const bool mono = smode_[s] == SM_MONO;
        const float center = mono ? 1.f : clampf(e[P_CENTER], 0, 1);
        const float wider0 = clampf(e[P_WIDER], 0, 1) * eg[G_FWIDER];
        const float wider = wider0 * std::min(1.f, dist);
        const float gdb = dbToLin(clampf(e[P_GAIN], -90, 24));

        Vec3 pL, pR, pC = dirFromAzEl(az, el);
        switch (mtype_[s]) {
            case MT_ELEVATION: pL = dirFromAzEl(az, el + width * 0.5f); pR = dirFromAzEl(az, el - width * 0.5f); break;
            case MT_PLANE: pL = pC; pR = dirFromAzEl(2.f * e[P_MAXIS] - az, el); break;
            case MT_FLOOR: pL = pC; pR = dirFromAzEl(az, -el); break;
            case MT_ANTIPODE: {
                float f = clampf(width / 180.f, 0, 1);
                pL = pC; pR = dirFromAzEl(az + width, el * (1.f - 2.f * f));
                break;
            }
            default: pL = dirFromAzEl(az + width * 0.5f, el); pR = dirFromAzEl(az - width * 0.5f, el); break;
        }
        if (mtype_[s] == MT_PLANE || mtype_[s] == MT_FLOOR || mtype_[s] == MT_ANTIPODE) {
            Vec3 m{pL.x + pR.x, pL.y + pR.y, pL.z + pR.z};
            float ln = std::sqrt(m.x * m.x + m.y * m.y + m.z * m.z);
            if (ln > 1e-3f) pC = {m.x / ln, m.y / ln, m.z / ln};
        }
        pL = transformDir(pL, eg); pR = transformDir(pR, eg); pC = transformDir(pC, eg);
        // listener translation: each image is a point at `dist` along its direction; seen
        // from the listener it gets its own direction and distance (gain, lobe width, air)
        Vec3 pts[3] = {pL, pR, pC};
        float dq[3] = {dist, dist, dist};
        if (listenerMoved) {
            for (int q = 0; q < 3; ++q) {
                Vec3 v{dist * pts[q].x - lpos.x, dist * pts[q].y - lpos.y, dist * pts[q].z - lpos.z};
                float d = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
                if (d > 1e-4f) pts[q] = {v.x / d, v.y / d, v.z / d};
                dq[q] = d;
            }
        }
        const float on3[3] = {mono ? 0.f : 1.f, mono ? 0.f : 1.f, center > 0 ? 1.f : 0.f};
        float tgt[3][HOA_N];
        for (int q = 0; q < 3; ++q) {
            const float wq = wider0 * std::min(1.f, dq[q]);
            float gl[4], esum = 0;
            for (int l = 0; l < 4; ++l) {
                gl[l] = clampf(wq * 3.f - (l - 1), 0, 1);
                esum += (2 * l + 1) * gl[l] * gl[l];
            }
            const float comp = std::pow(16.f / std::max(1.f, esum), 0.25f);
            const float gain = mute_[s] ? 0.f : gdb * (dq[q] > 1.f ? 1.f / dq[q] : 1.f) * 0.70710678f;
            float Y[HOA_N];
            sh3<float>(pts[q].x, pts[q].y, pts[q].z, Y);
            for (int k = 0; k < HOA_N; ++k) tgt[q][k] = on3[q] * Y[k] * gl[acnDegree(k)] * comp * gain;
        }

        // air absorption + M/S centre split:  L' = L - c*M, R' = R - c*M, C = 2c*M
        const float dAir = dq[2];
        float fc = dAir > 1.f ? 20000.f / (1.f + 0.8f * (dAir - 1.f)) : 20000.f;
        fc = clampf(fc, 600.f, sr_ * 0.45f);
        const bool air = fc < 18000.f;
        const float ac = std::exp(-2.f * (float)PI * fc / sr_);
        const float* L = srcL_[s].data();
        const float* R = srcR_[s].data();
        dopplerSource(s, n, dq[2], eg[G_DP_SIZE], L, R);
        float zl = airState_[s][0], zr = airState_[s][1];
        float acc = 0;
        for (int i = 0; i < n; ++i) {
            float l = L[i], r = R[i];
            if (air) { zl = l + ac * (zl - l); zr = r + ac * (zr - r); l = zl; r = zr; }
            float m = 0.5f * (l + r);
            sigL_[i] = l - center * m;
            sigR_[i] = r - center * m;
            sigC_[i] = 2.f * center * m;
            acc += l * l + r * r;
        }
        airState_[s][0] = zl; airState_[s][1] = zr;
        const float rms = std::sqrt(acc * 0.5f * invN);
        srcRms_[s] += (rms - srcRms_[s]) * smooth;
        follow(NUM_IN + s, mute_[s] ? 0.f : rms * gdb);

        const float* sig[3] = {sigL_.data(), sigR_.data(), sigC_.data()};
        for (int q = 0; q < 3; ++q) {
            float* prev = encPrev_[s][q];
            for (int k = 0; k < HOA_N; ++k) {
                float c0 = prev[k], c1 = tgt[q][k];
                if (std::fabs(c0) + std::fabs(c1) < 1e-9f) continue;
                float dc = (c1 - c0) * invN;
                float* h = hoa_[k].data();
                const float* x = sig[q];
                for (int i = 0; i < n; ++i) { h[i] += c0 * x[i]; c0 += dc; }
                prev[k] = c1;
            }
        }

        float caz, cel, laz, lel, raz, rel;
        vecToAzEl(pC, caz, cel); vecToAzEl(pL, laz, lel); vecToAzEl(pR, raz, rel);
        const float tele[SRC_TELE] = {caz, cel, dist, wider, mute_[s] ? 0.f : srcRms_[s] * gdb,
                                      laz, lel, raz, rel, (float)smode_[s]};
        for (int k = 0; k < SRC_TELE; ++k) meters.src[s][k].store(tele[k], std::memory_order_relaxed);
    }
    dopW_ = (dopW_ + n) & (DOP_LEN - 1);
    for (int s = nsrc; s < MAX_SRC; ++s) {
        dopOn_[s] = false; dopPrev_[s] = 0.f;
        for (auto& q : encPrev_[s]) for (auto& c : q) c = 0;
        follow(NUM_IN + s, 0.f);
    }

    // ---- field mirrors / kaleidoscope (SH domain): a = 0 off, 0.5 symmetric, 1 flipped
    {
        float tgt[HOA_N];
        const float a[3] = {clampf(eg[G_MIR_LR], 0, 1), clampf(eg[G_MIR_FB], 0, 1), clampf(eg[G_MIR_UD], 0, 1)};
        bool any = false;
        for (int k = 0; k < HOA_N; ++k) {
            float f = 1.f;
            for (int m = 0; m < 3; ++m) f *= (1.f - a[m]) + a[m] * mirSign_[m][k];
            tgt[k] = f;
            if (f != 1.f || mirPrev_[k] != 1.f) any = true;
        }
        if (any)
            for (int k = 0; k < HOA_N; ++k) {
                float c0 = mirPrev_[k], dc = (tgt[k] - c0) * invN;
                float* h = hoa_[k].data();
                for (int i = 0; i < n; ++i) { h[i] *= c0; c0 += dc; }
                mirPrev_[k] = tgt[k];
            }
    }

    processEffects(n, eg, bps);

    // ---- field meter
    {
        float acc[FIELD_DIRS] = {};
        int cnt = 0;
        for (int i = 0; i < n; i += 2, ++cnt) {
            float h[HOA_N];
            for (int k = 0; k < HOA_N; ++k) h[k] = hoa_[k][i];
            for (int d = 0; d < FIELD_DIRS; ++d) {
                const float* row = &fieldDec_[d * HOA_N];
                float o = 0;
                for (int k = 0; k < HOA_N; ++k) o += row[k] * h[k];
                acc[d] += o * o;
            }
        }
        for (int d = 0; d < FIELD_DIRS; ++d) {
            float v = std::sqrt(acc[d] / std::max(1, cnt));
            fieldRms_[d] += (v - fieldRms_[d]) * smooth;
            meters.field[d].store(fieldRms_[d], std::memory_order_relaxed);
        }
    }

    // ---- listener head rotation: on the speakers too only if asked (on speakers the real
    // head turns by itself), always on the binaural
    const bool rotSpk = set_[S_LROTSPK] > 0.5f;
    if (rotSpk) rotateField(n);

    // ---- speakers (+ mono bass: on the subwoofers if any, else on every speaker)
    const float spkGain = set_[S_MASTER] * set_[S_SPK];
    const float limRel = std::exp(-1.f / (0.15f * sr_));
    if (ds) {
        float* outs[MAX_SPK];
        for (int s = 0; s < ds->nspk; ++s) {
            float* out = (float*)jack_port_get_buffer(ds->ports[s], nframes);
            float* t = tmp_.data();
            const float bg = ds->bassGain[s];
            for (int i = 0; i < n; ++i) t[i] = bg * bass_[i];
            for (int k = 0; k < HOA_N; ++k) {
                float dk = ds->D[s][k];
                if (dk == 0.f) continue;
                const float* h = hoa_[k].data();
                for (int i = 0; i < n; ++i) t[i] += dk * h[i];
            }
            const float g = spkGain * ds->gain[s];
            const int del = ds->delay[s];
            float acc = 0;
            if (del > 0) {
                float* dl = &spkDl_[(size_t)s * SPK_DL];
                for (int i = 0; i < n; ++i) {
                    int w = (spkW_ + i) & (SPK_DL - 1);
                    dl[w] = t[i];
                    float v = dl[(w - del) & (SPK_DL - 1)] * g;
                    out[i] = v; acc += v * v;
                }
            } else {
                for (int i = 0; i < n; ++i) { float v = t[i] * g; out[i] = v; acc += v * v; }
            }
            for (int i = n; i < (int)nframes; ++i) out[i] = 0;
            outs[s] = out;
            spkRms_[s] += (std::sqrt(acc * invN) - spkRms_[s]) * smooth;
            meters.spk[s].store(spkRms_[s], std::memory_order_relaxed);
        }
        spkW_ = (spkW_ + n) & (SPK_DL - 1);
        float minG = 1.f;
        for (int i = 0; i < n; ++i) {
            float pk = 0;
            for (int s = 0; s < ds->nspk; ++s) pk = std::max(pk, std::fabs(outs[s][i]));
            float want = pk * spkLim_ > LIM_CEIL ? LIM_CEIL / pk : 1.f;
            spkLim_ = want < spkLim_ ? want : 1.f - limRel * (1.f - spkLim_);
            if (spkLim_ < 0.9999f) for (int s = 0; s < ds->nspk; ++s) outs[s][i] *= spkLim_;
            minG = std::min(minG, spkLim_);
        }
        meters.lim[0].store(minG, std::memory_order_relaxed);
    }

    if (!rotSpk) rotateField(n);

    // ---- binaural (+ mono bass in both ears)
    float* bL = (float*)jack_port_get_buffer(binPorts_[0], nframes);
    float* bR = (float*)jack_port_get_buffer(binPorts_[1], nframes);
    if (set_[S_BINON] > 0.5f) {
        std::memcpy(bin_[0].data(), bass_.data(), n * sizeof(float));
        std::memcpy(bin_[1].data(), bass_.data(), n * sizeof(float));
        for (int v = 0; v < BIN_V; ++v) {
            float* t = tmp_.data();
            std::memset(t, 0, n * sizeof(float));
            const float* row = &binDec_[v * HOA_N];
            for (int k = 0; k < HOA_N; ++k) {
                float dk = row[k];
                const float* h = hoa_[k].data();
                for (int i = 0; i < n; ++i) t[i] += dk * h[i];
            }
            float* dl = &binDl_[(size_t)v * BIN_DL];
            float lp = rearLp_[v];
            const float hf = rearHf_[v];
            OnePole& f0 = shadow_[v][0];
            OnePole& f1 = shadow_[v][1];
            for (int i = 0; i < n; ++i) {
                float x = t[i];
                lp = x + rearCoef_ * (lp - x);
                x = lp + hf * (x - lp);
                int w = (binW_ + i) & (BIN_DL - 1);
                dl[w] = x;
                for (int e = 0; e < 2; ++e) {
                    float acc = 0;
                    for (int tp = 0; tp < TAPS; ++tp) {
                        float d = tapDelay_[v][e][tp];
                        int di = (int)d;
                        float fr = d - di;
                        float a0 = dl[(w - di) & (BIN_DL - 1)];
                        float a1 = dl[(w - di - 1) & (BIN_DL - 1)];
                        acc += tapGain_[v][e][tp] * (a0 + fr * (a1 - a0));
                    }
                    bin_[e][i] += (e == 0 ? f0 : f1).process(acc);
                }
            }
            rearLp_[v] = lp;
        }
        binW_ = (binW_ + n) & (BIN_DL - 1);
        const float g = set_[S_MASTER] * set_[S_BIN] * 0.5f;  // -6 dB headroom (ITD/pinna peaks)
        float aL = 0, aR = 0, minG = 1.f;
        for (int i = 0; i < n; ++i) {
            float l = bin_[0][i] * g, r = bin_[1][i] * g;
            float pk = std::max(std::fabs(l), std::fabs(r));
            float want = pk * binLim_ > LIM_CEIL ? LIM_CEIL / pk : 1.f;
            binLim_ = want < binLim_ ? want : 1.f - limRel * (1.f - binLim_);
            bL[i] = l * binLim_; bR[i] = r * binLim_;
            minG = std::min(minG, binLim_);
            aL += bL[i] * bL[i]; aR += bR[i] * bR[i];
        }
        meters.lim[1].store(minG, std::memory_order_relaxed);
        ioRms_[2] += (std::sqrt(aL * invN) - ioRms_[2]) * smooth;
        ioRms_[3] += (std::sqrt(aR * invN) - ioRms_[3]) * smooth;
    } else {
        std::memset(bL, 0, n * sizeof(float));
        std::memset(bR, 0, n * sizeof(float));
        ioRms_[2] = ioRms_[3] = 0;
        meters.lim[1].store(1.f, std::memory_order_relaxed);
    }
    for (int i = n; i < (int)nframes; ++i) bL[i] = bR[i] = 0;
    for (int i = 0; i < 4; ++i) meters.io[i].store(ioRms_[i], std::memory_order_relaxed);

    blocks_.fetch_add(1, std::memory_order_release);
    return 0;
}
