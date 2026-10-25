#include "TextService.h"
#include "Dpapi.h"
#include "Paths.h"
#include <algorithm>
#include <cctype>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

// 日志里有键码和拼音，落盘前用 DPAPI 加密（每行一个 base64），不写明文
static void LogLine(const char* msg) {
    std::wstring dir = ResolveDataDir();   // 跟随 App 的数据目录
    if (dir.empty()) return;
    CreateDirectoryW(dir.c_str(), nullptr);
    std::wstring path = dir + L"\\ime_log.txt";

    SYSTEMTIME st;
    GetLocalTime(&st);
    char line[512];
    _snprintf_s(line, sizeof(line), _TRUNCATE, "[%02d:%02d:%02d.%03d] %s",
                st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, msg);

    std::vector<BYTE> plain(line, line + strlen(line));
    std::vector<BYTE> sealed;
    if (!DpapiProtect(plain, sealed)) return;   // 加不了密就不写
    std::string text = Base64Encode(sealed);
    FILE* f = _wfopen(path.c_str(), L"ab");
    if (f) {
        fwrite(text.data(), 1, text.size(), f);
        fputc('\n', f);
        fclose(f);
    }
}

static const GUID kModeGuids[3] = {
    { 0x51C7A3E9, 0x2B4D, 0x4F60, { 0x9A, 0x7E, 0x3C, 0x1D, 0x8B, 0x6F, 0x2A, 0x54 } },
    { 0x51C7A3E9, 0x2B4D, 0x4F60, { 0x9A, 0x7E, 0x3C, 0x1D, 0x8B, 0x6F, 0x2A, 0x55 } },
    { 0x51C7A3E9, 0x2B4D, 0x4F60, { 0x9A, 0x7E, 0x3C, 0x1D, 0x8B, 0x6F, 0x2A, 0x56 } },
};

static HICON MakeTextIcon(const wchar_t* text, COLORREF bg) {
    const int size = 32;
    HDC hdc = CreateCompatibleDC(nullptr);
    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = size;
    bmi.bmiHeader.biHeight = -size;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP color = CreateDIBSection(hdc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
    HGDIOBJ old = SelectObject(hdc, color);
    RECT rc = { 0, 0, size, size };
    HBRUSH br = CreateSolidBrush(bg);
    FillRect(hdc, &rc, br);
    DeleteObject(br);
    SetBkMode(hdc, TRANSPARENT);
    SetTextColor(hdc, RGB(255, 255, 255));
    HFONT font = CreateFontW(-22, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Microsoft YaHei UI");
    HGDIOBJ of = SelectObject(hdc, font);
    DrawTextW(hdc, text, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SelectObject(hdc, of);
    DeleteObject(font);
    SelectObject(hdc, old);
    DeleteDC(hdc);
    ICONINFO ii = {};
    ii.fIcon = TRUE;
    ii.hbmColor = color;
    ii.hbmMask = mask;
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

static void LogF(const char* fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf_s(buf, sizeof(buf), _TRUNCATE, fmt, ap);
    va_end(ap);
    LogLine(buf);
}

// ------------------------------------------------------------------ 插入文本

class CInsertSession : public ITfEditSession {
public:
    CInsertSession(ITfContext* ctx, const std::wstring& text) : _ctx(ctx), _text(text) {
        if (_ctx) _ctx->AddRef();
    }
    ~CInsertSession() {
        if (_ctx) _ctx->Release();
    }

    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_INVALIDARG;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession)) {
            *ppv = static_cast<ITfEditSession*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return (ULONG)InterlockedIncrement(&_ref); }
    STDMETHODIMP_(ULONG) Release() override {
        ULONG r = (ULONG)InterlockedDecrement(&_ref);
        if (r == 0) delete this;
        return r;
    }

    STDMETHODIMP DoEditSession(TfEditCookie ec) override {
        TF_SELECTION sel = {};
        ULONG fetched = 0;
        if (FAILED(_ctx->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &fetched)) || fetched != 1) {
            return S_OK;
        }
        if (SUCCEEDED(sel.range->SetText(ec, 0, _text.c_str(), (LONG)_text.size()))) {
            // 插入后必须把上下文的选择移到文字末尾，否则光标仍停在插入点（表现为光标在字前面、
            // GetTextExt 一直返回同一个矩形，候选窗也不跟着走）
            if (SUCCEEDED(sel.range->Collapse(ec, TF_ANCHOR_END))) {
                sel.style.ase = TF_AE_NONE;
                sel.style.fInterimChar = FALSE;
                _ctx->SetSelection(ec, 1, &sel);
            }
        }
        sel.range->Release();
        return S_OK;
    }

private:
    LONG _ref = 1;
    ITfContext* _ctx = nullptr;
    std::wstring _text;
};

// ------------------------------------------------------------------ CTextService

CTextService::CTextService() {
    EngineBridge::Instance().Load(AppDir());
    _window.Create(g_hInst);
}

CTextService::~CTextService() {
    for (int i = 0; i < 3; ++i) {
        if (_modeIcons[i]) { DestroyIcon(_modeIcons[i]); _modeIcons[i] = nullptr; }
    }
    _window.Destroy();
    if (_context) { _context->Release(); _context = nullptr; }
    if (_docMgr) { _docMgr->Release(); _docMgr = nullptr; }
    if (_threadMgr) { _threadMgr->Release(); _threadMgr = nullptr; }
}

STDMETHODIMP CTextService::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_INVALIDARG;
    *ppv = nullptr;
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfTextInputProcessor)) {
        *ppv = static_cast<ITfTextInputProcessor*>(this);
    } else if (IsEqualIID(riid, IID_ITfThreadMgrEventSink)) {
        *ppv = static_cast<ITfThreadMgrEventSink*>(this);
    } else if (IsEqualIID(riid, IID_ITfKeyEventSink)) {
        *ppv = static_cast<ITfKeyEventSink*>(this);
    } else if (IsEqualIID(riid, IID_ITfLangBarItem)) {
        *ppv = static_cast<ITfLangBarItem*>(this);
    } else if (IsEqualIID(riid, IID_ITfLangBarItemButton)) {
        *ppv = static_cast<ITfLangBarItemButton*>(this);
    } else if (IsEqualIID(riid, IID_ITfSource)) {
        *ppv = static_cast<ITfSource*>(this);
    } else {
        return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) CTextService::AddRef() {
    return (ULONG)InterlockedIncrement(&_ref);
}

