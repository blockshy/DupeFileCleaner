#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // 初始渲染表面与客户区尺寸一致，避免启动期间重复创建或销毁表面。
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // 确认引擎与视图初始化成功后，再注册平台插件和文件服务。
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  windows_bridge_ = std::make_unique<WindowsBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // 首帧可能早于显示回调完成，主动请求绘制以保证窗口最终显示。
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  windows_bridge_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 清理结果只能在窗口线程交回 Flutter。忙碌时关闭窗口会打断日志写入，
  // 因此要求用户先在界面取消任务，待当前文件操作结束后再关闭。
  if (windows_bridge_) {
    if (windows_bridge_->HandleMessage(message, wparam, lparam)) return 0;
    if (message == WM_CLOSE && windows_bridge_->IsBusy()) {
      MessageBoxW(hwnd, L"任务正在执行。请先在界面中取消，等待任务结束后再关闭。",
                  L"重复文件清理", MB_OK | MB_ICONINFORMATION);
      return 0;
    }
  }
  if (message == WM_GETMINMAXINFO) {
    // 保证桌面表格在较小窗口下仍有足够空间；Flutter 内部同时支持滚动。
    auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
    const UINT dpi = GetDpiForWindow(hwnd);
    limits->ptMinTrackSize.x = MulDiv(1080, static_cast<int>(dpi ? dpi : 96), 96);
    limits->ptMinTrackSize.y = MulDiv(720, static_cast<int>(dpi ? dpi : 96), 96);
    return 0;
  }
  // 应用自定义消息处理完成后，将其余消息交给 Flutter 及已注册插件。
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
