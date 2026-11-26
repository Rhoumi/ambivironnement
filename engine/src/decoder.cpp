#include "decoder.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "dsp.hpp"

namespace ambi {

using dsp::PI;

V3 dirFromAzEl(double azDeg, double elDeg) {
    double az = azDeg * PI / 180.0, el = elDeg * PI / 180.0;
    return {std::cos(el) * std::cos(az), std::cos(el) * std::sin(az), std::sin(el)};
}

std::vector<V3> fibonacciSphere(int n) {
    std::vector<V3> p(n);
    const double ga = PI * (3.0 - std::sqrt(5.0));
    for (int i = 0; i < n; ++i) {
        double z = 1.0 - (i + 0.5) * 2.0 / n;
        double r = std::sqrt(std::max(0.0, 1.0 - z * z));
        double th = ga * i;
        p[i] = {r * std::cos(th), r * std::sin(th), z};
    }
    return p;
}

static void shd(const V3& v, double* Y) { dsp::sh3<double>(v[0], v[1], v[2], Y); }

static double elevationDeg(const V3& v) { return std::asin(std::clamp(v[2], -1.0, 1.0)) * 180.0 / PI; }

static double factorial(int n) {
    double r = 1;
    for (int i = 2; i <= n; ++i) r *= i;
    return r;
}

static double legendre(int l, double x) {
    switch (l) {
        case 0: return 1;
        case 1: return x;
        case 2: return 0.5 * (3 * x * x - 1);
        case 3: return 0.5 * (5 * x * x * x - 3 * x);
        default: return 0;
    }
}

static void optimWeights(int N, bool is2D, int optim, double w[4]) {
    for (int l = 0; l < 4; ++l) {
        if (l > N) { w[l] = 0; continue; }
        switch (optim) {
            case OPT_MAXRE:
                if (is2D) w[l] = std::cos(l * PI / (2.0 * N + 2.0));
                else w[l] = legendre(l, std::cos((137.9 * PI / 180.0) / (N + 1.51)));
                break;
            case OPT_INPHASE:
                if (is2D) w[l] = factorial(N) * factorial(N) / (factorial(N + l) * factorial(N - l));
                else w[l] = factorial(N) * factorial(N + 1) / (factorial(N + l + 1) * factorial(N - l));
                break;
            default: w[l] = 1; break;
        }
    }
}

static std::vector<int> components(int N, bool is2D) {
    std::vector<int> c;
    for (int k = 0; k < (N + 1) * (N + 1); ++k) {
        int l = dsp::acnDegree(k);
        int m = k - l * l - l;
        if (!is2D || std::abs(m) == l) c.push_back(k);
    }
    return c;
}

// SN3D gain of the sectoral (cos) component of degree l at azimuth 0, elevation 0.
static double sectoralNorm(int l) {
    double Y[HOA_N];
    shd({1, 0, 0}, Y);
    return Y[l * l + 2 * l];
}

static bool invert(std::vector<double>& A, int n) {
    std::vector<double> I(n * n, 0.0);
    for (int i = 0; i < n; ++i) I[i * n + i] = 1;
    for (int c = 0; c < n; ++c) {
        int piv = c;
        for (int r = c + 1; r < n; ++r)
            if (std::fabs(A[r * n + c]) > std::fabs(A[piv * n + c])) piv = r;
        if (std::fabs(A[piv * n + c]) < 1e-12) return false;
        if (piv != c)
            for (int k = 0; k < n; ++k) { std::swap(A[c * n + k], A[piv * n + k]); std::swap(I[c * n + k], I[piv * n + k]); }
        double d = A[c * n + c];
        for (int k = 0; k < n; ++k) { A[c * n + k] /= d; I[c * n + k] /= d; }
        for (int r = 0; r < n; ++r) {
            if (r == c) continue;
            double f = A[r * n + c];
            if (f == 0) continue;
            for (int k = 0; k < n; ++k) { A[r * n + k] -= f * A[c * n + k]; I[r * n + k] -= f * I[c * n + k]; }
        }
    }
    A = I;
    return true;
}

static std::vector<double> sampling(const std::vector<V3>& dirs, int N, bool is2D, const double w[4]) {
    const int L = (int)dirs.size();
    std::vector<double> D(L * HOA_N, 0.0);
    auto comps = components(N, is2D);
    for (int s = 0; s < L; ++s) {
        double Y[HOA_N];
        shd(dirs[s], Y);
        for (int k : comps) {
            int l = dsp::acnDegree(k);
            double g;
            if (is2D) g = (k == 0) ? 1.0 : 2.0 * Y[k] / (sectoralNorm(l) * sectoralNorm(l));
            else g = (2 * l + 1) * Y[k];
            D[s * HOA_N + k] = g * w[l] / L;
        }
    }
    return D;
}

static std::vector<double> modeMatching(const std::vector<V3>& dirs, int N, bool is2D, const double w[4]) {
    const int L = (int)dirs.size();
    auto comps = components(N, is2D);
    const int K = (int)comps.size();
    std::vector<double> Y(K * L);
    for (int s = 0; s < L; ++s) {
        double y[HOA_N];
        shd(dirs[s], y);
        for (int i = 0; i < K; ++i) Y[i * L + s] = y[comps[i]];
    }
    std::vector<double> A(K * K, 0.0);
    for (int i = 0; i < K; ++i)
        for (int j = 0; j < K; ++j) {
            double acc = 0;
            for (int s = 0; s < L; ++s) acc += Y[i * L + s] * Y[j * L + s];
            A[i * K + j] = acc;
        }
    double tr = 0;
    for (int i = 0; i < K; ++i) tr += A[i * K + i];
    double lambda = 1e-3 * tr / K;
    for (int i = 0; i < K; ++i) A[i * K + i] += lambda;
    std::vector<double> D(L * HOA_N, 0.0);
    if (!invert(A, K)) return sampling(dirs, N, is2D, w);
    for (int s = 0; s < L; ++s)
        for (int j = 0; j < K; ++j) {
            double acc = 0;
            for (int i = 0; i < K; ++i) acc += Y[i * L + s] * A[i * K + j];
            int k = comps[j];
            D[s * HOA_N + k] = acc * w[dsp::acnDegree(k)];
        }
    return D;
}

// ---------------------------------------------------------------- VBAP

struct Tri { int a, b, c; double inv[9]; };

static bool inv3(const double m[9], double out[9]) {
    double det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
    if (std::fabs(det) < 1e-9) return false;
    double id = 1.0 / det;
    out[0] = (m[4] * m[8] - m[5] * m[7]) * id; out[1] = (m[2] * m[7] - m[1] * m[8]) * id; out[2] = (m[1] * m[5] - m[2] * m[4]) * id;
    out[3] = (m[5] * m[6] - m[3] * m[8]) * id; out[4] = (m[0] * m[8] - m[2] * m[6]) * id; out[5] = (m[2] * m[3] - m[0] * m[5]) * id;
    out[6] = (m[3] * m[7] - m[4] * m[6]) * id; out[7] = (m[1] * m[6] - m[0] * m[7]) * id; out[8] = (m[0] * m[4] - m[1] * m[3]) * id;
    return true;
}

static std::vector<Tri> convexHull(const std::vector<V3>& P) {
    std::vector<Tri> tris;
    const int n = (int)P.size();
    for (int i = 0; i < n; ++i)
        for (int j = i + 1; j < n; ++j)
            for (int k = j + 1; k < n; ++k) {
                V3 u{P[j][0] - P[i][0], P[j][1] - P[i][1], P[j][2] - P[i][2]};
                V3 v{P[k][0] - P[i][0], P[k][1] - P[i][1], P[k][2] - P[i][2]};
                V3 nr{u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]};
                double ln = std::sqrt(nr[0] * nr[0] + nr[1] * nr[1] + nr[2] * nr[2]);
                if (ln < 1e-9) continue;
                // plane through the origin -> unusable for VBAP
                double off = (nr[0] * P[i][0] + nr[1] * P[i][1] + nr[2] * P[i][2]) / ln;
                if (std::fabs(off) < 1e-6) continue;
                int pos = 0, neg = 0;
                for (int m = 0; m < n && !(pos && neg); ++m) {
                    if (m == i || m == j || m == k) continue;
                    double d = (nr[0] * (P[m][0] - P[i][0]) + nr[1] * (P[m][1] - P[i][1]) + nr[2] * (P[m][2] - P[i][2])) / ln;
                    if (d > 1e-7) ++pos;
                    else if (d < -1e-7) ++neg;
                }
                if (pos && neg) continue;
                Tri t{i, j, k, {}};
                double M[9] = {P[i][0], P[i][1], P[i][2], P[j][0], P[j][1], P[j][2], P[k][0], P[k][1], P[k][2]};
                if (!inv3(M, t.inv)) continue;
                tris.push_back(t);
            }
    return tris;
}