STDMETHODIMP_(ULONG) CTextService::Release() {
    ULONG r = (ULONG)InterlockedDecrement(&_ref);
    if (r == 0) delete this;
    return r;
}

std::wstring CTextService::AppDir() const {
    WCHAR path[MAX_PATH] = { 0 };
    GetModuleFileNameW(g_hInst, path, MAX_PATH);
    std::wstring p(path);
    size_t pos = p.find_last_of(L"\\/");
    if (pos != std::wstring::npos) p = p.substr(0, pos + 1);
    return p;
}

STDMETHODIMP CTextService::Activate(ITfThreadMgr* ptim, TfClientId tid) {
    LogLine("Activate enter");
    _threadMgr = ptim;
    if (_threadMgr) _threadMgr->AddRef();
    _clientId = tid;

    EngineBridge::Instance().Load(AppDir());
    LogLine("Activate engine loaded");
    LoadConfig();
    LoadLearningFile();
    ApplyWindowStyle();

    ITfSource* source = nullptr;
    if (_threadMgr && SUCCEEDED(_threadMgr->QueryInterface(IID_ITfSource, (void**)&source)) && source) {
        source->AdviseSink(IID_ITfThreadMgrEventSink,
                           static_cast<ITfThreadMgrEventSink*>(this), &_sinkCookie);
        source->Release();
    }

    ITfKeystrokeMgr* keystroke = nullptr;
    if (_threadMgr && SUCCEEDED(_threadMgr->QueryInterface(IID_ITfKeystrokeMgr, (void**)&keystroke)) && keystroke) {
        keystroke->AdviseKeyEventSink(_clientId, static_cast<ITfKeyEventSink*>(this), TRUE);
        keystroke->Release();
    }

    if (_threadMgr && SUCCEEDED(_threadMgr->QueryInterface(IID_ITfLangBarItemMgr, (void**)&_langBarMgr)) && _langBarMgr) {
        _langBarMgr->AddItem(static_cast<ITfLangBarItem*>(this));
        LogLine("LangBar item added");
    }
    LogLine("Activate done");
    return S_OK;
}

STDMETHODIMP CTextService::Deactivate() {
    LogLine("Deactivate");
    SaveLearningFile();
    if (_threadMgr) {
        ITfSource* source = nullptr;
        if (SUCCEEDED(_threadMgr->QueryInterface(IID_ITfSource, (void**)&source)) && source) {
            if (_sinkCookie != TF_INVALID_COOKIE) source->UnadviseSink(_sinkCookie);
            source->Release();
        }
        ITfKeystrokeMgr* keystroke = nullptr;
        if (SUCCEEDED(_threadMgr->QueryInterface(IID_ITfKeystrokeMgr, (void**)&keystroke)) && keystroke) {
            keystroke->UnadviseKeyEventSink(_clientId);
            keystroke->Release();
        }
    }
    _sinkCookie = TF_INVALID_COOKIE;
    _keyCookie = TF_INVALID_COOKIE;

    if (_langBarMgr) {
        _langBarMgr->RemoveItem(static_cast<ITfLangBarItem*>(this));
        _langBarMgr->Release();
        _langBarMgr = nullptr;
    }
    if (_langBarSink) { _langBarSink->Release(); _langBarSink = nullptr; }

    ResetComposition();
    _window.Destroy();

    if (_context) { _context->Release(); _context = nullptr; }
    if (_docMgr) { _docMgr->Release(); _docMgr = nullptr; }
    if (_threadMgr) { _threadMgr->Release(); _threadMgr = nullptr; }
    _clientId = TF_CLIENTID_NULL;
    return S_OK;
}

