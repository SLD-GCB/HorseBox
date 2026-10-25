#include "CandidateWindow.h"
#include <algorithm>
#include <gdiplus.h>

using namespace Gdiplus;

static const WCHAR* kClassName = L"HorseBoxCandidateWnd";

// 圆角矩形路径
static void AddRoundRect(GraphicsPath& path, REAL x, REAL y, REAL w, REAL h, REAL r) {
    if (r * 2 > w) r = w / 2;
    if (r * 2 > h) r = h / 2;
    if (r <= 0) {
        path.AddRectangle(RectF(x, y, w, h));
        return;
    }
    REAL d = r * 2;
    path.AddArc(x, y, d, d, 180, 90);
    path.AddArc(x + w - d, y, d, d, 270, 90);
    path.AddArc(x + w - d, y + h - d, d, d, 0, 90);
    path.AddArc(x, y + h - d, d, d, 90, 90);
    path.CloseFigure();
}

// 胶囊判定：左右各半个圆 + 中间矩形
static bool InsideCapsule(int x, int y, int w, int h, int r) {
    if (x < 0 || y < 0 || x >= w || y >= h) return false;
    if (x >= r && x < w - r) return true;
    int cx = (x < r) ? r : (w - r - 1);
    int cy = h / 2;
    int dx = x - cx;
    int dy = y - cy;
    return dx * dx + dy * dy <= r * r;
}

