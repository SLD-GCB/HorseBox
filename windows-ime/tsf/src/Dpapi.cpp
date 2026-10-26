#include "Dpapi.h"
#include <wincrypt.h>

// 固定熵值：让密文只对本程序有意义，别的程序拿到 blob 也不能直接解开
static const WCHAR kEntropy[] = L"HorseBox-v1";

static void FillEntropy(DATA_BLOB& blob) {
    blob.pbData = (BYTE*)kEntropy;
    blob.cbData = (DWORD)(sizeof(kEntropy) - sizeof(WCHAR));
}

bool DpapiProtect(const std::vector<BYTE>& plain, std::vector<BYTE>& sealed) {
    if (plain.empty()) return false;
    DATA_BLOB in = {};
    in.pbData = const_cast<BYTE*>(plain.data());
    in.cbData = (DWORD)plain.size();
    DATA_BLOB entropy = {};
    FillEntropy(entropy);
    DATA_BLOB out = {};
    if (!CryptProtectData(&in, L"HorseBox", &entropy, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return false;
    }
    sealed.assign(out.pbData, out.pbData + out.cbData);
    LocalFree(out.pbData);
    return true;
}

bool DpapiUnprotect(const std::vector<BYTE>& sealed, std::vector<BYTE>& plain) {
    if (sealed.empty()) return false;
    DATA_BLOB in = {};
    in.pbData = const_cast<BYTE*>(sealed.data());
    in.cbData = (DWORD)sealed.size();
    DATA_BLOB entropy = {};
    FillEntropy(entropy);
    DATA_BLOB out = {};
    if (!CryptUnprotectData(&in, nullptr, &entropy, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return false;
    }
    plain.assign(out.pbData, out.pbData + out.cbData);
    LocalFree(out.pbData);
    return true;
}

static const char kAlphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string Base64Encode(const std::vector<BYTE>& data) {
    std::string out;
    out.reserve((data.size() + 2) / 3 * 4);
    size_t i = 0;
    while (i + 2 < data.size()) {
        DWORD v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
        out.push_back(kAlphabet[(v >> 18) & 63]);
        out.push_back(kAlphabet[(v >> 12) & 63]);
        out.push_back(kAlphabet[(v >> 6) & 63]);
        out.push_back(kAlphabet[v & 63]);
        i += 3;
    }
    if (i + 1 == data.size()) {
        DWORD v = data[i] << 16;
        out.push_back(kAlphabet[(v >> 18) & 63]);
        out.push_back(kAlphabet[(v >> 12) & 63]);
        out += "==";
    } else if (i + 2 == data.size()) {
        DWORD v = (data[i] << 16) | (data[i + 1] << 8);
        out.push_back(kAlphabet[(v >> 18) & 63]);
        out.push_back(kAlphabet[(v >> 12) & 63]);
        out.push_back(kAlphabet[(v >> 6) & 63]);
        out.push_back('=');
    }
    return out;
}

bool Base64Decode(const std::string& text, std::vector<BYTE>& out) {
    int table[256];
    for (int i = 0; i < 256; ++i) table[i] = -1;
    for (int i = 0; i < 64; ++i) table[(BYTE)kAlphabet[i]] = i;
    out.clear();
    DWORD buffer = 0;
    int bits = 0;
    for (char c : text) {
        if (c == '=' || c == '\r' || c == '\n' || c == ' ') continue;
        int v = table[(BYTE)c];
        if (v < 0) return false;
        buffer = (buffer << 6) | (DWORD)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back((BYTE)((buffer >> bits) & 0xFF));
        }
    }
    return !out.empty();
}
