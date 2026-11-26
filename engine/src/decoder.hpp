// Ambisonic decoder design (order <= 3, ACN/SN3D input).
#pragma once
#include <array>
#include <string>
#include <vector>

namespace ambi {

constexpr int HOA_N = 16;

struct Speaker {
    double az = 0, el = 0, dist = 2;  // degrees, degrees, metres
    bool sub = false;                 // subwoofer: not decoded, plays the mono bass only
};

enum DecoderType { DEC_ALLRAD = 0, DEC_MODEMATCH = 1, DEC_SAMPLING = 2 };
enum Optim { OPT_BASIC = 0, OPT_MAXRE = 1, OPT_INPHASE = 2 };

struct DecoderResult {
    std::vector<float> D;  // nspk x HOA_N, row major
    int order = 3;
    bool is2D = false;
    int typeUsed = DEC_ALLRAD;
    std::string info;
};

using V3 = std::array<double, 3>;

V3 dirFromAzEl(double azDeg, double elDeg);
std::vector<V3> fibonacciSphere(int n);

DecoderResult buildDecoder(const std::vector<Speaker>& spk, int type, int optim, int order);

// Plain sampling decoder (virtual microphones) on arbitrary directions, 3D, with optim weights.
std::vector<float> samplingDecoder3D(const std::vector<V3>& dirs, int order, int optim, bool normalise);

}  // namespace ambi
