#include <windows.h>
#include <initguid.h>
#include <msctf.h>
#include <psapi.h>
#include <tlhelp32.h>
#include "../src/Dpapi.h"
#include "../src/Paths.h"
#include <stdio.h>
#include <string>

static const CLSID kClsid =
    { 0x6C1F0A3E, 0x9A2B, 0x4C77, { 0x8E, 0x31, 0x2F, 0x5C, 0x4B, 0x7D, 0x9A, 0x10 } };
static const GUID kProfile =
    { 0x3F1A7B2C, 0x5D4E, 0x4A6B, { 0x9C, 0x21, 0x7E, 0x8D, 0x4F, 0x0A, 0x5B, 0x6C } };
static const LANGID kLang = 0x0804;

DEFINE_GUID(HB_IID_ITfInputProcessorProfileMgr, 0x71C6E74C, 0x0F28, 0x11D8, 0xA8, 0x2A, 0x00, 0x06, 0x5B, 0x84, 0x43, 0x5C);
DEFINE_GUID(HB_CLSID_TF_InputProcessorProfiles, 0x33C53A50, 0xF456, 0x4884, 0xB0, 0x49, 0x85, 0xFD, 0x64, 0x3E, 0xCF, 0xED);
DEFINE_GUID(HB_IID_ITfInputProcessorProfiles, 0x1F02B6C5, 0x7842, 0x4EE6, 0x8A, 0x0B, 0x9A, 0x24, 0x18, 0x3A, 0x95, 0xCA);
DEFINE_GUID(HB_CLSID_TF_CategoryMgr, 0xA4B544A1, 0x438D, 0x4B41, 0x93, 0x25, 0x86, 0x95, 0x23, 0xE2, 0xD6, 0xC7);
DEFINE_GUID(HB_IID_ITfCategoryMgr, 0xC3ACEFB5, 0xF69D, 0x4905, 0x93, 0x8F, 0xFC, 0xAD, 0xCF, 0x4B, 0xE8, 0x30);
DEFINE_GUID(HB_GUID_TFCAT_TIP_KEYBOARD, 0x34745C63, 0xB2F0, 0x4784, 0x8B, 0x67, 0x5E, 0x12, 0xC8, 0x70, 0x1A, 0x31);

static std::wstring GuidStr(REFGUID g) {
    LPOLESTR s = nullptr;
    StringFromCLSID(g, &s);
    std::wstring out = s ? s : L"";
    if (s) CoTaskMemFree(s);
    return out;
}

static bool InUserList() {
    std::wstring valueName = L"0804:" + GuidStr(kClsid) + GuidStr(kProfile);
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Control Panel\\International\\User Profile\\zh-Hans-CN",
                      0, KEY_READ, &key) != ERROR_SUCCESS) {
        return false;
    }
    bool ok = RegQueryValueExW(key, valueName.c_str(), nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
    RegCloseKey(key);
    return ok;
}

static void AddToUserList() {
    ITfInputProcessorProfiles* profiles = nullptr;
    if (SUCCEEDED(CoCreateInstance(HB_CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                   HB_IID_ITfInputProcessorProfiles, (void**)&profiles)) && profiles) {
        profiles->AddLanguageProfile(kClsid, kLang, kProfile, L"HorseBox 输入法",
                                     (ULONG)wcslen(L"HorseBox 输入法"), nullptr, 0, 0);
        profiles->Release();
    }
}