STDMETHODIMP CTextService::OnSetFocus(ITfDocumentMgr* pdimFocus, ITfDocumentMgr* /*pdimPrevFocus*/) {
    if (_context) { _context->Release(); _context = nullptr; }
    if (_docMgr) { _docMgr->Release(); _docMgr = nullptr; }
    if (pdimFocus) {
        _docMgr = pdimFocus;
        _docMgr->AddRef();
        _docMgr->GetTop(&_context);
    }
    LogF("OnSetFocus ctx=%p", (void*)_context);
    MaybeReloadConfig();   // 设置页改完不用重启输入法
    ResetComposition();
    return S_OK;
}

STDMETHODIMP CTextService::OnPushContext(ITfContext* pic) {
    if (_context) { _context->Release(); _context = nullptr; }
    _context = pic;
    if (_context) _context->AddRef();
    LogF("OnPushContext ctx=%p", (void*)_context);
    ResetComposition();
    return S_OK;
}

STDMETHODIMP CTextService::OnPopContext(ITfContext* /*pic*/) {
    UpdateContext();
    ResetComposition();
    return S_OK;
}

void CTextService::UpdateContext() {
    if (_context) { _context->Release(); _context = nullptr; }
    if (_docMgr) _docMgr->GetTop(&_context);
}

// 中文模式下的标点：中文标点；英文模式不进来，保持键盘原来的半角
static bool MapChinesePunct(WPARAM vk, bool shift, int& quoteToggle, std::wstring& out) {
    switch (vk) {
    case VK_OEM_COMMA:  out = shift ? L"\u300A" : L"\uFF0C"; return true;  // 《 ，
    case VK_OEM_PERIOD: out = shift ? L"\u300B" : L"\u3002"; return true;  // 》 。
    case VK_OEM_1:      out = shift ? L"\uFF1A" : L"\uFF1B"; return true;  // ： ；
    case VK_OEM_2:      out = shift ? L"\uFF1F" : L"\u3001"; return true;  // ？ 、
    case VK_OEM_4:      out = shift ? L"\u300C" : L"\u3010"; return true;  // 「 【
    case VK_OEM_6:      out = shift ? L"\u300D" : L"\u3011"; return true;  // 」 】
    case VK_OEM_5:      out = shift ? L"\uFF5C" : L"\u3001"; return true;  // ｜ 、
    case VK_OEM_3:      out = shift ? L"\uFF5E" : L"\u00B7"; return true;  // ～ ·
    case VK_OEM_7: {
        bool even = (quoteToggle % 2) == 0;
        if (shift) {
            out = even ? L"\u201C" : L"\u201D";  // “ ”
        } else {
            out = even ? L"\u2018" : L"\u2019";  // ‘ ’
        }
        ++quoteToggle;
        return true;
    }
    default:
        return false;
    }
}

STDMETHODIMP CTextService::OnTestKeyDown(ITfContext* /*pic*/, WPARAM wParam, LPARAM /*lParam*/, BOOL* pfEaten) {
    if (!pfEaten) return E_INVALIDARG;
    BOOL eaten = FALSE;
    bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
    bool win = (GetKeyState(VK_LWIN) & 0x8000) != 0 || (GetKeyState(VK_RWIN) & 0x8000) != 0;
    bool composing = !_pinyin.empty();
    // 按着 Shift 又敲了别的键，说明 Shift 是修饰键，抬起时不该切中英
    if (wParam != VK_SHIFT && (GetKeyState(VK_SHIFT) & 0x8000) != 0) _shiftUsed = true;
    if (ctrl && wParam == VK_SPACE) {
        eaten = TRUE;
    } else if (ctrl || alt || win) {
        eaten = FALSE;
    } else if (wParam == VK_SHIFT) {
        eaten = FALSE;
    } else if (wParam >= 'A' && wParam <= 'Z') {
        // 英文模式/大写锁定/Shift 按住时不吃，字母直接交给程序
        bool caps = (GetKeyState(VK_CAPITAL) & 1) != 0;
        bool shifted = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        eaten = (_chinese || _englishSuggest) && !(caps || shifted);
    } else if (composing) {
        if (wParam == VK_SPACE || wParam == VK_BACK || wParam == VK_RETURN || wParam == VK_ESCAPE ||
            wParam == VK_LEFT || wParam == VK_RIGHT || wParam == VK_UP || wParam == VK_DOWN) {
            eaten = TRUE;
        } else if (wParam >= '1' && wParam <= '9' &&
                   PageStart() + (int)(wParam - '1') < (int)_cands.size()) {
            eaten = TRUE;   // 只吃当前页真的有的那几个数字
        }
    }
    // 多页时 - / = / PgUp / PgDn 归我们翻页
    if (!eaten && (int)_cands.size() > _pageSize) {
        if (wParam == VK_PRIOR || wParam == VK_NEXT || wParam == VK_OEM_MINUS || wParam == VK_OEM_PLUS) {
            eaten = TRUE;
        }
    }
    // 中文模式标点归我们输出全角（这里只做判断，不动引号开关）
    if (!eaten && _chinese) {
        std::wstring punct;
        int toggle = _quoteToggle;
        bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        if (MapChinesePunct(wParam, shift, toggle, punct)) eaten = TRUE;
    }
    *pfEaten = eaten;
    return S_OK;
}

