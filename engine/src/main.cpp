// ambi-engine: JACK spatialiser controlled over OSC (UDP).
//   control in  : 127.0.0.1:<osc-port>   (default 9100)
//   telemetry   : 127.0.0.1:<reply-port> (default 9101)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#if defined(__linux__)
#include <sys/prctl.h>
#endif
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <ctime>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "engine.hpp"
#include "osc.hpp"

static volatile std::sig_atomic_t g_quit = 0;
static void onSignal(int) { g_quit = 1; }

static const std::map<std::string, int> kSrcParams = {
    {"az", P_AZ}, {"el", P_EL}, {"dist", P_DIST}, {"width", P_WIDTH}, {"gain", P_GAIN},
    {"wider", P_WIDER}, {"jitter", P_JITTER}, {"jrate", P_JRATE}, {"center", P_CENTER}, {"maxis", P_MAXIS}};
static const std::map<std::string, int> kGlobalParams = {
    {"yaw", G_YAW}, {"pitch", G_PITCH}, {"roll", G_ROLL}, {"focus", G_FOCUS}, {"faz", G_FAZ}, {"fel", G_FEL},
    {"fwider", G_FWIDER}, {"mir_lr", G_MIR_LR}, {"mir_fb", G_MIR_FB}, {"mir_ud", G_MIR_UD},
    {"rm_mix", G_RM_MIX}, {"rm_freq", G_RM_FREQ}, {"rm_spread", G_RM_SPREAD},
    {"am_depth", G_AM_DEPTH}, {"am_az", G_AM_AZ}, {"am_el", G_AM_EL}, {"am_sharp", G_AM_SHARP},
    {"cr_mix", G_CR_MIX}, {"cr_rate", G_CR_RATE}, {"cr_bits", G_CR_BITS}, {"cr_spread", G_CR_SPREAD},
    {"df_mix", G_DF_MIX}, {"df_size", G_DF_SIZE},
    {"dl_mix", G_DL_MIX}, {"dl_time", G_DL_TIME}, {"dl_fb", G_DL_FB}, {"dl_spread", G_DL_SPREAD},
    {"rv_mix", G_RV_MIX}, {"rv_size", G_RV_SIZE}, {"rv_damp", G_RV_DAMP}, {"rv_rot", G_RV_ROT},
    {"dp_size", G_DP_SIZE}};
static const std::map<std::string, int> kSetParams = {
    {"master", S_MASTER}, {"spk", S_SPK}, {"bin", S_BIN}, {"input", S_INPUT}, {"binon", S_BINON},
    {"mode", S_MODE}, {"basson", S_BASSON}, {"bassfreq", S_BASSFREQ}, {"envatk", S_ENVATK}, {"envrel", S_ENVREL},
    {"clock", S_CLOCK}, {"rmmodel", S_RMMODEL}, {"dlsync", S_DLSYNC},
    {"lx", S_LX}, {"ly", S_LY}, {"lz", S_LZ}, {"lyaw", S_LYAW}, {"lpitch", S_LPITCH}, {"lrotspk", S_LROTSPK}};
static const std::map<std::string, int> kLfoParams = {
    {"shape", L_SHAPE}, {"rate", L_RATE}, {"phase", L_PHASE}, {"sync", L_SYNC}};

static int lookup(const std::map<std::string, int>& m, const std::string& k) {
    auto it = m.find(k);
    return it == m.end() ? -1 : it->second;
}

struct App {
    Engine eng;
    int sock = -1;
    sockaddr_in reply{};
    std::vector<ambi::Speaker> layout;
    std::vector<int> subs;  // per speaker: 1 = subwoofer (set by /spksub, applied at the next relayout)
    int decType = 0, decOptim = 1, decOrder = 3;
    bool distComp = true;
    std::chrono::steady_clock::time_point lastRx = std::chrono::steady_clock::now();

    void send(const osc::Writer& w) {
        auto b = w.bytes();
        sendto(sock, b.data(), b.size(), 0, (sockaddr*)&reply, sizeof reply);
    }