// gains (size P) for direction v using triangle set
static void vbap3(const std::vector<V3>& P, const std::vector<Tri>& tris, const V3& v, std::vector<double>& g) {
    std::fill(g.begin(), g.end(), 0.0);
    for (const Tri& t : tris) {
        // g = v * inv(M) where rows of M are speaker vectors
        double g0 = v[0] * t.inv[0] + v[1] * t.inv[3] + v[2] * t.inv[6];
        double g1 = v[0] * t.inv[1] + v[1] * t.inv[4] + v[2] * t.inv[7];
        double g2 = v[0] * t.inv[2] + v[1] * t.inv[5] + v[2] * t.inv[8];
        if (g0 >= -1e-6 && g1 >= -1e-6 && g2 >= -1e-6) {
            g0 = std::max(0.0, g0); g1 = std::max(0.0, g1); g2 = std::max(0.0, g2);
            double nrm = std::sqrt(g0 * g0 + g1 * g1 + g2 * g2);
            if (nrm < 1e-12) continue;
            g[t.a] = g0 / nrm; g[t.b] = g1 / nrm; g[t.c] = g2 / nrm;
            return;
        }
    }
    // fallback: nearest speaker
    int best = 0; double bd = -2;
    for (size_t i = 0; i < P.size(); ++i) {
        double d = P[i][0] * v[0] + P[i][1] * v[1] + P[i][2] * v[2];
        if (d > bd) { bd = d; best = (int)i; }
    }
    g[best] = 1.0;
}