STDMETHODIMP CTextService::OnKeyDown(ITfContext* pic, WPARAM wParam, LPARAM /*lParam*/, BOOL* pfEaten) {
    if (!pfEaten) return E_INVALIDARG;
    *pfEaten = FALSE;
    if (pic && pic != _context) {
        if (_context) _context->Release();
        _context = pic;
        _context->AddRef();
    }
    MaybeReloadConfigFast();   // 设置页改完，下一次按键就用新配置
    LogF("OnKeyDown key=%u chinese=%d ctx=%p py=%d", (unsigned)wParam, _chinese ? 1 : 0, (void*)_context, (int)_pinyin.size());
    if (!_context) return S_OK;

    bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    if (ctrl && wParam == VK_SPACE) {
        CycleMode();
        *pfEaten = TRUE;
        return S_OK;
    }
    // Ctrl/Alt/Win 组合键属于系统与应用（Ctrl+C/V、Alt+Tab、Win+Space 等），一律不吞
    bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
    bool win = (GetKeyState(VK_LWIN) & 0x8000) != 0 || (GetKeyState(VK_RWIN) & 0x8000) != 0;
    if (ctrl || alt || win) return S_OK;

    if (wParam == VK_SHIFT) {
        _shiftDown = true;
        _shiftUsed = false;
        return S_OK;
    }
    if (_shiftDown) _shiftUsed = true;

    if (wParam >= 'A' && wParam <= 'Z') {
        // 大写锁定、按住 Shift，或英文模式下没开联想：都不组词，字母直接进输入框
        bool caps = (GetKeyState(VK_CAPITAL) & 1) != 0;
        bool shifted = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        bool compose = _chinese || _englishSuggest;
        if (!compose || caps || shifted) {
            if (!_pinyin.empty()) CommitSelected();   // 先把已经在输入的拼音上屏
            return S_OK;
        }
        _pinyin.push_back((char)tolower((int)wParam));
        UpdateCandidates();
        RefreshWindow();
        *pfEaten = TRUE;
        return S_OK;
    }

    if (wParam == VK_BACK) {
        if (_pinyin.empty()) {
            return S_OK;
        }
        _pinyin.pop_back();
        if (_pinyin.empty()) {
            ResetComposition();
        } else {
            UpdateCandidates();
            RefreshWindow();
        }
        *pfEaten = TRUE;
        return S_OK;
    }

    if (wParam == VK_LEFT || wParam == VK_UP || wParam == VK_RIGHT || wParam == VK_DOWN) {
        if (_pinyin.empty() || _cands.empty()) return S_OK;
        int total = (int)_cands.size();
        // 走到本页边缘就自动翻页：上下左右都能翻
        int sel = (wParam == VK_LEFT || wParam == VK_UP)
                      ? std::max(0, _sel - 1)
                      : std::min(total - 1, _sel + 1);
        if (sel != _sel) {
            _sel = sel;
            RefreshWindow();
        }
        LogF("Arrow sel=%d total=%d", _sel, total);
        *pfEaten = TRUE;
        return S_OK;
    }

    if (wParam == VK_SPACE || wParam == VK_RETURN) {
        if (_pinyin.empty()) return S_OK;
        CommitSelected();
        *pfEaten = TRUE;
        return S_OK;
    }

    if (wParam == VK_ESCAPE) {
        if (!_pinyin.empty()) {
            ResetComposition();
            *pfEaten = TRUE;
        }
        return S_OK;
    }

    // 整页翻：PgUp/PgDn 或 - / =（方向键走的是逐个移动，到边缘自动翻页）
    if ((int)_cands.size() > _pageSize) {
        int start = PageStart();
        if (wParam == VK_PRIOR || wParam == VK_OEM_MINUS) {
            if (start > 0) { _sel = std::max(0, start - _pageSize); RefreshWindow(); }
            *pfEaten = TRUE;
            return S_OK;
        }
        if (wParam == VK_NEXT || wParam == VK_OEM_PLUS) {
            if (HasNextPage()) {
                _sel = std::min((int)_cands.size() - 1, start + _pageSize);
                RefreshWindow();
            }
            *pfEaten = TRUE;
            return S_OK;
        }
    }

    // 中文模式标点：直接输出全角，并且把已在输入的拼音先上屏
    if (_chinese) {
        std::wstring punct;
        bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
        if (MapChinesePunct(wParam, shift, _quoteToggle, punct)) {
            if (!_pinyin.empty()) CommitSelected();
            CommitText(punct);
            *pfEaten = TRUE;
            return S_OK;
        }
    }

    if (wParam >= '1' && wParam <= '9' && !_cands.empty()) {
        int global = PageStart() + (int)wParam - '1';
        if (global < (int)_cands.size()) {
            _sel = global;
            CommitSelected();
            *pfEaten = TRUE;
        }
        return S_OK;
    }

    if (!_pinyin.empty()) {
        CommitSelected();
    }
    return S_OK;
}