// 结束所有加载了 IME DLL 的进程（跳过系统关键进程、自身与父进程）
static void KillDllHolders() {
    DWORD pids[2048];
    DWORD cbNeeded = 0;
    if (!EnumProcesses(pids, sizeof(pids), &cbNeeded)) return;
    DWORD count = cbNeeded / sizeof(DWORD);
    DWORD self = GetCurrentProcessId();
    DWORD parent = 0;
    {
        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap != INVALID_HANDLE_VALUE) {
            PROCESSENTRY32W pe = { 0 };
            pe.dwSize = sizeof(pe);
            if (Process32FirstW(snap, &pe)) {
                do {
                    if (pe.th32ProcessID == self) { parent = pe.th32ParentProcessID; break; }
                } while (Process32NextW(snap, &pe));
            }
            CloseHandle(snap);
        }
    }
    int killed = 0;
    const wchar_t* skip[] = { L"System", L"csrss.exe", L"winlogon.exe", L"lsass.exe",
                              L"services.exe", L"smss.exe", L"wininit.exe",
                              L"fontdrvhost.exe", L"dwm.exe", L"MsMpEng.exe" };
    for (DWORD i = 0; i < count; ++i) {
        DWORD pid = pids[i];
        if (pid == 0 || pid == self || pid == parent) continue;
        HANDLE h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_TERMINATE, FALSE, pid);
        if (!h) continue;
        WCHAR name[MAX_PATH] = { 0 };
        GetModuleBaseNameW(h, nullptr, name, MAX_PATH);
        bool skipIt = false;
        for (auto s : skip) {
            if (_wcsicmp(name, s) == 0) { skipIt = true; break; }
        }
        if (skipIt) { CloseHandle(h); continue; }
        bool hit = false;
        HMODULE mods[512];
        DWORD cbMods = 0;
        if (EnumProcessModules(h, mods, sizeof(mods), &cbMods)) {
            DWORD n = cbMods / sizeof(HMODULE);
            for (DWORD j = 0; j < n; ++j) {
                WCHAR path[MAX_PATH] = { 0 };
                if (GetModuleFileNameExW(h, mods[j], path, MAX_PATH)) {
                    if (wcsstr(path, L"horsebox-ime.dll") || wcsstr(path, L"horsebox_ime_engine.dll")) {
                        hit = true;
                        break;
                    }
                }
            }
        }
        if (hit) {
            if (TerminateProcess(h, 0)) {
                wprintf(L"killed %s (pid %lu)\n", name, pid);
                ++killed;
            } else {
                wprintf(L"kill failed %s (pid %lu) err=%lu\n", name, pid, GetLastError());
            }
        } else {
            CloseHandle(h);
            continue;
        }
        CloseHandle(h);
    }
    // 等进程真正退出，再确认 DLL 是否还被占用
    if (killed > 0) Sleep(400);
    int left = 0;
    for (DWORD i = 0; i < count; ++i) {
        DWORD pid = pids[i];
        if (pid == 0 || pid == self) continue;
        HANDLE h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
        if (!h) continue;
        HMODULE mods[512];
        DWORD cbMods = 0;
        if (EnumProcessModules(h, mods, sizeof(mods), &cbMods)) {
            DWORD n = cbMods / sizeof(HMODULE);
            for (DWORD j = 0; j < n; ++j) {
                WCHAR p[MAX_PATH] = { 0 };
                if (GetModuleFileNameExW(h, mods[j], p, MAX_PATH) &&
                    (wcsstr(p, L"horsebox-ime.dll") || wcsstr(p, L"horsebox_ime_engine.dll"))) {
                    WCHAR nm[MAX_PATH] = { 0 };
                    GetModuleBaseNameW(h, nullptr, nm, MAX_PATH);
                    wprintf(L"still loaded %s (pid %lu)\n", nm, pid);
                    ++left;
                    break;
                }
            }
        }
        CloseHandle(h);
    }
    wprintf(L"holders killed=%d remaining=%d\n", killed, left);
}

static void RemoveFromUserList() {
    ITfInputProcessorProfiles* profiles = nullptr;
    if (SUCCEEDED(CoCreateInstance(HB_CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                   HB_IID_ITfInputProcessorProfiles, (void**)&profiles)) && profiles) {
        profiles->RemoveLanguageProfile(kClsid, kLang, kProfile);
        profiles->Release();
    }
}