static double maxAzGap(const std::vector<Speaker>& spk, std::vector<int>& order) {
    order.resize(spk.size());
    for (size_t i = 0; i < spk.size(); ++i) order[i] = (int)i;
    auto wrap = [](double a) { a = std::fmod(a, 360.0); return a < 0 ? a + 360 : a; };
    std::sort(order.begin(), order.end(), [&](int a, int b) { return wrap(spk[a].az) < wrap(spk[b].az); });
    double gap = 0;
    for (size_t i = 0; i < order.size(); ++i) {
        double a = wrap(spk[order[i]].az), b = wrap(spk[order[(i + 1) % order.size()]].az);
        double d = b - a;
        if (d <= 0) d += 360;
        gap = std::max(gap, d);
    }
    return gap;
}

static std::vector<double> allrad2D(const std::vector<Speaker>& spkReal, int N, const double w[4], int& imaginary) {
    const int L = (int)spkReal.size();
    auto wrap = [](double a) { a = std::fmod(a, 360.0); return a < 0 ? a + 360 : a; };
    // fill azimuth gaps wider than 100 deg with imaginary speakers; their gains are
    // folded back (at -6 dB each) into the two real speakers bounding the gap.
    std::vector<int> ord;
    maxAzGap(spkReal, ord);
    std::vector<Speaker> spk = spkReal;
    std::vector<std::pair<int, int>> owner;  // for imaginary: bounding real speakers
    imaginary = 0;
    for (size_t i = 0; i < ord.size(); ++i) {
        int a = ord[i], b = ord[(i + 1) % ord.size()];
        double aa = wrap(spkReal[a].az), bb = wrap(spkReal[b].az);
        double gap = bb - aa; if (gap <= 0) gap += 360;
        if (ord.size() == 1) gap = 360;
        int extra = (int)std::ceil(gap / 100.0) - 1;
        for (int e = 1; e <= extra; ++e) {
            Speaker s; s.az = aa + gap * e / (extra + 1); s.el = 0; s.dist = 1;
            spk.push_back(s); owner.push_back({a, b}); ++imaginary;
        }
    }
    maxAzGap(spk, ord);
    const int V = 72;
    std::vector<V3> virt(V);
    for (int i = 0; i < V; ++i) virt[i] = dirFromAzEl(i * 360.0 / V, 0);
    auto Dv = sampling(virt, N, true, w);
    std::vector<double> D(L * HOA_N, 0.0);
    auto add = [&](int s, double g, int v) {
        if (s < L) { for (int k = 0; k < HOA_N; ++k) D[s * HOA_N + k] += g * Dv[v * HOA_N + k]; return; }
        auto [ra, rb] = owner[s - L];
        for (int k = 0; k < HOA_N; ++k) {
            D[ra * HOA_N + k] += 0.5 * g * Dv[v * HOA_N + k];
            D[rb * HOA_N + k] += 0.5 * g * Dv[v * HOA_N + k];
        }
    };
    for (int v = 0; v < V; ++v) {
        double az = v * 360.0 / V;
        for (size_t i = 0; i < ord.size(); ++i) {
            int a = ord[i], b = ord[(i + 1) % ord.size()];
            double aa = wrap(spk[a].az), bb = wrap(spk[b].az);
            double span = bb - aa; if (span <= 0) span += 360;
            double rel = az - aa; if (rel < 0) rel += 360;
            if (rel > span + 1e-9) continue;
            double ta = aa * PI / 180, tb = bb * PI / 180, t = az * PI / 180;
            double m00 = std::cos(ta), m01 = std::sin(ta), m10 = std::cos(tb), m11 = std::sin(tb);
            double det = m00 * m11 - m01 * m10;
            double ga, gb;
            if (std::fabs(det) < 1e-9) { ga = gb = std::sqrt(0.5); }
            else {
                double px = std::cos(t), py = std::sin(t);
                ga = std::max(0.0, (px * m11 - py * m10) / det);
                gb = std::max(0.0, (py * m00 - px * m01) / det);
                double n = std::sqrt(ga * ga + gb * gb);
                if (n > 1e-12) { ga /= n; gb /= n; }
            }
            add(a, ga, v);
            add(b, gb, v);
            break;
        }
    }
    return D;
}

