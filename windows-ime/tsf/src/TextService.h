#pragma once
#include "Globals.h"
#include <ctfutb.h>
#include "EngineBridge.h"
#include "CandidateWindow.h"
#include <string>
#include <vector>

class CTextService : public ITfTextInputProcessor,
                     public ITfThreadMgrEventSink,
                     public ITfKeyEventSink,
                     public ITfLangBarItemButton,
                     public ITfSource {
public:
    CTextService();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfTextInputProcessor
    STDMETHODIMP Activate(ITfThreadMgr* ptim, TfClientId tid) override;
    STDMETHODIMP Deactivate() override;

    // ITfThreadMgrEventSink
    STDMETHODIMP OnInitDocumentMgr(ITfDocumentMgr* pdim) override { return S_OK; }
    STDMETHODIMP OnUninitDocumentMgr(ITfDocumentMgr* pdim) override { return S_OK; }
    STDMETHODIMP OnSetFocus(ITfDocumentMgr* pdimFocus, ITfDocumentMgr* pdimPrevFocus) override;
    STDMETHODIMP OnPushContext(ITfContext* pic) override;
    STDMETHODIMP OnPopContext(ITfContext* pic) override;

    // ITfKeyEventSink
    STDMETHODIMP OnSetFocus(BOOL fForeground) override { return S_OK; }
    STDMETHODIMP OnTestKeyDown(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten) override;
    STDMETHODIMP OnTestKeyUp(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten) override {
        *pfEaten = FALSE;
        return S_OK;
    }
    STDMETHODIMP OnKeyDown(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten) override;
    STDMETHODIMP OnKeyUp(ITfContext* pic, WPARAM wParam, LPARAM lParam, BOOL* pfEaten) override;
    STDMETHODIMP OnPreservedKey(ITfContext* pic, REFGUID rguid, BOOL* pfEaten) override {
        *pfEaten = FALSE;
        return S_OK;
    }

    // ITfLangBarItem
    STDMETHODIMP GetInfo(TF_LANGBARITEMINFO* pInfo) override;
    STDMETHODIMP GetStatus(DWORD* pdwStatus) override;
    STDMETHODIMP Show(BOOL fShow) override;
    STDMETHODIMP GetTooltipString(BSTR* pbstrToolTip) override;

    // ITfLangBarItemButton
    STDMETHODIMP OnClick(TfLBIClick click, POINT pt, const RECT* prcArea) override;
    STDMETHODIMP InitMenu(ITfMenu* pMenu) override;
    STDMETHODIMP OnMenuSelect(UINT wID) override;
    STDMETHODIMP GetIcon(HICON* phIcon) override;
    STDMETHODIMP GetText(BSTR* pbstrText) override;

    // ITfSource (for language bar item sink)
    STDMETHODIMP AdviseSink(REFIID riid, IUnknown* punk, DWORD* pdwCookie) override;
    STDMETHODIMP UnadviseSink(DWORD dwCookie) override;

private:
    ~CTextService();

    void UpdateContext();
    void ApplyMode();
    void CycleMode();
    void SetCompartment();
    std::wstring ModeText() const;
    void LoadConfig();
    void ApplyWindowStyle();
    bool MaybeReloadConfig();
    bool MaybeReloadConfigFast();   // 按键时只比对已缓存路径的时间戳
    std::wstring LearningPath() const;
    void LoadLearningFile();
    void SaveLearningFile();
    int PageItems() const;
    int PageStart() const;
    bool HasNextPage() const;
    int PageCount() const;
    void ResetComposition();
    void UpdateCandidates();
    void RefreshWindow();
    void CommitSelected();
    void CommitText(const std::wstring& text);
    bool GetCaretRect(RECT& out);
    std::wstring AppDir() const;

    LONG _ref = 1;
    ITfThreadMgr* _threadMgr = nullptr;
    TfClientId _clientId = TF_CLIENTID_NULL;
    ITfDocumentMgr* _docMgr = nullptr;
    ITfContext* _context = nullptr;
    DWORD _sinkCookie = TF_INVALID_COOKIE;
    DWORD _keyCookie = TF_INVALID_COOKIE;

    bool _chinese = true;
    int _mode = 0;  // 0=简, 1=繁, 2=英
    bool _shiftDown = false;
    bool _shiftUsed = false;
    bool _traditional = false;
    bool _themeDark = false;
    bool _themeSystem = false;      // theme=system 时跟随 Windows 应用模式
    bool _paletteOn = false;        // 自定义整套颜色
    COLORREF _accent = RGB(0, 120, 215);
    COLORREF _bg = RGB(27, 28, 30);
    COLORREF _fg = RGB(237, 237, 239);
    COLORREF _border = RGB(90, 90, 90);
    int _candidateLimit = 6;
    int _pageSize = 6;      // 一页显示几个，等于 _candidateLimit
    int _quoteToggle = 0;   // 中文引号成对出现
    bool _fuzzy = true;
    bool _sentence = true;
    bool _learn = true;
    bool _englishSuggest = false;   // 英文模式是否也出候选框
    ULONGLONG _iniStamp = 0;
    std::wstring _iniPath;
    std::string _pinyin;
    std::vector<EngCandidate> _cands;
    int _sel = 0;   // 全局下标，所在页由它推导

    ITfLangBarItemMgr* _langBarMgr = nullptr;
    ITfLangBarItemSink* _langBarSink = nullptr;
    HICON _modeIcons[3] = { nullptr, nullptr, nullptr };
    void EnsureModeIcons();
    CandidateWindow _window;
};
