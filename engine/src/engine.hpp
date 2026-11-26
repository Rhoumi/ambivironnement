// Real-time spatialisation engine (JACK client).
#pragma once
#include <jack/jack.h>

#include <ableton/Link.hpp>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "decoder.hpp"
#include "dsp.hpp"

constexpr int HOA_N = ambi::HOA_N;
constexpr int MAX_SRC = 16;        // sources: one per band (stereo mode) or one per orbit (orbits mode, 8 used)
constexpr int NUM_IN = 8;          // stereo inputs (16 JACK ports)
constexpr int MAX_SPK = 64;
constexpr int NUM_LFO = 16;
constexpr int NUM_ENV = NUM_IN + MAX_SRC;   // envelope followers: 8 inputs + 16 sources
constexpr int NUM_MODSRC = NUM_LFO + NUM_ENV;
constexpr int NUM_MOD = 64;
constexpr int FIELD_DIRS = 64;
constexpr int MAX_BLOCK = 8192;
constexpr int BIN_V = 36;
constexpr int PW_V = 24;           // plane-wave domain for spatial effects
constexpr int SPK_DL = 16384;
constexpr int BIN_DL = 512;
constexpr int FX_DL = 131072;      // spatial delay line per direction
constexpr int RV_DL = 16384;       // reverb comb per direction
constexpr int DF_DL = 4096;        // diffuser allpass per direction
constexpr int SRC_TELE = 10;
constexpr float LIM_CEIL = 0.97f;

// modulatable per-source parameters
enum SrcParam { P_AZ, P_EL, P_DIST, P_WIDTH, P_GAIN, P_WIDER, P_JITTER, P_JRATE, P_CENTER, P_MAXIS, NUM_SP };
// modulatable global parameters (field transforms + effects)
enum GlobalParam {
    G_YAW, G_PITCH, G_ROLL, G_FOCUS, G_FAZ, G_FEL, G_FWIDER,
    G_MIR_LR, G_MIR_FB, G_MIR_UD,
    G_RM_MIX, G_RM_FREQ, G_RM_SPREAD,
    G_AM_DEPTH, G_AM_AZ, G_AM_EL, G_AM_SHARP,
    G_CR_MIX, G_CR_RATE, G_CR_BITS, G_CR_SPREAD,
    G_DF_MIX, G_DF_SIZE,
    G_DL_MIX, G_DL_TIME, G_DL_FB, G_DL_SPREAD,
    G_RV_MIX, G_RV_SIZE, G_RV_DAMP, G_RV_ROT,
    G_DP_SIZE,   // doppler: metres per distance unit (0 = off)
    NUM_GP
};
// non-modulatable settings
enum SetParam {
    S_MASTER, S_SPK, S_BIN, S_INPUT, S_BINON, S_MODE, S_BASSON, S_BASSFREQ, S_ENVATK, S_ENVREL,
    S_CLOCK, S_RMMODEL, S_DLSYNC,
    // listener pose (first-person mode): position in distance units (x front, y left, z up),
    // head yaw / pitch in degrees, and whether the head rotation also applies to the speakers
    S_LX, S_LY, S_LZ, S_LYAW, S_LPITCH, S_LROTSPK, NUM_SET
};
enum StereoMode { SM_MONO = 0, SM_MIRROR = 1 };
enum MirrorType { MT_AZIMUTH = 0, MT_ELEVATION, MT_PLANE, MT_FLOOR, MT_ANTIPODE, MT_NUM };
enum LfoParam { L_SHAPE, L_RATE, L_PHASE, L_SYNC };
enum CmdType : uint8_t {
    C_SRC, C_SRCMODE, C_MUTE, C_GLOBAL, C_LFO, C_LFO_RESET, C_MOD, C_MOD_CLEAR, C_PULSE,
    C_BANDCOUNT, C_XOVER, C_SET, C_TEMPO
};

constexpr int TARGET_GLOBAL = -1;
constexpr int TARGET_ALL = -2;

struct Command {
    CmdType type = C_SRC;
    int a = 0, b = 0, p = 0;
    float x = 0, y = 0;
};