void CandidateWindow::Create(HINSTANCE hinst) {
    GdiplusStartupInput gdiplusInput;
    GdiplusStartup(&_gdiplusToken, &gdiplusInput, nullptr);

    WNDCLASSEXW wc = { sizeof(wc) };
    wc.lpfnWndProc = CandidateWindow::WndProc;
    wc.hInstance = hinst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kClassName;
    RegisterClassExW(&wc);  // 已注册会失败，忽略

    // 分层窗口 + 逐像素 alpha，才能画出柔和的圆角
    _hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_LAYERED,
        kClassName, L"", WS_POPUP,
        0, 0, 0, 0, nullptr, nullptr, hinst, nullptr);
    if (_hwnd) {
        SetWindowLongPtrW(_hwnd, GWLP_USERDATA, (LONG_PTR)this);
    }

    _font = CreateFontW(-20, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");
    _small = CreateFontW(-14, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");
}

void CandidateWindow::ApplyStyle(bool dark, bool custom, COLORREF bg, COLORREF fg,
                                  COLORREF border, COLORREF accent) {
    _dark = dark;
    _custom = custom;
    _bg = custom ? bg : (dark ? RGB(40, 40, 40) : RGB(250, 250, 250));
    _fg = custom ? fg : (dark ? RGB(235, 235, 235) : RGB(30, 30, 30));
    _border = custom ? border : (dark ? RGB(90, 90, 90) : RGB(160, 160, 160));
    _accent = accent;
    if (_hwnd && _visible) InvalidateRect(_hwnd, nullptr, TRUE);
}

// 把前景色朝背景色混，得到次要文字的颜色
static COLORREF Mix(COLORREF a, COLORREF b, int percentB) {
    int rb = GetRValue(a) * (100 - percentB) / 100 + GetRValue(b) * percentB / 100;
    int gb = GetGValue(a) * (100 - percentB) / 100 + GetGValue(b) * percentB / 100;
    int bb = GetBValue(a) * (100 - percentB) / 100 + GetBValue(b) * percentB / 100;
    return RGB(rb, gb, bb);
}

void CandidateWindow::Destroy() {
    if (_hwnd) {
        DestroyWindow(_hwnd);
        _hwnd = nullptr;
    }
    if (_dib) { DeleteObject(_dib); _dib = nullptr; }
    if (_memDc) { DeleteDC(_memDc); _memDc = nullptr; }
    _dibBits = nullptr;
    if (_font) { DeleteObject(_font); _font = nullptr; }
    if (_small) { DeleteObject(_small); _small = nullptr; }
    if (_gdiplusToken) { GdiplusShutdown(_gdiplusToken); _gdiplusToken = 0; }
    _visible = false;
}

void CandidateWindow::Recalc() {
    if (!_hwnd) return;
    HDC hdc = GetDC(_hwnd);
    SelectObject(hdc, _small);
    SIZE ps = { 0, 0 };
    GetTextExtentPoint32W(hdc, _pinyin.c_str(), (int)_pinyin.size(), &ps);
    SIZE ms = { 0, 0 };
    GetTextExtentPoint32W(hdc, _mode.c_str(), (int)_mode.size(), &ms);
    SIZE gs = { 0, 0 };
    if (!_pageText.empty()) GetTextExtentPoint32W(hdc, _pageText.c_str(), (int)_pageText.size(), &gs);
    SelectObject(hdc, _font);
    int x = 16;
    int maxH = 18;
    for (auto& label : _labels) {
        SIZE sz = { 0, 0 };
        GetTextExtentPoint32W(hdc, label.c_str(), (int)label.size(), &sz);
        x += sz.cx + 16;
        maxH = std::max(maxH, (int)sz.cy);
    }
    ReleaseDC(_hwnd, hdc);
    int topW = 16 + (int)ms.cx + 14 + 8 + (int)ps.cx + 10 + (int)gs.cx + 16;
    _w = std::max(std::max(x + 16, topW), (int)ps.cx + 44);
    // 顶行（徽标 + 拼音 + 页码）的实际高度，候选那一行从它下面开始，别压在一起
    int topBottom = 4 + std::max(20, (int)ms.cy + 8);
    _h = topBottom + 4 + maxH + 8;
}

void CandidateWindow::UpdateWindowPos(const RECT& anchor) {
    if (!_hwnd) return;
    MONITORINFO mi = { sizeof(mi) };
    HMONITOR mon = MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST);
    GetMonitorInfoW(mon, &mi);

    int x = anchor.left;
    int y = anchor.bottom + 4;  // 始终在文字下方，不再翻到上面
    if (x + _w > mi.rcWork.right) x = mi.rcWork.right - _w;
    if (x < mi.rcWork.left) x = mi.rcWork.left;

    SetWindowPos(_hwnd, HWND_TOPMOST, x, y, _w, _h,
        SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(_hwnd, nullptr, TRUE);
}

void CandidateWindow::Show(const RECT& anchor, const std::wstring& modeText, const std::wstring& pinyin,
                           const std::vector<std::wstring>& items, int sel, const std::wstring& pageText) {
    if (!_hwnd) return;
    KillTimer(_hwnd, 1);
    _mode = modeText;
    _pinyin = pinyin;
    _pageText = pageText;
    _items = items;
    _sel = sel;
    _labels.clear();
    for (int i = 0; i < (int)items.size(); ++i) {
        _labels.push_back(std::to_wstring(i + 1) + L"  " + items[i]);
    }
    Recalc();
    UpdateWindowPos(anchor);
    if (!_visible) {
        ShowWindow(_hwnd, SW_SHOWNOACTIVATE);
        _visible = true;
    }
    InvalidateRect(_hwnd, nullptr, TRUE);
}

void CandidateWindow::ShowMode(const std::wstring& text) {
    if (!_hwnd) return;
    KillTimer(_hwnd, 1);
    _pinyin = text;
    _mode.clear();
    _items.clear();
    _labels.clear();
    _sel = 0;
    Recalc();
    RECT work = {};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int x = work.right - _w - 20;
    int y = work.bottom - _h - 16;
    if (x < work.left) x = work.left;
    if (y < work.top) y = work.top;
    SetWindowPos(_hwnd, HWND_TOPMOST, x, y, _w, _h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    ShowWindow(_hwnd, SW_SHOWNOACTIVATE);
    _visible = true;
    InvalidateRect(_hwnd, nullptr, TRUE);
    SetTimer(_hwnd, 1, 1200, nullptr);
}

void CandidateWindow::Hide() {
    if (_hwnd && _visible) {
        ShowWindow(_hwnd, SW_HIDE);
        _visible = false;
    }
}

LRESULT CALLBACK CandidateWindow::WndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT) {
        auto* self = (CandidateWindow*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (self) return self->OnPaint();
    }
    if (msg == WM_TIMER) {
        auto* self = (CandidateWindow*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (self) self->Hide();
        KillTimer(hwnd, 1);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, w, l);
}

LRESULT CandidateWindow::OnPaint() {
    PAINTSTRUCT ps;
    HDC hdcWin = BeginPaint(_hwnd, &ps);
    RECT wr;
    GetClientRect(_hwnd, &wr);
    const int W = wr.right;
    const int H = wr.bottom;
    if (W <= 0 || H <= 0) {
        EndPaint(_hwnd, &ps);
        return 0;
    }

    // 复用 32 位 DIB
    if (!_memDc) _memDc = CreateCompatibleDC(hdcWin);
    if (!_dib || _dibW != W || _dibH != H) {
        if (_dib) { DeleteObject(_dib); _dib = nullptr; }
        BITMAPINFO bi = {};
        bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bi.bmiHeader.biWidth = W;
        bi.bmiHeader.biHeight = -H;   // 自上而下
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        _dib = CreateDIBSection(_memDc, &bi, DIB_RGB_COLORS, &_dibBits, nullptr, 0);
        _dibW = W;
        _dibH = H;
    }
    HGDIOBJ oldBmp = SelectObject(_memDc, _dib);
    ZeroMemory(_dibBits, (size_t)W * H * 4);
    SetBkMode(_memDc, TRANSPARENT);

    // ---- 先量字，再画形状 ----
    SelectObject(_memDc, _small);
    SIZE ms = { 0, 0 };
    GetTextExtentPoint32W(_memDc, _mode.c_str(), (int)_mode.size(), &ms);
    SIZE gs = { 0, 0 };
    if (!_pageText.empty()) GetTextExtentPoint32W(_memDc, _pageText.c_str(), (int)_pageText.size(), &gs);

    RECT mr = { 16, 4, 16 + ms.cx + 14, 4 + ms.cy + 8 };
    RECT pr = { mr.right + 8, 4, W - 16 - (int)gs.cx - 6, 4 + 20 };
    RECT gr = { W - 16 - (int)gs.cx, 4, W - 16, 4 + 20 };

    std::vector<RECT> itemRects;
    SelectObject(_memDc, _font);
    int x = 16;
    int y = 4 + std::max(20, (int)ms.cy + 8) + 4;   // 顶行（徽标）下方再留 4px
    for (auto& label : _labels) {
        SIZE sz = { 0, 0 };
        GetTextExtentPoint32W(_memDc, label.c_str(), (int)label.size(), &sz);
        RECT ir = { x, y, x + sz.cx, y + sz.cy };
        itemRects.push_back(ir);
        x += sz.cx + 16;
    }

    // ---- 形状（GDI+，带抗锯齿）----
    {
        Graphics g(_memDc);
        g.SetSmoothingMode(SmoothingModeAntiAlias);
        const REAL radius = H / 2.0f;   // 胶囊：半径等于半个高度

        GraphicsPath capsule;
        AddRoundRect(capsule, 0.5f, 0.5f, (REAL)W - 1, (REAL)H - 1, radius - 0.5f);
        SolidBrush bgBrush(Color(255, GetRValue(_bg), GetGValue(_bg), GetBValue(_bg)));
        g.FillPath(&bgBrush, &capsule);
        Pen borderPen(Color(255, GetRValue(_border), GetGValue(_border), GetBValue(_border)), 1.0f);
        g.DrawPath(&borderPen, &capsule);

        // 模式徽标
        if (!_mode.empty()) {
            GraphicsPath badge;
            REAL bh = (REAL)(mr.bottom - mr.top);
            AddRoundRect(badge, (REAL)mr.left, (REAL)mr.top, (REAL)(mr.right - mr.left), bh, bh / 2);
            COLORREF modeCol = RGB(0, 120, 215);
            if (_mode == L"繁") modeCol = RGB(230, 120, 20);
            else if (_mode == L"英") modeCol = RGB(40, 160, 80);
            SolidBrush badgeBrush(Color(255, GetRValue(modeCol), GetGValue(modeCol), GetBValue(modeCol)));
            g.FillPath(&badgeBrush, &badge);
        }

        // 选中候选的高亮块
        if (_sel >= 0 && _sel < (int)itemRects.size()) {
            RECT ir = itemRects[_sel];
            GraphicsPath chip;
            REAL cw = (REAL)(ir.right - ir.left) + 12;
            REAL ch = (REAL)(ir.bottom - ir.top) + 8;
            AddRoundRect(chip, (REAL)ir.left - 6, (REAL)ir.top - 4, cw, ch, ch / 2);
            SolidBrush chipBrush(Color(255, GetRValue(_accent), GetGValue(_accent), GetBValue(_accent)));
            g.FillPath(&chipBrush, &chip);
        }
    }

    // ---- 文字（GDI，字号和量出来的宽度一致）----
    SelectObject(_memDc, _small);
    if (!_mode.empty()) {
        SetTextColor(_memDc, RGB(255, 255, 255));
        DrawTextW(_memDc, _mode.c_str(), -1, &mr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    SetTextColor(_memDc, _custom ? _fg : Mix(_fg, _bg, 50));
    DrawTextW(_memDc, _pinyin.c_str(), -1, &pr, DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    if (!_pageText.empty()) {
        SetTextColor(_memDc, Mix(_fg, _bg, 55));
        DrawTextW(_memDc, _pageText.c_str(), -1, &gr, DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
    }

    SelectObject(_memDc, _font);
    int lum = (GetRValue(_accent) * 299 + GetGValue(_accent) * 587 + GetBValue(_accent) * 114) / 1000;
    for (int i = 0; i < (int)itemRects.size(); ++i) {
        if (i == _sel) {
            SetTextColor(_memDc, lum > 150 ? RGB(20, 20, 20) : RGB(255, 255, 255));
        } else {
            SetTextColor(_memDc, _fg);
        }
        DrawTextW(_memDc, _labels[i].c_str(), -1, &itemRects[i],
                  DT_LEFT | DT_SINGLELINE | DT_VCENTER);
    }

    // ---- 修 alpha：GDI 画的字没带 alpha；胶囊外的像素一律清掉 ----
    BYTE* px = (BYTE*)_dibBits;
    const int radius = H / 2;
    for (int yy = 0; yy < H; ++yy) {
        for (int xx = 0; xx < W; ++xx) {
            BYTE* p = px + ((size_t)yy * W + xx) * 4;
            if (!InsideCapsule(xx, yy, W, H, radius)) {
                p[0] = p[1] = p[2] = p[3] = 0;
            } else if (p[3] == 0) {
                p[3] = 255;
            }
        }
    }

    POINT dst = { 0, 0 };
    RECT wrc;
    GetWindowRect(_hwnd, &wrc);
    dst.x = wrc.left;
    dst.y = wrc.top;
    SIZE size = { W, H };
    POINT src = { 0, 0 };
    BLENDFUNCTION bf = { AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    UpdateLayeredWindow(_hwnd, hdcWin, &dst, &size, _memDc, &src, 0, &bf, ULW_ALPHA);

    SelectObject(_memDc, oldBmp);
    EndPaint(_hwnd, &ps);
    return 0;
}