    void sendLayoutInfo() {
        send(osc::Writer("/layout/info").s(eng.decoderInfo).i(eng.decoderOrder).i(eng.nspk()));
    }

    void relayout() {
        for (size_t i = 0; i < layout.size(); ++i) layout[i].sub = i < subs.size() && subs[i] != 0;
        eng.applyLayout(layout, decType, decOptim, decOrder, distComp);
        sendLayoutInfo();
    }

    void handle(const osc::Message& m) {
        const auto& a = m.args;
        const std::string& ad = m.address;
        auto push = [&](Command c) { if (!eng.push(c)) std::fprintf(stderr, "[engine] command queue full\n"); };

        if (ad == "/src" && a.size() >= 3) {
            int p = lookup(kSrcParams, a[1].asString());
            if (p >= 0) push({C_SRC, a[0].asInt(), 0, p, a[2].asFloat(), 0});
        } else if (ad == "/mute" && a.size() >= 2) {
            push({C_MUTE, a[0].asInt(), 0, 0, a[1].asFloat(), 0});
        } else if ((ad == "/global" || ad == "/field") && a.size() >= 2) {
            int p = lookup(kGlobalParams, a[0].asString());
            if (p >= 0) push({C_GLOBAL, 0, 0, p, a[1].asFloat(), 0});
        } else if (ad == "/srcmode" && a.size() >= 3) {
            // src, stereo mode (0 mono sum, 1 mirror), mirror type
            push({C_SRCMODE, a[0].asInt(), a[1].asInt(), a[2].asInt(), 0, 0});
        } else if (ad == "/lfo" && a.size() >= 3) {
            int p = lookup(kLfoParams, a[1].asString());
            if (p >= 0) push({C_LFO, a[0].asInt(), 0, p, a[2].asFloat(), 0});
        } else if (ad == "/lfo/reset") {
            push({C_LFO_RESET, a.empty() ? -1 : a[0].asInt(), 0, 0, 0, 0});
        } else if (ad == "/mod" && a.size() >= 5) {
            // slot source target param amount   (source < 0 disables the slot)
            // source: 0..15 LFO, 16..23 envelope of input 1..8, 24..39 envelope of source 1..16
            int target = a[2].asInt();
            int p = target == TARGET_GLOBAL ? lookup(kGlobalParams, a[3].asString()) : lookup(kSrcParams, a[3].asString());
            int src = p < 0 ? -1 : a[1].asInt();
            push({C_MOD, a[0].asInt(), src, std::max(p, 0), a[4].asFloat(), (float)target});
        } else if (ad == "/mod/clear") {
            push({C_MOD_CLEAR, 0, 0, 0, 0, 0});
        } else if (ad == "/pulse" && a.size() >= 4) {
            int target = a[0].asInt();
            int p = target == TARGET_GLOBAL ? lookup(kGlobalParams, a[1].asString()) : lookup(kSrcParams, a[1].asString());
            if (p >= 0) push({C_PULSE, target, 0, p, a[2].asFloat(), a[3].asFloat()});
        } else if (ad == "/bands/count" && !a.empty()) {
            push({C_BANDCOUNT, a[0].asInt(), 0, 0, 0, 0});
        } else if (ad == "/bands/xover" && a.size() >= 2) {
            push({C_XOVER, a[0].asInt(), 0, 0, a[1].asFloat(), 0});
        } else if (ad == "/set" && a.size() >= 2) {
            int p = lookup(kSetParams, a[0].asString());
            if (p == S_CLOCK) eng.setClockLink(a[1].asFloat() < 0.5f);  // 0 = Ableton Link, 1 = manual
            if (p >= 0) push({C_SET, 0, 0, p, a[1].asFloat(), 0});
        } else if (ad == "/tempo" && !a.empty()) {
            push({C_TEMPO, 0, 0, 0, a[0].asFloat(), 0});
        } else if (ad == "/layout") {
            // n, then az el dist triples
            if (a.empty()) return;
            int n = std::min(a[0].asInt(), MAX_SPK);
            std::vector<ambi::Speaker> spk;
            for (int i = 0; i < n && 1 + i * 3 + 2 < (int)a.size(); ++i) {
                ambi::Speaker s;
                s.az = a[1 + i * 3].asFloat();
                s.el = a[2 + i * 3].asFloat();
                s.dist = a[3 + i * 3].asFloat();
                spk.push_back(s);
            }
            layout = spk;
            relayout();
        } else if (ad == "/decoder" && a.size() >= 3) {
            decType = a[0].asInt(); decOptim = a[1].asInt(); decOrder = a[2].asInt();
            relayout();
        } else if (ad == "/distcomp" && !a.empty()) {
            distComp = a[0].asInt() != 0;
            relayout();
        } else if (ad == "/connect/input" && !a.empty()) {
            eng.connectInputs(a[0].asString());
        } else if (ad == "/connect/binaural") {
            eng.connectBinaural(a.empty() ? "" : a[0].asString());
        } else if (ad == "/connect/speakers") {
            eng.connectSpeakers(a.empty() ? "" : a[0].asString());
        } else if (ad == "/spkmap") {
            // output channel (1-based) per speaker, 0 = in order
            std::vector<int> m;
            for (const auto& v : a) m.push_back(v.asInt());
            eng.setSpeakerMap(m);
        } else if (ad == "/spksub") {
            // subwoofer flag per speaker (1 = sub); send before /layout
            subs.clear();
            for (const auto& v : a) subs.push_back(v.asInt());
            relayout();
        } else if (ad == "/ports") {
            for (int dir = 0; dir < 2; ++dir) {
                osc::Writer w(dir == 0 ? "/ports/out" : "/ports/in");
                for (auto& p : eng.listPorts(dir == 0)) w.s(p);
                send(w);
            }
        } else if (ad == "/ping") {
            send(osc::Writer("/pong"));
        } else if (ad == "/quit") {
            g_quit = 1;
        }
    }

