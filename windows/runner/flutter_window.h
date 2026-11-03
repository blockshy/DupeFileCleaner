#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"
#include "windows_bridge.h"

// 承载 Flutter 视图及 Windows 文件服务的桌面主窗口。
class FlutterWindow : public Win32Window {
 public:
  // 使用指定 Dart 工程创建主窗口，实际引擎初始化在 OnCreate 中执行。
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // 实现 Win32 窗口生命周期与消息分发。
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 与窗口绑定的 Dart 工程配置。
  flutter::DartProject project_;

  // 窗口内运行的 Flutter 引擎及视图控制器。
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 原生文件服务必须先于 Flutter 引擎释放，以便安全结束工作线程和回调。
  std::unique_ptr<WindowsBridge> windows_bridge_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
