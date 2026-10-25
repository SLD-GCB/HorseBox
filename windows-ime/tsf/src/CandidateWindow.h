#pragma once
#include <windows.h>
#include <string>
#include <vector>

class CandidateWindow {
public:
    void Create(HINSTANCE hinst);
    void Destroy();

    // anchor：光标屏幕矩形。pinyin：顶行。items：候选。sel：选中下标。pageText：页码（如 1/3）。
    void Show(const RECT& anchor, const std::wstring& modeText, const std::wstring& pinyin,
              const std::vector<std::wstring>& items, int sel, const std::wstring& pageText = L"");
    void ShowMode(const std::wstring& text);
    void Hide();
    bool Visible() const { return _visible; }
    // 主题 + 配色：dark 决定默认色；custom 为真时用 bg/fg/border 三色
    void ApplyStyle(bool dark, bool custom, COLORREF bg, COLORREF fg, COLORREF border, COLORREF accent);
    void SetTheme(bool dark) { ApplyStyle(dark, false, 0, 0, 0, _accent); }

private:
    static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
    LRESULT OnPaint();
    void Recalc();
    void UpdateWindowPos(const RECT& anchor);

    HWND _hwnd = nullptr;
    bool _visible = false;
    bool _dark = false;
    bool _custom = false;
    COLORREF _bg = RGB(250, 250, 250);
    COLORREF _fg = RGB(30, 30, 30);
    COLORREF _border = RGB(160, 160, 160);
    COLORREF _accent = RGB(0, 120, 215);
    std::wstring _mode;
    std::wstring _pinyin;
    std::wstring _pageText;
    std::vector<std::wstring> _items;
    std::vector<std::wstring> _labels;
    int _sel = 0;
    int _w = 0;
    int _h = 0;
    HFONT _font = nullptr;
    HFONT _small = nullptr;
    ULONG_PTR _gdiplusToken = 0;
    void* _dibBits = nullptr;   // 复用 32 位 DIB，避免每次绘制都分配
    HBITMAP _dib = nullptr;
    HDC _memDc = nullptr;
    int _dibW = 0;
    int _dibH = 0;
};