    void telemetry(bool full) {
        const int nb = eng.meters.nsrc.load();
        {
            osc::Writer w("/t/src");
            w.i(nb).i(SRC_TELE);
            for (int b = 0; b < nb; ++b)
                for (int k = 0; k < SRC_TELE; ++k) w.f(eng.meters.src[b][k].load());
            send(w);
        }
        {
            osc::Writer w("/t/spk");
            int ns = eng.nspk();
            for (int s = 0; s < ns; ++s) w.f(eng.meters.spk[s].load());
            send(w);
        }
        {
            osc::Writer w("/t/field");
            for (int d = 0; d < FIELD_DIRS; ++d) w.f(eng.meters.field[d].load());
            send(w);
        }
        {
            osc::Writer w("/t/lfo");
            for (int i = 0; i < NUM_LFO; ++i) w.f(eng.meters.lfo[i].load());
            send(w);
        }
        {
            osc::Writer w("/t/in");
            for (int c = 0; c < NUM_IN * 2; ++c) w.f(eng.meters.in[c].load());
            send(w);
        }
        {
            osc::Writer w("/t/env");
            for (int i = 0; i < NUM_ENV; ++i) w.f(eng.meters.env[i].load());
            send(w);
        }
        send(osc::Writer("/t/clock").f(eng.meters.tempo.load()).f(eng.meters.beat.load())
                 .i(eng.linkPeers()).i(eng.clockIsLink() ? 0 : 1));
        {
            osc::Writer w("/t/io");
            for (int i = 0; i < 4; ++i) w.f(eng.meters.io[i].load());
            w.f(eng.meters.lim[0].load()).f(eng.meters.lim[1].load());
            send(w);
        }
        if (full) {
            send(osc::Writer("/t/status")
                     .i((int)eng.sampleRate()).i(eng.bufferSize())
                     .f(jack_cpu_load(eng.client())).i(eng.xruns.load())
                     .i(eng.nspk()).i(eng.decoderOrder).s(eng.decoderInfo));
        }
    }
};

