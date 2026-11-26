// Small DSP toolbox: biquads, spherical harmonics (ACN / SN3D, order 3), RNG, LFOs.
#pragma once
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace dsp {

constexpr double PI = 3.14159265358979323846;

inline float clampf(float v, float a, float b) { return v < a ? a : (v > b ? b : v); }
inline float deg2rad(float d) { return d * (float)(PI / 180.0); }
inline float rad2deg(float r) { return r * (float)(180.0 / PI); }
inline float dbToLin(float db) { return std::pow(10.f, db * 0.05f); }

// Transposed direct form II biquad (RBJ cookbook designs).
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1 = 0, z2 = 0;
    inline float process(float x) {
        float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void reset() { z1 = z2 = 0; }
    void set(double nb0, double nb1, double nb2, double a0, double na1, double na2) {
        b0 = float(nb0 / a0); b1 = float(nb1 / a0); b2 = float(nb2 / a0);
        a1 = float(na1 / a0); a2 = float(na2 / a0);
    }
    void setLP(double f, double q, double sr) {
        double w = 2 * PI * f / sr, c = std::cos(w), al = std::sin(w) / (2 * q);
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void setHP(double f, double q, double sr) {
        double w = 2 * PI * f / sr, c = std::cos(w), al = std::sin(w) / (2 * q);
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void setAP(double f, double q, double sr) {
        double w = 2 * PI * f / sr, c = std::cos(w), al = std::sin(w) / (2 * q);
        set(1 - al, -2 * c, 1 + al, 1 + al, -2 * c, 1 - al);
    }
};

// First-order section y = b0 x + b1 x1 - a1 y1
struct OnePole {
    float b0 = 1, b1 = 0, a1 = 0, x1 = 0, y1 = 0;
    inline float process(float x) {
        float y = b0 * x + b1 * x1 - a1 * y1;
        x1 = x; y1 = y;
        return y;
    }
    void reset() { x1 = y1 = 0; }
};

// Real spherical harmonics, ACN ordering, SN3D normalisation (AmbiX), order 3.
// x = front, y = left, z = up.
template <typename T>
inline void sh3(T x, T y, T z, T* Y) {
    const T s3 = T(1.7320508075688772);    // sqrt(3)
    const T a = T(0.7905694150420949);     // sqrt(5/8)
    const T b = T(3.872983346207417);      // sqrt(15)
    const T c = T(0.6123724356957945);     // sqrt(3/8)
    Y[0] = 1;
    Y[1] = y; Y[2] = z; Y[3] = x;
    Y[4] = s3 * x * y; Y[5] = s3 * y * z; Y[6] = T(0.5) * (3 * z * z - 1);
    Y[7] = s3 * x * z; Y[8] = T(0.5) * s3 * (x * x - y * y);
    Y[9] = a * y * (3 * x * x - y * y); Y[10] = b * x * y * z; Y[11] = c * y * (5 * z * z - 1);
    Y[12] = T(0.5) * z * (5 * z * z - 3); Y[13] = c * x * (5 * z * z - 1);
    Y[14] = T(0.5) * b * z * (x * x - y * y); Y[15] = a * x * (x * x - 3 * y * y);
}

inline int acnDegree(int k) { return k < 1 ? 0 : (k < 4 ? 1 : (k < 9 ? 2 : 3)); }

struct Vec3 {
    float x = 1, y = 0, z = 0;
};

inline Vec3 dirFromAzEl(float azDeg, float elDeg) {
    float az = deg2rad(azDeg), el = deg2rad(elDeg);
    float ce = std::cos(el);
    return {ce * std::cos(az), ce * std::sin(az), std::sin(el)};
}

struct Rng {
    uint32_t s = 0x9E3779B9u;
    explicit Rng(uint32_t seed = 0x9E3779B9u) : s(seed ? seed : 1u) {}
    inline uint32_t next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
    inline float bipolar() { return float(next()) * (2.f / 4294967295.f) - 1.f; }
};

// Smooth random walk: cosine interpolation between random targets.
struct SmoothRandom {
    double p = 0;
    float r0 = 0, r1 = 0;
    void advance(double rateHz, double dt, Rng& rng) {
        p += rateHz * dt;
        while (p >= 1.0) { p -= 1.0; r0 = r1; r1 = rng.bipolar(); }
    }
    float value() const {
        float t = float(0.5 - 0.5 * std::cos(PI * p));
        return r0 + (r1 - r0) * t;
    }
};

enum LfoShape { LFO_SINE = 0, LFO_TRI, LFO_SAW_UP, LFO_SAW_DOWN, LFO_SQUARE, LFO_SH, LFO_SMOOTH, LFO_NUM_SHAPES };

struct Lfo {
    int shape = LFO_SINE;
    float rate = 0.1f;   // Hz (free) or cycles per beat (sync)
    float phase = 0.f;   // 0..1 offset
    bool sync = true;
    double p = 0;        // current cycle position 0..1
    double resetOff = 0; // sync: offset so that a reset lands on phase 0
    double lastCycle = 0;
    float r0 = 0, r1 = 0;
    // beat = absolute beat position of the shared clock (Ableton Link or manual)
    void advance(double dt, double beat, Rng& rng) {
        if (sync) {
            double c = beat * rate + resetOff;
            double ci = std::floor(c);
            if (ci != lastCycle) { r0 = r1; r1 = rng.bipolar(); lastCycle = ci; }
            p = c - ci;
        } else {
            p += rate * dt;
            while (p >= 1.0) { p -= 1.0; r0 = r1; r1 = rng.bipolar(); }
            while (p < 0.0) { p += 1.0; r1 = r0; r0 = rng.bipolar(); }
        }
    }
    void reset(double beat) {
        if (sync) { double c = beat * rate; resetOff = -(c - std::floor(c)); }
        p = 0;
    }
    float value() const {
        double q = p + phase;
        q -= std::floor(q);
        switch (shape) {
            case LFO_SINE: return (float)std::sin(2 * PI * q);
            case LFO_TRI: return float(q < 0.25 ? 4 * q : (q < 0.75 ? 2 - 4 * q : 4 * q - 4));
            case LFO_SAW_UP: return float(2 * q - 1);
            case LFO_SAW_DOWN: return float(1 - 2 * q);
            case LFO_SQUARE: return q < 0.5 ? 1.f : -1.f;
            case LFO_SH: return r1;
            case LFO_SMOOTH: {
                float t = float(0.5 - 0.5 * std::cos(PI * p));
                return r0 + (r1 - r0) * t;
            }
            default: return 0.f;
        }
    }
};

// Lock-free single producer / single consumer ring.
template <typename T, size_t N>
class Spsc {
public:
    bool push(const T& v) {
        size_t h = head_.load(std::memory_order_relaxed);
        size_t nh = (h + 1) % N;
        if (nh == tail_.load(std::memory_order_acquire)) return false;
        buf_[h] = v;
        head_.store(nh, std::memory_order_release);
        return true;
    }
    bool pop(T& v) {
        size_t t = tail_.load(std::memory_order_relaxed);
        if (t == head_.load(std::memory_order_acquire)) return false;
        v = buf_[t];
        tail_.store((t + 1) % N, std::memory_order_release);
        return true;
    }
private:
    T buf_[N];
    std::atomic<size_t> head_{0}, tail_{0};
};

}  // namespace dsp
