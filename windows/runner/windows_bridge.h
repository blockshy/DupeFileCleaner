#ifndef RUNNER_WINDOWS_BRIDGE_H_
#define RUNNER_WINDOWS_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <thread>

// Windows 文件操作适配层。Dart 负责界面与扫描，本类只提供需要原生句柄、
// Shell 对话框或文件系统身份的能力；耗时清理始终在独立工作线程上执行。
class WindowsBridge {
 public:
  static constexpr UINT kReplyMessage = WM_APP + 73;

  WindowsBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsBridge();

  // 在创建本适配层的窗口线程中分发结果，避免从工作线程调用 Flutter 回调。
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  bool IsBusy() const { return busy_ || cleaning_.load(); }

 private:
  void OnMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND window_;
  bool busy_ = false;
  std::atomic<bool> cancelled_{false};
  std::atomic<bool> cleaning_{false};
  std::thread worker_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_BRIDGE_H_
