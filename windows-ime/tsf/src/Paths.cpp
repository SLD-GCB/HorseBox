#include "Paths.h"
#include <windows.h>
#include <cstdio>

static std::wstring g_dataDir;

static std::wstring Utf8ToWideLocal(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    if (n <= 0) return L"";
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n);
    return out;
}

std::wstring DefaultDataDir() {
    WCHAR buf[MAX_PATH] = { 0 };
    if (GetEnvironmentVariableW(L"APPDATA", buf, MAX_PATH) == 0) return L"";
    return std::wstring(buf) + L"\\HorseBox";
}

void InvalidateDataDir() { g_dataDir.clear(); }

std::wstring ResolveDataDir() {
    if (!g_dataDir.empty()) return g_dataDir;
    std::wstring fallback = DefaultDataDir();
    if (fallback.empty()) return fallback;

    std::wstring result = fallback;
    std::wstring pointer = fallback + L"\\bootstrap.json";
    FILE* f = _wfopen(pointer.c_str(), L"rb");
    if (f) {
        char buf[1024] = { 0 };
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        std::string text(buf, n);
        // 极简解析：bootstrap.json 只有 {"data_dir": "..."}
        size_t key = text.find("\"data_dir\"");
        if (key != std::string::npos) {
            size_t colon = text.find(':', key);
            size_t quote = (colon == std::string::npos) ? std::string::npos : text.find('"', colon);
            size_t end = (quote == std::string::npos) ? std::string::npos : text.find('"', quote + 1);
            if (end != std::string::npos) {
                std::string raw = text.substr(quote + 1, end - quote - 1);
                std::string plain;
                for (size_t i = 0; i < raw.size(); ++i) {
                    if (raw[i] == '\\' && i + 1 < raw.size()) {
                        ++i;
                        plain.push_back(raw[i]);
                    } else {
                        plain.push_back(raw[i]);
                    }
                }
                if (!plain.empty()) {
                    std::wstring wide = Utf8ToWideLocal(plain);
                    DWORD attrs = GetFileAttributesW(wide.c_str());
                    if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
                        result = wide;
                    }
                }
            }
        }
    }
    g_dataDir = result;
    return g_dataDir;
}

std::wstring FirstExisting(const std::wstring& primary, const std::wstring& legacy) {
    if (primary == legacy) return primary;
    if (GetFileAttributesW(primary.c_str()) != INVALID_FILE_ATTRIBUTES) return primary;
    if (GetFileAttributesW(legacy.c_str()) != INVALID_FILE_ATTRIBUTES) return legacy;
    return primary;
}