struct DecodeState {
    int nspk = 0;
    jack_port_t* ports[MAX_SPK] = {};
    float D[MAX_SPK][HOA_N] = {};
    float gain[MAX_SPK] = {};
    int delay[MAX_SPK] = {};
    // per-speaker gain of the mono bass. Without subwoofers every speaker gets an equal
    // share (matching the decoded W pressure); with subwoofers only the subs get it.
    float bassGain[MAX_SPK] = {};
};

struct ModSlot {
    bool on = false;
    int src = 0;     // 0..15 LFO, 16..23 env input, 24..39 env source
    int target = 0;  // source index, TARGET_GLOBAL or TARGET_ALL
    int param = 0;
    float amount = 0;
};

struct Meters {
    std::atomic<float> src[MAX_SRC][SRC_TELE];
    std::atomic<float> spk[MAX_SPK];
    std::atomic<float> field[FIELD_DIRS];
    std::atomic<float> lfo[NUM_LFO];
    std::atomic<float> env[NUM_ENV];
    std::atomic<float> io[4];
    std::atomic<float> in[NUM_IN * 2];  // per input channel RMS (in_1L .. in_8R)
    std::atomic<float> lim[2];
    std::atomic<float> tempo{120.f}, beat{0.f};
    std::atomic<int> nsrc{4};
    Meters();
};

class Engine {
public:
    Engine();
    ~Engine();

    bool open(const std::string& clientName);
    void close();

    // --- control thread API
    bool push(const Command& c) { return cmds_.push(c); }
    void applyLayout(const std::vector<ambi::Speaker>& spk, int type, int optim, int order, bool distComp);
    void connectInputs(const std::string& pattern);
    void connectBinaural(const std::string& pattern);
    void connectSpeakers(const std::string& pattern);
    // speaker i -> output port spkMap[i]-1 among the matched ports (0 / missing = port i)
    void setSpeakerMap(const std::vector<int>& m) { spkMap_ = m; }
    std::vector<std::string> listPorts(bool outputs);
    void setClockLink(bool on);
    int linkPeers() const { return link_ ? (int)link_->numPeers() : 0; }
    bool clockIsLink() const { return clockLink_.load(); }

    jack_client_t* client() const { return client_; }
    Meters meters;
    std::atomic<int> xruns{0};
    std::atomic<bool> shutdown{false};
    std::string decoderInfo;
    int decoderOrder = 3;
    int nspk() const { auto* d = decode_.load(); return d ? d->nspk : 0; }
    float sampleRate() const { return sr_; }
    int bufferSize() const { return bufSize_.load(); }

    int process(jack_nframes_t n);
    void onSampleRate(jack_nframes_t sr) { pendingSr_.store((int)sr); }
    void onBufferSize(jack_nframes_t n) { bufSize_.store((int)n); }

private:
    void handle(const Command& c);
    void recomputeSr(float sr);
    void recomputeCrossovers();
    void recomputeBass();
    void recomputeBinaural();
    void resetBandFilters();
    dsp::Vec3 transformDir(dsp::Vec3 v, const float* g) const;
    void splitBands(int n, const float* L, const float* R);
    void rotateField(int n);
    void dopplerSource(int s, int n, float dist, float metres, const float*& L, const float*& R);
    void processEffects(int n, const float* g, double beatsPerSec);
    void waitBlocks(int count);
    std::string ownPrefix() const;

    jack_client_t* client_ = nullptr;
    jack_port_t* inPorts_[NUM_IN * 2] = {};
    jack_port_t* binPorts_[2] = {};
    std::vector<jack_port_t*> spkPool_;
    std::vector<int> spkMap_;
    std::atomic<DecodeState*> decode_{nullptr};
    std::atomic<uint64_t> blocks_{0};
    std::atomic<int> pendingSr_{0};
    std::atomic<int> bufSize_{0};
    dsp::Spsc<Command, 8192> cmds_;
    std::unique_ptr<ableton::Link> link_;
    std::atomic<bool> clockLink_{true};

