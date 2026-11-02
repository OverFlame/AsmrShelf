#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::wstring Utf8ToWide(const std::string& input) {
  if (input.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, 0, input.data(), static_cast<int>(input.size()), nullptr, 0);
  if (size <= 0) {
    return {};
  }
  std::wstring output(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, input.data(),
                      static_cast<int>(input.size()), output.data(), size);
  return output;
}

std::wstring ReadString(const flutter::EncodableMap& arguments,
                        const std::string& key) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) {
    return {};
  }
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? Utf8ToWide(*value) : std::wstring();
}

bool ReadBool(const flutter::EncodableMap& arguments, const std::string& key) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) {
    return false;
  }
  const auto* value = std::get_if<bool>(&it->second);
  return value ? *value : false;
}

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

  subtitle_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "asmrshelf/subtitle_overlay",
          &flutter::StandardMethodCodec::GetInstance());
  subtitle_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        const std::string& method = call.method_name();
        if (method == "hasPermission" || method == "requestPermission") {
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "hide") {
          subtitle_overlay_.Hide();
          result->Success();
          return;
        }
        if (method == "setLocked") {
          const auto* locked = std::get_if<bool>(call.arguments());
          subtitle_overlay_.SetLocked(locked != nullptr && *locked);
          result->Success();
          return;
        }
        if (method == "show" || method == "update") {
          std::wstring current;
          std::wstring next;
          bool locked = false;
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments != nullptr) {
            current = ReadString(*arguments, "current");
            next = ReadString(*arguments, "next");
            locked = ReadBool(*arguments, "locked");
          }
          if (method == "show") {
            result->Success(flutter::EncodableValue(
                subtitle_overlay_.Show(current, next, locked)));
          } else {
            subtitle_overlay_.Update(current, next);
            result->Success();
          }
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  subtitle_overlay_.Hide();
  subtitle_channel_.reset();
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