STDMETHODIMP CTextService::OnKeyUp(ITfContext* /*pic*/, WPARAM wParam, LPARAM /*lParam*/, BOOL* pfEaten) {
    if (!pfEaten) return E_INVALIDARG;
    *pfEaten = FALSE;
    if (wParam == VK_SHIFT) {
        if (_shiftDown && !_shiftUsed) {
            CycleMode();
        }
        _shiftDown = false;
        _shiftUsed = false;
    }
    return S_OK;
}

STDMETHODIMP CTextService::GetInfo(TF_LANGBARITEMINFO* pInfo) {
    if (!pInfo) return E_INVALIDARG;
    pInfo->clsidService = CLSID_HorseBoxIme;
    pInfo->guidItem = GUID_HorseBoxLangBarItem;
    pInfo->dwStyle = TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY;
    pInfo->ulSort = 0;
    lstrcpynW(pInfo->szDescription, L"HorseBox 输入法", 32);
    return S_OK;
}

STDMETHODIMP CTextService::GetStatus(DWORD* pdwStatus) {
    if (!pdwStatus) return E_INVALIDARG;
    *pdwStatus = 0;
    return S_OK;
}

STDMETHODIMP CTextService::Show(BOOL /*fShow*/) { return S_OK; }

STDMETHODIMP CTextService::GetTooltipString(BSTR* pbstrToolTip) {
    if (!pbstrToolTip) return E_INVALIDARG;
    std::wstring t = L"HorseBox 输入法 - " + ModeText();
    *pbstrToolTip = SysAllocString(t.c_str());
    return *pbstrToolTip ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP CTextService::OnClick(TfLBIClick /*click*/, POINT /*pt*/, const RECT* /*prcArea*/) {
    CycleMode();
    return S_OK;
}

STDMETHODIMP CTextService::InitMenu(ITfMenu* /*pMenu*/) { return E_NOTIMPL; }

STDMETHODIMP CTextService::OnMenuSelect(UINT /*wID*/) { return S_OK; }

STDMETHODIMP CTextService::AdviseSink(REFIID riid, IUnknown* punk, DWORD* pdwCookie) {
    LogLine("AdviseSink called");
    if (!punk || !pdwCookie) return E_INVALIDARG;
    if (!IsEqualIID(riid, IID_ITfLangBarItemSink)) return E_NOINTERFACE;
    if (_langBarSink) return E_FAIL;
    if (FAILED(punk->QueryInterface(IID_ITfLangBarItemSink, (void**)&_langBarSink))) return E_NOINTERFACE;
    *pdwCookie = 1;
    return S_OK;
}

STDMETHODIMP CTextService::UnadviseSink(DWORD dwCookie) {
    if (dwCookie != 1) return E_FAIL;
    if (_langBarSink) { _langBarSink->Release(); _langBarSink = nullptr; }
    return S_OK;
}

void CTextService::EnsureModeIcons() {
    if (!_modeIcons[0]) _modeIcons[0] = MakeTextIcon(L"简", RGB(0, 120, 215));
    if (!_modeIcons[1]) _modeIcons[1] = MakeTextIcon(L"繁", RGB(230, 120, 20));
    if (!_modeIcons[2]) _modeIcons[2] = MakeTextIcon(L"英", RGB(40, 160, 80));
}

STDMETHODIMP CTextService::GetIcon(HICON* phIcon) {
    LogF("GetIcon mode=%d", _mode);
    EnsureModeIcons();
    if (phIcon) *phIcon = _modeIcons[0];  // 固定 HorseBox 图标
    return S_OK;
}

STDMETHODIMP CTextService::GetText(BSTR* pbstrText) {
    LogF("GetText mode=%d", _mode);
    if (!pbstrText) return E_INVALIDARG;
    *pbstrText = SysAllocString(L"HorseBox");
    return *pbstrText ? S_OK : E_OUTOFMEMORY;
}

std::wstring CTextService::ModeText() const {
    if (_mode != 0) return L"英文";
    // 繁体是输出字形，不是模式；徽标上如实显示，免得以为没生效
    return _traditional ? L"繁体" : L"简体";
}

void CTextService::ApplyMode() {
    _chinese = (_mode == 0);
    // 繁体不再是模式，改由设置页的开关决定（_traditional 在 LoadConfig 里读）
    ResetComposition();
    LogF("Mode=%d chinese=%d trad=%d sink=%p", _mode, _chinese ? 1 : 0, _traditional ? 1 : 0, (void*)_langBarSink);
    if (_langBarSink) {
        _langBarSink->OnUpdate(TF_LBI_ICON | TF_LBI_TEXT | TF_LBI_TOOLTIP | TF_LBI_STATUS);
    }
    SetCompartment();
}

void CTextService::SetCompartment() {
    if (!_threadMgr) return;
    ITfCompartmentMgr* cm = nullptr;
    if (SUCCEEDED(_threadMgr->QueryInterface(IID_ITfCompartmentMgr, (void**)&cm)) && cm) {
        ITfCompartment* comp = nullptr;
        if (SUCCEEDED(cm->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, &comp)) && comp) {
            VARIANT var;
            VariantInit(&var);
            var.vt = VT_I4;
            var.lVal = _chinese ? 1 : 0;
            comp->SetValue(_clientId, &var);
            comp->Release();
        }
        cm->Release();
    }
    LogF("Compartment openclose=%d", _chinese ? 1 : 0);
}