    // ---------------- audio-thread state
    float sr_ = 48000.f;
    float base_[MAX_SRC][NUM_SP] = {};
    int smode_[MAX_SRC] = {};
    int mtype_[MAX_SRC] = {};
    bool mute_[MAX_SRC] = {};
    float gbase_[NUM_GP] = {};
    float pulseS_[MAX_SRC][NUM_SP] = {}, decayS_[MAX_SRC][NUM_SP] = {};
    float pulseG_[NUM_GP] = {}, decayG_[NUM_GP] = {};
    float set_[NUM_SET] = {};
    double tempo_ = 120.0;      // manual tempo / last known link tempo
    double beat_ = 0.0;         // manual beat accumulator
    bool pendingLinkTempo_ = false;
    double linkTempoReq_ = 120.0;
    dsp::Lfo lfo_[NUM_LFO];
    float modsrc_[NUM_MODSRC] = {};
    float envState_[NUM_ENV] = {};
    ModSlot mods_[NUM_MOD];
    dsp::Rng rng_{0x1234567u};
    dsp::SmoothRandom jit_[MAX_SRC][2];

    // input stage
    float bassF_ = 80.f;
    dsp::Biquad bassHp_[NUM_IN][2][2], bassLp_[NUM_IN][2];
    dsp::Biquad bassAp_[MAX_SRC - 1];  // stereo (bands) mode: keeps the mono bass in phase with the band split
    int nbands_ = 4;
    float xover_[MAX_SRC - 1] = {};
    dsp::Biquad xlp_[2][MAX_SRC - 1][2], xhp_[2][MAX_SRC - 1][2];
    dsp::Biquad xap_[2][MAX_SRC][MAX_SRC - 1];

    std::vector<float> inL_, inR_, bass_, rest_;
    std::vector<float> srcL_[MAX_SRC], srcR_[MAX_SRC];
    std::vector<float> sigL_, sigR_, sigC_;
    std::vector<float> hoa_[HOA_N];
    std::vector<float> tmp_;
    std::vector<float> rotHoa_[HOA_N];          // head-rotated field (scratch)
    float rotPrev_[HOA_N][HOA_N] = {};           // last head-rotation matrix (ramped per block)
    bool rotActive_ = false;
    std::vector<float> bin_[2];

    float encPrev_[MAX_SRC][3][HOA_N] = {};
    float airState_[MAX_SRC][2] = {};
    // doppler: per-source stereo delay line, delay = distance (from the listener) / c
    static constexpr int DOP_LEN = 1 << 17;      // 2.7 s at 48 kHz
    std::vector<float> dopBuf_[MAX_SRC][2];
    std::vector<float> dopL_, dopR_;
    float dopPrev_[MAX_SRC] = {};                // delay (samples) at the end of the last block
    bool dopOn_[MAX_SRC] = {};
    int dopW_ = 0;
    float srcRms_[MAX_SRC] = {};
    float mirPrev_[HOA_N] = {};
    float mirSign_[3][HOA_N] = {};

    std::vector<float> spkDl_;
    int spkW_ = 0;
    float spkRms_[MAX_SPK] = {};
    float spkLim_ = 1.f, binLim_ = 1.f;

    std::vector<float> fieldDec_;
    float fieldRms_[FIELD_DIRS] = {};
    float ioRms_[4] = {};
    float inRms_[NUM_IN * 2] = {};

    // plane-wave effects
    std::vector<float> pwDec_, pwEnc_;  // PW_V x HOA_N, HOA_N x PW_V
    std::vector<ambi::V3> pwDirs_;
    float pwHash_[PW_V] = {};
    int pwOpp_[PW_V] = {};
    std::vector<float> pwBuf_[PW_V];
    double rmPhase_[PW_V] = {};
    double rmPhase0_ = 0;
    float amPrev_[PW_V] = {};
    float crPhase_[PW_V] = {}, crHold_[PW_V] = {};
    std::vector<float> dfDl_;   // PW_V * 3 * DF_DL
    int dfW_ = 0;
    std::vector<float> fxDl_;   // PW_V * FX_DL
    int fxW_ = 0;
    float dlTimeSm_ = 0.25f;
    std::vector<float> rvDl_;   // PW_V * 2 * RV_DL
    int rvW_ = 0;
    float rvLp_[PW_V][2] = {};
    bool fxActive_ = false;

    // binaural
    std::vector<float> binDec_;
    std::vector<ambi::V3> binDirs_;
    std::vector<float> binDl_;
    int binW_ = 0;
    static constexpr int TAPS = 6;
    float tapGain_[BIN_V][2][TAPS] = {};
    float tapDelay_[BIN_V][2][TAPS] = {};
    dsp::OnePole shadow_[BIN_V][2];
    float rearLp_[BIN_V] = {}, rearCoef_ = 0, rearHf_[BIN_V] = {};
};