int main(int argc, char** argv) {
    int oscPort = 9100, replyPort = 9101;
    double watchdog = 0;
    bool autoconnect = true;
    bool parentWatch = false;
    std::string logPath;
    std::string name = "ambivironnement";
    for (int i = 1; i < argc; ++i) {
        std::string k = argv[i];
        auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
        if (k == "--osc-port") oscPort = std::atoi(next().c_str());
        else if (k == "--reply-port") replyPort = std::atoi(next().c_str());
        else if (k == "--name") name = next();
        else if (k == "--watchdog") watchdog = std::atof(next().c_str());
        else if (k == "--no-autoconnect") autoconnect = false;
        else if (k == "--parent-watch") parentWatch = true;
        else if (k == "--log") logPath = next();
        else if (k == "-h" || k == "--help") {
            std::printf("ambi-engine [--osc-port 9100] [--reply-port 9101] [--name ambivironnement] [--watchdog sec] [--parent-watch] [--log file] [--no-autoconnect]\n");
            return 0;
        }
    }
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    if (!logPath.empty()) {
        // keep stdout/stderr in a file so crashes can be diagnosed
        if (std::freopen(logPath.c_str(), "a", stdout)) std::setvbuf(stdout, nullptr, _IOLBF, 0);
        std::freopen(logPath.c_str(), "a", stderr);
        std::time_t t = std::time(nullptr);
        std::printf("\n[engine] ---- start %s", std::ctime(&t));
    }
    pid_t parent = getppid();
    if (parentWatch) {
        // exit when the UI process dies (crash or kill), but never because it is merely frozen.
        // Linux: the kernel signals us at once. Elsewhere (macOS): the main loop below notices
        // that the parent changed within ~33 ms.
#if defined(__linux__)
        prctl(PR_SET_PDEATHSIG, SIGTERM);
#endif
        if (getppid() != parent) return 0;
    }

    static App app;
    app.sock = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(oscPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(app.sock, (sockaddr*)&addr, sizeof addr) < 0) {
        std::perror("[engine] bind");
        std::fprintf(stderr, "[engine] port %d busy: another engine running?\n", oscPort);
        return 1;
    }
    app.reply.sin_family = AF_INET;
    app.reply.sin_port = htons(replyPort);
    app.reply.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (!app.eng.open(name)) return 2;

    // default layout: octagon
    for (int i = 0; i < 8; ++i) app.layout.push_back({22.5 + 45.0 * i, 0, 2});
    app.relayout();
    if (autoconnect) app.eng.connectBinaural("");
    app.send(osc::Writer("/hello"));

    using clock = std::chrono::steady_clock;
    auto nextTele = clock::now();
    int teleCount = 0;
    std::vector<uint8_t> buf(65536);
    std::vector<osc::Message> msgs;

    while (!g_quit && !app.eng.shutdown.load()) {
        auto now = clock::now();
        int timeout = (int)std::chrono::duration_cast<std::chrono::milliseconds>(nextTele - now).count();
        pollfd pfd{app.sock, POLLIN, 0};
        if (poll(&pfd, 1, std::max(0, timeout)) > 0 && (pfd.revents & POLLIN)) {
            ssize_t r;
            while ((r = recv(app.sock, buf.data(), buf.size(), MSG_DONTWAIT)) > 0) {
                msgs.clear();
                osc::parse(buf.data(), (size_t)r, msgs);
                for (auto& m : msgs) app.handle(m);
                app.lastRx = clock::now();
            }
        }
        now = clock::now();
        if (now >= nextTele) {
            app.telemetry(teleCount % 8 == 0);
            ++teleCount;
            nextTele = now + std::chrono::milliseconds(33);
            if (parentWatch && getppid() != parent) {
                std::printf("[engine] parent process gone, exiting\n");
                break;
            }
            if (watchdog > 0 && std::chrono::duration<double>(now - app.lastRx).count() > watchdog) {
                std::printf("[engine] watchdog: no control messages for %.0fs, exiting\n", watchdog);
                break;
            }
        }
    }
    if (app.eng.shutdown.load()) std::printf("[engine] JACK server shut the client down\n");
    app.send(osc::Writer("/bye"));
    app.eng.close();
    close(app.sock);
    std::printf("[engine] bye\n");
    return 0;
}