void CTextService::CycleMode() {
    _mode = (_mode + 1) % 2;   // 只在 简 / 英 之间切
    ApplyMode();
}

void CTextService::ResetComposition() {
    _pinyin.clear();
    _cands.clear();
    _sel = 0;
    _window.Hide();
}

// _sel 是全局下标，所在页由它推导出来
int CTextService::PageStart() const {
    if (_pageSize <= 0) return 0;
    return (_sel / _pageSize) * _pageSize;
}

int CTextService::PageItems() const {
    int remain = (int)_cands.size() - PageStart();
    if (remain <= 0) return 0;
    return remain > _pageSize ? _pageSize : remain;
}

bool CTextService::HasNextPage() const {
    return PageStart() + _pageSize < (int)_cands.size();
}

int CTextService::PageCount() const {
    int total = (int)_cands.size();
    if (total <= 0 || _pageSize <= 0) return 0;
    return (total + _pageSize - 1) / _pageSize;
}

// Windows 的"应用模式"：AppsUseLightTheme=0 表示深色
static bool SystemDarkMode() {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                      0, KEY_READ, &key) != ERROR_SUCCESS) {
        return false;
    }
    DWORD value = 1, size = sizeof(value), type = 0;
    bool dark = false;
    if (RegQueryValueExW(key, L"AppsUseLightTheme", nullptr, &type, (BYTE*)&value, &size) == ERROR_SUCCESS) {
        dark = (value == 0);
    }
    RegCloseKey(key);
    return dark;
}

// 配置里是 AARRGGBB 或 RRGGBB（不区分大小写）
static COLORREF ParseColor(const std::string& v, COLORREF fallback) {
    if (v.empty()) return fallback;
    char* end = nullptr;
    unsigned long raw = strtoul(v.c_str(), &end, 16);
    if (end == v.c_str()) return fallback;
    return RGB((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF);
}

void CTextService::ApplyWindowStyle() {
    _window.ApplyStyle(_themeDark, _paletteOn, _bg, _fg, _border, _accent);
}

std::wstring CTextService::LearningPath() const {
    std::wstring dir = ResolveDataDir();
    if (dir.empty()) return L"";
    return dir + L"\\ime_learned.txt";
}

// 学习记录加密落盘：文件里是 DPAPI 密文，老版本的明文文件读一次就迁移过去
void CTextService::LoadLearningFile() {
    std::wstring path = LearningPath();
    if (path.empty()) return;
    {
        std::wstring legacy = DefaultDataDir() + L"\\ime_learned.txt";
        path = FirstExisting(path, legacy);
    }
    FILE* f = _wfopen(path.c_str(), L"rb");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0) { fclose(f); return; }
    std::vector<BYTE> raw((size_t)size);
    size_t got = fread(raw.data(), 1, raw.size(), f);
    fclose(f);
    raw.resize(got);
    if (raw.empty()) return;
    std::vector<BYTE> plain;
    if (!DpapiUnprotect(raw, plain)) plain = raw;  // 旧格式（明文）直接吃
    std::string text(plain.begin(), plain.end());
    EngineBridge::Instance().LearningLoadText(text);
    LogF("Learning loaded %d bytes", (int)text.size());
}

void CTextService::SaveLearningFile() {
    std::wstring path = LearningPath();
    if (path.empty()) return;
    std::string text = EngineBridge::Instance().LearningDump();
    if (text.empty()) return;
    std::vector<BYTE> plain(text.begin(), text.end());
    std::vector<BYTE> sealed;
    if (!DpapiProtect(plain, sealed)) return;  // 加不了密宁可不存，也不落明文
    FILE* f = _wfopen(path.c_str(), L"wb");
    if (!f) return;
    fwrite(sealed.data(), 1, sealed.size(), f);
    fclose(f);
}

void CTextService::LoadConfig() {
    InvalidateDataDir();                     // 设置里可能刚改过数据目录
    std::wstring dir = ResolveDataDir();
    if (dir.empty()) return;
    std::wstring path = FirstExisting(dir + L"\\ime.ini", DefaultDataDir() + L"\\ime.ini");
    _iniPath = path;   // 按键热重载靠这个缓存路径
    WIN32_FILE_ATTRIBUTE_DATA fad = {};
    if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fad)) {
        _iniStamp = ((ULONGLONG)fad.ftLastWriteTime.dwHighDateTime << 32) | fad.ftLastWriteTime.dwLowDateTime;
    }
    FILE* f = _wfopen(path.c_str(), L"rb");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        std::string s(line);
        while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) s.pop_back();
        size_t eq = s.find('=');
        if (eq == std::string::npos) continue;
        std::string k = s.substr(0, eq);
        std::string v = s.substr(eq + 1);
        if (k == "candidates") {
            int c = atoi(v.c_str());
            if (c >= 3 && c <= 9) _candidateLimit = c;
        } else if (k == "fuzzy") {
            _fuzzy = (v == "1" || v == "true");
        } else if (k == "sentence") {
            _sentence = (v == "1" || v == "true");
        } else if (k == "learn") {
            _learn = (v == "1" || v == "true");
        } else if (k == "traditional") {
            _traditional = (v == "1" || v == "true");
        } else if (k == "english") {
            _englishSuggest = (v == "1" || v == "true");
        } else if (k == "theme") {
            _themeSystem = (v == "system");
            _themeDark = _themeSystem ? SystemDarkMode() : (v == "dark");
        } else if (k == "accent") {
            _accent = ParseColor(v, _accent);
        } else if (k == "palette") {
            _paletteOn = (v == "1" || v == "true");
        } else if (k == "bg") {
            _bg = ParseColor(v, _bg);
        } else if (k == "fg") {
            _fg = ParseColor(v, _fg);
        } else if (k == "border") {
            _border = ParseColor(v, _border);
        }
    }
    fclose(f);
    _pageSize = _candidateLimit;
    EngineBridge::Instance().SetOptions(_fuzzy, _sentence, _learn);
    ApplyWindowStyle();
    LogF("Config cand=%d fuzzy=%d sentence=%d learn=%d theme=%d", _candidateLimit,
         _fuzzy ? 1 : 0, _sentence ? 1 : 0, _learn ? 1 : 0, _themeDark ? 1 : 0);
}

