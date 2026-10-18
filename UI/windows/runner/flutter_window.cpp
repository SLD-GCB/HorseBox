#include "flutter_window.h"

#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuShow = 1;
constexpr UINT kMenuQuit = 2;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::AddTrayIcon() {
  if (tray_added_) {
    return;
  }

  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIconW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  if (data.hIcon == nullptr) {
    data.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  }
  lstrcpynW(data.szTip, L"HorseBox - 代理运行中", ARRAYSIZE(data.szTip));

  if (Shell_NotifyIconW(NIM_ADD, &data)) {
    tray_added_ = true;
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) {
    return;
  }

  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_added_ = false;
}

void FlutterWindow::ShowFromTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  ShowWindow(hwnd, SW_SHOW);
  ShowWindow(hwnd, SW_RESTORE);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  POINT cursor = {};
  GetCursorPos(&cursor);

  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kMenuShow, L"显示主界面");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuQuit, L"退出 HorseBox");

  // 不先把窗口拉到前台，点菜单外面时菜单不会自动消失。
  SetForegroundWindow(hwnd);
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, hwnd,
      nullptr);
  DestroyMenu(menu);
  PostMessageW(hwnd, WM_NULL, 0, 0);

  if (command == kMenuShow) {
    ShowFromTray();
  } else if (command == kMenuQuit) {
    force_quit_ = true;
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    // Explorer 重启后托盘图标会消失，需要重新注册。
    tray_added_ = false;
    AddTrayIcon();
    return 0;
  }

  if (message == kTrayMessage) {
    switch (static_cast<UINT>(lparam)) {
      case WM_LBUTTONDBLCLK:
      case WM_LBUTTONUP:
        ShowFromTray();
        break;
      case WM_RBUTTONUP:
        ShowTrayMenu();
        break;
      default:
        break;
    }
    return 0;
  }

  if (message == WM_CLOSE && !force_quit_) {
    // 点关闭按钮只隐藏窗口，Flutter 和代理继续在后台运行。
    ShowWindow(hwnd, SW_HIDE);
    if (!balloon_shown_) {
      balloon_shown_ = true;
      NOTIFYICONDATAW data = {};
      data.cbSize = sizeof(data);
      data.hWnd = hwnd;
      data.uID = kTrayIconId;
      data.uFlags = NIF_INFO;
      data.dwInfoFlags = NIIF_INFO;
      lstrcpynW(data.szInfoTitle, L"HorseBox", ARRAYSIZE(data.szInfoTitle));
      lstrcpynW(data.szInfo, L"已最小化到托盘，代理继续运行",
                ARRAYSIZE(data.szInfo));
      Shell_NotifyIconW(NIM_MODIFY, &data);
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