static std::vector<double> allrad3D(const std::vector<Speaker>& spk, int N, const double w[4], int& imaginary) {
    const int L = (int)spk.size();
    std::vector<V3> P;
    double minEl = 90, maxEl = -90;
    for (auto& s : spk) {
        P.push_back(dirFromAzEl(s.az, s.el));
        minEl = std::min(minEl, s.el); maxEl = std::max(maxEl, s.el);
    }
    imaginary = 0;
    std::vector<std::vector<int>> fold;  // real speakers receiving each imaginary speaker
    auto ring = [&](bool low) {
        std::vector<int> r;
        double ref = low ? minEl : maxEl;
        for (int s = 0; s < L; ++s) if (std::fabs(spk[s].el - ref) < 10) r.push_back(s);
        return r;
    };
    if (minEl > -10) { P.push_back({0, 0, -1}); fold.push_back(ring(true)); ++imaginary; }
    if (maxEl < 10) { P.push_back({0, 0, 1}); fold.push_back(ring(false)); ++imaginary; }
    auto tris = convexHull(P);
    auto virt = fibonacciSphere(240);
    auto Dv = sampling(virt, N, false, w);
    std::vector<double> D(L * HOA_N, 0.0), g(P.size());
    for (size_t v = 0; v < virt.size(); ++v) {
        vbap3(P, tris, virt[v], g);
        for (int s = 0; s < L; ++s) {
            if (g[s] == 0) continue;
            for (int k = 0; k < HOA_N; ++k) D[s * HOA_N + k] += g[s] * Dv[v * HOA_N + k];
        }
        for (int im = 0; im < imaginary; ++im) {
            double gi = g[L + im];
            if (gi == 0 || fold[im].empty()) continue;
            double share = 0.5 * gi / std::sqrt((double)fold[im].size());
            for (int s : fold[im])
                for (int k = 0; k < HOA_N; ++k) D[s * HOA_N + k] += share * Dv[v * HOA_N + k];
        }
    }
    return D;
}