int wmain(int argc, wchar_t** argv) {
    std::wstring cmd = argc > 1 ? argv[1] : L"";
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    if (cmd == L"install" && argc > 2) {
        HMODULE m = LoadLibraryW(argv[2]);
        if (!m) {
            wprintf(L"load failed: %lu\n", GetLastError());
            CoUninitialize();
            return 2;
        }
        auto fn = (HRESULT(WINAPI*)())GetProcAddress(m, "DllRegisterServer");
        HRESULT hr = fn ? fn() : E_FAIL;
        FreeLibrary(m);
        wprintf(L"install hr=0x%08X\n", (unsigned)hr);
        CoUninitialize();
        return SUCCEEDED(hr) ? 0 : 3;
    }

    ITfInputProcessorProfileMgr* mgr = nullptr;
    HRESULT hr = CoCreateInstance(HB_CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                  HB_IID_ITfInputProcessorProfileMgr, (void**)&mgr);

    if (cmd == L"uninstall" && argc > 2) {
        RemoveFromUserList();
        HMODULE m = LoadLibraryW(argv[2]);
        if (m) {
            auto fn = (HRESULT(WINAPI*)())GetProcAddress(m, "DllUnregisterServer");
            if (fn) fn();
            FreeLibrary(m);
        }
        wprintf(L"uninstalled\n");
        KillDllHolders();
        CoUninitialize();
        return 0;
    }

    // 日志现在是 DPAPI 密文，用它解密出来看
    if (cmd == L"logdump") {
        std::wstring dir = ResolveDataDir();
        if (dir.empty()) {
            wprintf(L"no APPDATA\n");
            CoUninitialize();
            return 1;
        }
        std::wstring path = dir + L"\\ime_log.txt";
        FILE* f = _wfopen(path.c_str(), L"rb");
        if (!f) {
            wprintf(L"no log: %s\n", path.c_str());
            CoUninitialize();
            return 1;
        }
        char line[8192];
        while (fgets(line, sizeof(line), f)) {
            std::string s(line);
            while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
            if (s.empty()) continue;
            std::vector<BYTE> sealed, plain;
            if (Base64Decode(s, sealed) && DpapiUnprotect(sealed, plain)) {
                std::string out(plain.begin(), plain.end());
                printf("%s\n", out.c_str());
            } else {
                printf("%s\n", s.c_str());  // 老版本明文日志原样输出
            }
        }
        fclose(f);
        CoUninitialize();
        return 0;
    }

    if (cmd == L"diag") {
        ITfCategoryMgr* cat = nullptr;
        HRESULT h1 = CoCreateInstance(HB_CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
                                      HB_IID_ITfCategoryMgr, (void**)&cat);
        wprintf(L"catmgr=0x%08X\n", (unsigned)h1);
        if (cat) {
            HRESULT h2 = cat->RegisterCategory(kClsid, HB_GUID_TFCAT_TIP_KEYBOARD, kClsid);
            wprintf(L"registercat=0x%08X\n", (unsigned)h2);
            cat->Release();
        }
        ITfInputProcessorProfiles* p = nullptr;
        HRESULT h3 = CoCreateInstance(HB_CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                      HB_IID_ITfInputProcessorProfiles, (void**)&p);
        wprintf(L"profiles=0x%08X\n", (unsigned)h3);
        if (p) {
            HRESULT h4 = p->AddLanguageProfile(kClsid, kLang, kProfile, L"HorseBox 输入法", 8, nullptr, 0, 0);
            wprintf(L"addlang=0x%08X\n", (unsigned)h4);
            p->Release();
        }
        CoUninitialize();
        return 0;
    }

    if (cmd == L"enable") {
        AddToUserList();
        if (mgr) {
            mgr->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, kLang, kClsid, kProfile, nullptr, 0);
            mgr->Release();
        }
        wprintf(L"enable ok\n");
        CoUninitialize();
        return 0;
    }

    if (cmd == L"disable") {
        RemoveFromUserList();
        if (mgr) {
            mgr->DeactivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, kLang, kClsid, kProfile, nullptr, 0);
            mgr->Release();
        }
        wprintf(L"disable ok\n");
        CoUninitialize();
        return 0;
    }

    if (cmd == L"status") {
        bool registered = false;
        std::wstring sub = L"CLSID\\" + GuidStr(kClsid) + L"\\InprocServer32";
        HKEY key = nullptr;
        if (RegOpenKeyExW(HKEY_CLASSES_ROOT, sub.c_str(), 0, KEY_READ, &key) == ERROR_SUCCESS) {
            registered = true;
            RegCloseKey(key);
        }
        bool enabled = InUserList();
        wprintf(L"registered=%d\nenabled=%d\n", registered ? 1 : 0, enabled ? 1 : 0);
        if (mgr) mgr->Release();
        CoUninitialize();
        return 0;
    }

    wprintf(L"usage: horsebox-imectl install|uninstall <dll> | enable | disable | status | diag | logdump\n");
    if (mgr) mgr->Release();
    CoUninitialize();
    return 1;
}