// 按键时走这条轻量路径：只比对 ime.ini 的修改时间，变了才读文件
bool CTextService::MaybeReloadConfigFast() {
    if (_iniPath.empty()) return false;
    WIN32_FILE_ATTRIBUTE_DATA fad = {};
    if (!GetFileAttributesExW(_iniPath.c_str(), GetFileExInfoStandard, &fad)) return false;
    ULONGLONG stamp = ((ULONGLONG)fad.ftLastWriteTime.dwHighDateTime << 32) | fad.ftLastWriteTime.dwLowDateTime;
    if (stamp == _iniStamp) return false;
    LoadConfig();
    LogF("Config reloaded on key: cand=%d fuzzy=%d sentence=%d learn=%d", _candidateLimit,
         _fuzzy ? 1 : 0, _sentence ? 1 : 0, _learn ? 1 : 0);
    return true;
}

// 设置页改完 ime.ini 后，切回应用时按文件时间戳自动重载，不用重启输入法
bool CTextService::MaybeReloadConfig() {
    InvalidateDataDir();   // 数据目录本身也可能刚被改过
    if (_themeSystem) {    // 跟随系统时，切回程序顺便看一下系统明暗有没有变
        _themeDark = SystemDarkMode();
        ApplyWindowStyle();
    }
    std::wstring dir = ResolveDataDir();
    if (dir.empty()) return false;
    std::wstring path = FirstExisting(dir + L"\\ime.ini", DefaultDataDir() + L"\\ime.ini");
    WIN32_FILE_ATTRIBUTE_DATA fad = {};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fad)) return false;
    ULONGLONG stamp = ((ULONGLONG)fad.ftLastWriteTime.dwHighDateTime << 32) | fad.ftLastWriteTime.dwLowDateTime;
    if (stamp == _iniStamp) return false;
    LoadConfig();
    ApplyWindowStyle();
    return true;
}

void CTextService::UpdateCandidates() {
    _cands.clear();
    // 能匹配到多少就取多少，翻页翻到底；上限只是兜底（实测 a=1893、shi=2408、单字母前缀上万）
    const int fetch = 3000;
    if (_chinese) {
        _cands = EngineBridge::Instance().Candidates(_pinyin, fetch);
    } else {
        for (auto& w : EngineBridge::Instance().EnglishSuggest(_pinyin, fetch)) {
            _cands.push_back({ w, 0 });
        }
    }
    _sel = 0;
    LogF("UpdateCandidates py=%s n=%d", _pinyin.c_str(), (int)_cands.size());
}

void CTextService::RefreshWindow() {
    LogF("RefreshWindow py=%s n=%d", _pinyin.c_str(), (int)_cands.size());
    if (_pinyin.empty() || _cands.empty()) {
        _window.Hide();
        return;
    }
    RECT anchor = {};
    if (!GetCaretRect(anchor)) {
        LogLine("RefreshWindow caret fail");
        _window.Hide();
        return;
    }
    LogF("RefreshWindow caret ok %ld,%ld", (long)anchor.left, (long)anchor.top);
    int count = PageItems();
    if (count <= 0) {
        _window.Hide();
        return;
    }
    std::vector<std::wstring> items;
    items.reserve(count);
    for (int i = PageStart(); i < PageStart() + count; ++i) {
        const std::wstring& w = _cands[i].word;
        items.push_back((_traditional && _chinese) ? EngineBridge::Instance().ToTraditional(w) : w);
    }
    std::wstring pageText;
    int pages = PageCount();
    int page = PageStart() / (_pageSize > 0 ? _pageSize : 1);
    if (pages > 1) pageText = std::to_wstring(page + 1) + L"/" + std::to_wstring(pages);
    _window.Show(anchor, ModeText(), Utf8ToWide(_pinyin), items, _sel - PageStart(), pageText);
}

