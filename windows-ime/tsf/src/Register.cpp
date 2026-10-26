#include "Globals.h"
#include <string>

static bool SetValue(HKEY root, const std::wstring& sub, const WCHAR* name, const std::wstring& value) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(root, sub.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        return false;
    }
    LONG r = RegSetValueExW(key, name, 0, REG_SZ,
        (const BYTE*)value.c_str(), (DWORD)((value.size() + 1) * sizeof(WCHAR)));
    RegCloseKey(key);
    return r == ERROR_SUCCESS;
}

static bool SetDword(HKEY root, const std::wstring& sub, const WCHAR* name, DWORD value) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(root, sub.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        return false;
    }
    LONG r = RegSetValueExW(key, name, 0, REG_DWORD, (const BYTE*)&value, sizeof(value));
    RegCloseKey(key);
    return r == ERROR_SUCCESS;
}

static bool CreateRegKey(HKEY root, const std::wstring& sub) {
    HKEY key = nullptr;
    LONG r = RegCreateKeyExW(root, sub.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &key, nullptr);
    if (key) RegCloseKey(key);
    return r == ERROR_SUCCESS;
}

static std::wstring GuidString(REFGUID g) {
    LPOLESTR s = nullptr;
    StringFromCLSID(g, &s);
    std::wstring out = s ? s : L"";
    if (s) CoTaskMemFree(s);
    return out;
}

// 声明支持的 TSF 类别：键盘输入 + 微软拼音同款能力位
static const GUID* const kCategories[] = {
    &GUID_TFCAT_TIP_KEYBOARD,
    &GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    &GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
    &GUID_TFCAT_TIPCAP_COMLESS,
    &GUID_TFCAT_TIPCAP_INPUTMODECOMPARTMENT,
    &GUID_TFCAT_TIPCAP_UIELEMENTENABLED,
};

STDAPI DllRegisterServer() {
    WCHAR path[MAX_PATH] = { 0 };
    GetModuleFileNameW(g_hInst, path, MAX_PATH);
    std::wstring dll(path);

    std::wstring cs = GuidString(CLSID_HorseBoxIme);
    std::wstring sub = L"CLSID\\" + cs + L"\\InprocServer32";
    if (!SetValue(HKEY_CLASSES_ROOT, sub, nullptr, dll)) return E_FAIL;
    if (!SetValue(HKEY_CLASSES_ROOT, sub, L"ThreadingModel", L"Apartment")) return E_FAIL;

    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool coInit = SUCCEEDED(hr);

    // 统一使用老的 ITfInputProcessorProfiles：Register -> AddLanguageProfile -> Enable
    ITfInputProcessorProfiles* profiles = nullptr;
    hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                          IID_ITfInputProcessorProfiles, (void**)&profiles);
    if (SUCCEEDED(hr) && profiles) {
        profiles->Register(CLSID_HorseBoxIme);
        profiles->AddLanguageProfile(CLSID_HorseBoxIme, 0x0804, GUID_HorseBoxProfile,
                                     kTextServiceDesc, (ULONG)wcslen(kTextServiceDesc), nullptr, 0, 0);
        profiles->EnableLanguageProfile(CLSID_HorseBoxIme, 0x0804, GUID_HorseBoxProfile, TRUE);
        profiles->Release();
    }

    // Category（本机 ITfCategoryMgr 不可用，手写注册表，结构和微软拼音一致）
    {
        std::wstring tip = L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + cs;
        std::wstring cat = L"{34745C63-B2F0-4784-8B67-5E12C8701A31}";
        CreateRegKey(HKEY_LOCAL_MACHINE, tip + L"\\Category\\Item\\" + cs);
        SetValue(HKEY_LOCAL_MACHINE, tip + L"\\Category\\Item\\" + cs, L"Description", kTextServiceDesc);
        CreateRegKey(HKEY_LOCAL_MACHINE, tip + L"\\Category\\Item\\" + cs + L"\\" + cat);
        CreateRegKey(HKEY_LOCAL_MACHINE, tip + L"\\Category\\Category\\" + cat + L"\\" + cs);
    }

    // 官方 Category 注册（IID 修正后可用，会同步 CTF 缓存）
    // 只注册 KEYBOARD 时，Windows Terminal / 沉浸式应用这类客户端会判定输入法能力不全而拒用，
    // 表现为"切过去一打字就退回微软输入法"，所以按微软拼音的能力集补齐。
    {
        ITfCategoryMgr* catmgr = nullptr;
        if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
                                       IID_ITfCategoryMgr, (void**)&catmgr)) && catmgr) {
            for (const GUID* cat : kCategories) {
                catmgr->RegisterCategory(CLSID_HorseBoxIme, *cat, CLSID_HorseBoxIme);
            }
            catmgr->Release();
        }
    }

    // profile 补 Enable / Display Description（和微软拼音对齐）
    {
        std::wstring pk = L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + cs
            + L"\\LanguageProfile\\0x00000804\\" + GuidString(GUID_HorseBoxProfile);
        SetValue(HKEY_LOCAL_MACHINE, pk, L"Display Description", kTextServiceDesc);
        SetDword(HKEY_LOCAL_MACHINE, pk, L"Enable", 1);
        SetDword(HKEY_LOCAL_MACHINE, pk, L"IconIndex", 0);
    }

    if (coInit) CoUninitialize();
    return SUCCEEDED(hr) ? S_OK : E_FAIL;
}

STDAPI DllUnregisterServer() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool coInit = SUCCEEDED(hr);

    ITfInputProcessorProfiles* profiles = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_ITfInputProcessorProfiles, (void**)&profiles)) && profiles) {
        profiles->RemoveLanguageProfile(CLSID_HorseBoxIme, 0x0804, GUID_HorseBoxProfile);
        profiles->Unregister(CLSID_HorseBoxIme);
        profiles->Release();
    }

    {
        ITfCategoryMgr* catmgr = nullptr;
        if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
                                       IID_ITfCategoryMgr, (void**)&catmgr)) && catmgr) {
            for (const GUID* cat : kCategories) {
                catmgr->UnregisterCategory(CLSID_HorseBoxIme, *cat, CLSID_HorseBoxIme);
            }
            catmgr->Release();
        }
    }

    // 删整棵 TIP（不再只删 Category）
    std::wstring tip = L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + GuidString(CLSID_HorseBoxIme);
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, tip.c_str());

    if (coInit) CoUninitialize();

    std::wstring sub = L"CLSID\\" + GuidString(CLSID_HorseBoxIme);
    RegDeleteTreeW(HKEY_CLASSES_ROOT, sub.c_str());
    return S_OK;
}
