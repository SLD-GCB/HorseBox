#include "app_lock_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <utility>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>

namespace {

namespace credentials_ui = winrt::Windows::Security::Credentials::UI;
using Result = flutter::MethodResult<flutter::EncodableValue>;

winrt::fire_and_forget VerifyAsync(
    std::shared_ptr<Result> result,
    winrt::apartment_context ui_thread) {
  bool ok = false;
  try {
    const auto status = co_await credentials_ui::UserConsentVerifier::
        RequestVerificationAsync(L"解锁 HorseBox");
    ok = status == credentials_ui::UserConsentVerificationResult::Verified;
  } catch (...) {
    ok = false;
  }
  co_await ui_thread;
  result->Success(flutter::EncodableValue(ok));
}

void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<Result> result) {
  if (call.method_name() == "available") {
    flutter::EncodableMap methods;
    methods[flutter::EncodableValue("biometric")] =
        flutter::EncodableValue(true);
    methods[flutter::EncodableValue("credential")] =
        flutter::EncodableValue(true);
    result->Success(flutter::EncodableValue(methods));
    return;
  }
  if (call.method_name() == "authenticate") {
    winrt::apartment_context ui_thread;
    VerifyAsync(std::shared_ptr<Result>(std::move(result)), ui_thread);
    return;
  }
  result->NotImplemented();
}

}  // namespace

void RegisterAppLockChannel(flutter::FlutterEngine* engine) {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "horsebox/app_lock",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(HandleMethodCall);
}