void CTextService::CommitSelected() {
    int global = _cands.empty() ? -1 : std::min(_sel, (int)_cands.size() - 1);
    if (_chinese) {
        if (global < 0) return;
        const std::wstring& raw = _cands[global].word;
        EngineBridge::Instance().Learn(_pinyin, raw, global);
        SaveLearningFile();  // 选完就落盘（加密），不靠退出时保存
        std::wstring word = _traditional ? EngineBridge::Instance().ToTraditional(raw) : raw;
        CommitText(word);
    } else {
        std::wstring word;
        if (global >= 0) {
            word = _cands[global].word;
        } else {
            word = Utf8ToWide(_pinyin);
        }
        CommitText(word);
    }
    ResetComposition();
}

void CTextService::CommitText(const std::wstring& text) {
    if (!_context || text.empty()) return;
    CInsertSession* session = new CInsertSession(_context, text);
    HRESULT hr = S_OK;
    _context->RequestEditSession(_clientId, session, TF_ES_SYNC | TF_ES_READWRITE, &hr);
    session->Release();
}

class CCaretSession : public ITfEditSession {
public:
    CCaretSession(ITfContext* ctx) : _ctx(ctx) { if (_ctx) _ctx->AddRef(); }
    ~CCaretSession() { if (_ctx) _ctx->Release(); }
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_INVALIDARG;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession)) {
            *ppv = static_cast<ITfEditSession*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return (ULONG)InterlockedIncrement(&_ref); }
    STDMETHODIMP_(ULONG) Release() override {
        ULONG r = (ULONG)InterlockedDecrement(&_ref);
        if (r == 0) delete this;
        return r;
    }
    STDMETHODIMP DoEditSession(TfEditCookie ec) override {
        TF_SELECTION sel = {};
        ULONG n = 0;
        if (FAILED(_ctx->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &n)) || n != 1) return S_OK;
        ITfContextView* view = nullptr;
        if (SUCCEEDED(_ctx->GetActiveView(&view)) && view) {
            BOOL clipped = FALSE;
            RECT rc = {};
            if (SUCCEEDED(view->GetTextExt(ec, sel.range, &rc, &clipped))) {
                _rect = rc;
                _ok = true;
            }
            view->Release();
        }
        sel.range->Release();
        return S_OK;
    }
    bool ok() const { return _ok; }
    RECT rect() const { return _rect; }
private:
    LONG _ref = 1;
    ITfContext* _ctx = nullptr;
    RECT _rect = {};
    bool _ok = false;
};

bool CTextService::GetCaretRect(RECT& out) {
    if (_context) {
        CCaretSession* s = new CCaretSession(_context);
        HRESULT hr = S_OK;
        _context->RequestEditSession(_clientId, s, TF_ES_SYNC | TF_ES_READ, &hr);
        bool ok = s->ok();
        RECT rc = s->rect();
        s->Release();
        if (ok && (rc.right > rc.left || rc.bottom > rc.top)) {
            out = rc;
            LogF("caret textExt %ld,%ld", (long)rc.left, (long)rc.top);
            return true;
        }
    }
    GUITHREADINFO gti = { sizeof(gti) };
    if (GetGUIThreadInfo(GetCurrentThreadId(), &gti) && gti.hwndCaret) {
        POINT tl = { gti.rcCaret.left, gti.rcCaret.top };
        POINT br = { gti.rcCaret.right, gti.rcCaret.bottom };
        ClientToScreen(gti.hwndCaret, &tl);
        ClientToScreen(gti.hwndCaret, &br);
        RECT r = { tl.x, tl.y, br.x, br.y };
        if (r.right > r.left || r.bottom > r.top) {
            out = r;
            LogF("caret gti %ld,%ld", (long)r.left, (long)r.top);
            return true;
        }
    }
    HWND fg = GetForegroundWindow();
    if (fg) {
        RECT w = {};
        GetWindowRect(fg, &w);
        out.left = w.left + 120;
        out.top = w.top + 80;
        out.right = out.left;
        out.bottom = out.top;
        LogF("caret window fallback %ld,%ld", (long)out.left, (long)out.top);
        return true;
    }
    return false;
}

// ------------------------------------------------------------------ Class factory

namespace {
class CClassFactory : public IClassFactory {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_INVALIDARG;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IClassFactory)) {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return (ULONG)InterlockedIncrement(&_ref); }
    STDMETHODIMP_(ULONG) Release() override {
        ULONG r = (ULONG)InterlockedDecrement(&_ref);
        if (r == 0) delete this;
        return r;
    }
    STDMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
        LogLine("CreateInstance enter");
        if (outer) return CLASS_E_NOAGGREGATION;
        auto* svc = new CTextService();
        LogLine("CreateInstance constructed");
        HRESULT hr = svc->QueryInterface(riid, ppv);
        svc->Release();
        return hr;
    }
    STDMETHODIMP LockServer(BOOL) override { return S_OK; }
private:
    LONG _ref = 1;
};
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
    if (!IsEqualCLSID(rclsid, CLSID_HorseBoxIme)) return CLASS_E_CLASSNOTAVAILABLE;
    CClassFactory* factory = new CClassFactory();
    HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

STDAPI DllCanUnloadNow() {
    return S_FALSE;
}
