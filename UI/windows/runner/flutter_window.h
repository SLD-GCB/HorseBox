#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 托盘图标：关闭窗口时隐藏到托盘，代理继续在后台运行。
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowFromTray();
  void ShowTrayMenu();

  bool tray_added_ = false;
  bool balloon_shown_ = false;
  bool force_quit_ = false;
  UINT taskbar_created_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
