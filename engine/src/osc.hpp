// Minimal OSC 1.0 encoder / decoder (no dependencies).
#pragma once
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

namespace osc {

struct Arg {
    char type = 'N';
    int64_t i = 0;
    double f = 0.0;
    std::string s;

    float asFloat() const {
        switch (type) {
            case 'i': case 'h': return (float)i;
            case 'f': case 'd': return (float)f;
            case 'T': return 1.f;
            case 's': case 'S': return std::strtof(s.c_str(), nullptr);
            default: return 0.f;
        }
    }
    int asInt() const {
        switch (type) {
            case 'i': case 'h': return (int)i;
            case 'f': case 'd': return (int)std::lround(f);
            case 'T': return 1;
            case 's': case 'S': return std::atoi(s.c_str());
            default: return 0;
        }
    }
    std::string asString() const {
        switch (type) {
            case 's': case 'S': return s;
            case 'i': case 'h': return std::to_string(i);
            case 'f': case 'd': return std::to_string(f);
            default: return std::string();
        }
    }
};

struct Message {
    std::string address;
    std::vector<Arg> args;
};

inline uint32_t rd32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
inline uint64_t rd64(const uint8_t* p) { return (uint64_t(rd32(p)) << 32) | rd32(p + 4); }

inline bool readStr(const uint8_t* d, size_t n, size_t& pos, std::string& out) {
    size_t start = pos;
    while (pos < n && d[pos] != 0) ++pos;
    if (pos >= n) return false;
    out.assign((const char*)d + start, pos - start);
    pos = (pos + 4) & ~size_t(3);  // skip null + pad
    return pos <= n;
}

inline bool parse(const uint8_t* d, size_t n, std::vector<Message>& out, int depth = 0) {
    if (n < 4 || depth > 8) return false;
    if (n >= 16 && std::memcmp(d, "#bundle", 8) == 0) {
        size_t pos = 16;
        while (pos + 4 <= n) {
            uint32_t sz = rd32(d + pos);
            pos += 4;
            if (pos + sz > n) return false;
            parse(d + pos, sz, out, depth + 1);
            pos += sz;
        }
        return true;
    }
    Message m;
    size_t pos = 0;
    if (!readStr(d, n, pos, m.address) || m.address.empty() || m.address[0] != '/') return false;
    std::string tags;
    if (pos >= n || !readStr(d, n, pos, tags) || tags.empty() || tags[0] != ',') {
        out.push_back(std::move(m));
        return true;
    }
    for (size_t t = 1; t < tags.size(); ++t) {
        Arg a;
        a.type = tags[t];
        switch (a.type) {
            case 'i': case 'c': case 'r': case 'm':
                if (pos + 4 > n) return false;
                a.i = (int32_t)rd32(d + pos); pos += 4;
                if (a.type != 'i') a.type = 'i';
                break;
            case 'f': {
                if (pos + 4 > n) return false;
                uint32_t u = rd32(d + pos); float f; std::memcpy(&f, &u, 4);
                a.f = f; pos += 4; break;
            }
            case 'h': case 't':
                if (pos + 8 > n) return false;
                a.i = (int64_t)rd64(d + pos); pos += 8; a.type = 'h'; break;
            case 'd': {
                if (pos + 8 > n) return false;
                uint64_t u = rd64(d + pos); double f; std::memcpy(&f, &u, 8);
                a.f = f; pos += 8; break;
            }
            case 's': case 'S':
                if (!readStr(d, n, pos, a.s)) return false;
                a.type = 's';
                break;
            case 'b': {
                if (pos + 4 > n) return false;
                uint32_t sz = rd32(d + pos); pos += 4;
                pos += (sz + 3) & ~uint32_t(3);
                if (pos > n) return false;
                a.type = 'N';
                break;
            }
            case 'T': case 'F': case 'N': case 'I':
                break;
            default:
                return false;
        }
        m.args.push_back(std::move(a));
    }
    out.push_back(std::move(m));
    return true;
}

class Writer {
public:
    explicit Writer(const std::string& addr) : addr_(addr), tags_(",") {}
    Writer& i(int32_t v) { tags_ += 'i'; put32((uint32_t)v); return *this; }
    Writer& f(float v) { tags_ += 'f'; uint32_t u; std::memcpy(&u, &v, 4); put32(u); return *this; }
    Writer& s(const std::string& v) { tags_ += 's'; putStr(args_, v); return *this; }
    std::vector<uint8_t> bytes() const {
        std::vector<uint8_t> out;
        putStr(out, addr_);
        putStr(out, tags_);
        out.insert(out.end(), args_.begin(), args_.end());
        return out;
    }
private:
    static void putStr(std::vector<uint8_t>& b, const std::string& s) {
        b.insert(b.end(), s.begin(), s.end());
        size_t pad = 4 - (s.size() % 4);
        for (size_t k = 0; k < pad; ++k) b.push_back(0);
    }
    void put32(uint32_t u) {
        args_.push_back(uint8_t(u >> 24)); args_.push_back(uint8_t(u >> 16));
        args_.push_back(uint8_t(u >> 8)); args_.push_back(uint8_t(u));
    }
    std::string addr_, tags_;
    std::vector<uint8_t> args_;
};

}  // namespace osc