// Scale so that mean decoded energy over the covered region is 1.
static void normaliseEnergy(std::vector<double>& D, int L, bool is2D, double minEl, double maxEl) {
    std::vector<V3> test;
    if (is2D) {
        for (int i = 0; i < 180; ++i) test.push_back(dirFromAzEl(i * 2.0, 0));
    } else {
        for (auto& v : fibonacciSphere(600)) {
            double e = elevationDeg(v);
            if (e >= minEl - 15 && e <= maxEl + 15) test.push_back(v);
        }
        if (test.empty()) test = fibonacciSphere(600);
    }
    double acc = 0;
    for (auto& v : test) {
        double Y[HOA_N];
        shd(v, Y);
        for (int s = 0; s < L; ++s) {
            double o = 0;
            for (int k = 0; k < HOA_N; ++k) o += D[s * HOA_N + k] * Y[k];
            acc += o * o;
        }
    }
    double mean = acc / test.size();
    if (mean > 1e-12) {
        double sc = 1.0 / std::sqrt(mean);
        for (auto& d : D) d *= sc;
    }
}

DecoderResult buildDecoder(const std::vector<Speaker>& spk, int type, int optim, int order) {
    DecoderResult r;
    const int L = (int)spk.size();
    if (L == 0) { r.info = "no speakers"; return r; }
    int N = std::clamp(order, 1, 3);
    bool is2D = true;
    double minEl = 90, maxEl = -90;
    for (auto& s : spk) {
        if (std::fabs(s.el) > 5) is2D = false;
        minEl = std::min(minEl, s.el); maxEl = std::max(maxEl, s.el);
    }
    std::vector<V3> dirs;
    for (auto& s : spk) dirs.push_back(dirFromAzEl(s.az, s.el));

    std::vector<double> D;
    char buf[160];
    if (L == 1) {
        D.assign(HOA_N, 0.0); D[0] = 1.0;
        r.order = 0; r.is2D = is2D; r.typeUsed = DEC_SAMPLING; r.info = "mono (omni)";
        r.D.assign(D.begin(), D.end());
        return r;
    }

    int used = type;
    if (type == DEC_ALLRAD && !is2D && L < 4) used = DEC_SAMPLING;
    double w[4];
    if (used == DEC_MODEMATCH || used == DEC_SAMPLING) {
        if (is2D) while (N > 1 && 2 * N + 1 > L) --N;
        else while (N > 1 && (N + 1) * (N + 1) > L) --N;
    }
    optimWeights(N, is2D, optim, w);

    int imaginary = 0;
    switch (used) {
        case DEC_ALLRAD:
            D = is2D ? allrad2D(spk, N, w, imaginary) : allrad3D(spk, N, w, imaginary);
            break;
        case DEC_MODEMATCH: D = modeMatching(dirs, N, is2D, w); break;
        default: D = sampling(dirs, N, is2D, w); used = DEC_SAMPLING; break;
    }
    normaliseEnergy(D, L, is2D, minEl, maxEl);

    static const char* names[] = {"AllRAD", "mode-matching", "sampling"};
    static const char* onames[] = {"basic", "maxRe", "inPhase"};
    std::snprintf(buf, sizeof buf, "%s %s order %d %s %d spk%s", names[used], is2D ? "2D" : "3D", N,
                  onames[std::clamp(optim, 0, 2)], L, imaginary ? " (+imag.)" : "");
    r.info = buf;
    r.order = N; r.is2D = is2D; r.typeUsed = used;
    r.D.assign(D.begin(), D.end());
    return r;
}

std::vector<float> samplingDecoder3D(const std::vector<V3>& dirs, int order, int optim, bool normalise) {
    double w[4];
    optimWeights(order, false, optim, w);
    auto D = sampling(dirs, order, false, w);
    if (normalise) normaliseEnergy(D, (int)dirs.size(), false, -90, 90);
    return std::vector<float>(D.begin(), D.end());
}

}  // namespace ambi
