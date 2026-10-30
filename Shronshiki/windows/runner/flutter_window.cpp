#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Id of the global hotkey for the media Play/Pause key.
constexpr int kMediaHotkeyId = 0x5348;

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
  SetUpCallChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetUpCallChannel() {
  call_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "shronshiki/call",
          &flutter::StandardMethodCodec::GetInstance());
  call_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "start") {
          call_active_ = true;
        } else if (method == "stop") {
          call_active_ = false;
        } else if (method == "startButtonTest") {
          button_test_active_ = true;
        } else if (method == "stopButtonTest") {
          button_test_active_ = false;
        } else if (method == "flash") {
          // Mention in a room chat: flash the taskbar button until the
          // window comes to the foreground.
          FLASHWINFO info{};
          info.cbSize = static_cast<UINT>(sizeof(FLASHWINFO));
          info.hwnd = GetHandle();
          info.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
          ::FlashWindowEx(&info);
          result->Success();
          return;
        } else if (method != "update") {
          result->NotImplemented();
          return;
        }
        UpdateMediaHotkey();
        result->Success();
      });
}

void FlutterWindow::UpdateMediaHotkey() {
  const bool wanted = call_active_ || button_test_active_;
  if (wanted && !hotkey_registered_) {
    hotkey_registered_ = ::RegisterHotKey(GetHandle(), kMediaHotkeyId,
                                          MOD_NOREPEAT,
                                          VK_MEDIA_PLAY_PAUSE) != 0;
  } else if (!wanted && hotkey_registered_) {
    ::UnregisterHotKey(GetHandle(), kMediaHotkeyId);
    hotkey_registered_ = false;
  }
}

void FlutterWindow::OnDestroy() {
  call_active_ = false;
  button_test_active_ = false;
  UpdateMediaHotkey();
  call_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_HOTKEY:
      if (wparam == static_cast<WPARAM>(kMediaHotkeyId) && call_channel_) {
        call_channel_->InvokeMethod(
            "onMediaKey", std::make_unique<flutter::EncodableValue>(
                              std::string("MEDIA_PLAY_PAUSE")));
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
