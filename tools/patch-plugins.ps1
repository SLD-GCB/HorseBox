# Patch third-party flutter plugins so HorseBox can build on this machine.
# 1. flutter_inappwebview_android uses an old proguard file rejected by AGP 8+.
# 2. flutter_inappwebview_windows keeps its server-certificate handler commented out.
#    HorseBox 启用它，并改成按指纹决定放行：
#    - panel_pin 是 64 位十六进制：证书 DER 的 SHA-256 必须一致，否则 CANCEL；
#    - panel_pin 是 temporary：首次登录的临时连接，仍然走 TLS，但不校验指纹；
#    - 文件缺失：拒绝。

$ErrorActionPreference = 'SilentlyContinue'

$hosts = @(
  "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.flutter-io.cn",
  "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev"
)

$helper = @'
  // HorseBox: 面板证书指纹固定（horsebox-pin-v2）。
  // WebView2 每次 TLS 握手报证书错误时读取 panel_pin：
  //   64 位十六进制 -> 证书 DER 的 SHA-256 必须一致；
  //   temporary     -> 首次登录的临时连接，放行但仍然是加密连接；
  //   其它/缺失     -> 拒绝。
  namespace horsebox_pin {
    inline std::string readPinFile() {
      std::string token;
      wchar_t base[MAX_PATH] = {};
      DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
      if (len == 0 || len >= MAX_PATH) {
        len = GetEnvironmentVariableW(L"TEMP", base, MAX_PATH);
        if (len == 0 || len >= MAX_PATH) return token;
      }
      std::wstring path(base, len);
      path.append(L"\\HorseBox\\panel_pin");
      HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                                FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file == INVALID_HANDLE_VALUE) return token;
      char buf[512] = {};
      DWORD read = 0;
      if (ReadFile(file, buf, sizeof(buf) - 1, &read, nullptr)) {
        for (DWORD i = 0; i < read; ++i) {
          unsigned char c = static_cast<unsigned char>(buf[i]);
          if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
          if (c >= 'A' && c <= 'Z') c = static_cast<unsigned char>(c - 'A' + 'a');
          token.push_back(static_cast<char>(c));
        }
      }
      CloseHandle(file);
      return token;
    }

    inline bool hashMatchesPem(const std::wstring& pem, const std::string& expected) {
      if (expected.size() != 64 || pem.empty()) return false;

      std::string b64;
      const size_t bodyBegin = pem.find(L'\n');
      if (bodyBegin == std::wstring::npos) return false;
      const size_t bodyEnd = pem.find(L"-----END", bodyBegin);
      if (bodyEnd == std::wstring::npos) return false;
      for (size_t i = bodyBegin; i < bodyEnd; ++i) {
        const wchar_t c = pem[i];
        if (c == L'\r' || c == L'\n' || c == L' ' || c == L'\t') continue;
        if (c < 0x21 || c > 0x7e) return false;
        b64.push_back(static_cast<char>(c));
      }
      if (b64.empty()) return false;

      DWORD derLen = 0;
      if (!CryptStringToBinaryA(b64.c_str(), static_cast<DWORD>(b64.size()),
                                CRYPT_STRING_BASE64, nullptr, &derLen, nullptr, nullptr) ||
          derLen == 0) {
        return false;
      }
      std::vector<BYTE> der(derLen);
      if (!CryptStringToBinaryA(b64.c_str(), static_cast<DWORD>(b64.size()),
                                CRYPT_STRING_BASE64, der.data(), &derLen, nullptr, nullptr)) {
        return false;
      }

      BCRYPT_ALG_HANDLE alg = nullptr;
      BCRYPT_HASH_HANDLE hash = nullptr;
      if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) {
        return false;
      }
      if (BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
        BCryptCloseAlgorithmProvider(alg, 0);
        return false;
      }
      const NTSTATUS fed = BCryptHashData(hash, der.data(), static_cast<ULONG>(derLen), 0);
      unsigned char digest[32] = {};
      const NTSTATUS done = BCryptFinishHash(hash, digest, sizeof(digest), 0);
      BCryptDestroyHash(hash);
      BCryptCloseAlgorithmProvider(alg, 0);
      if (fed < 0 || done < 0) return false;

      static const char* hexDigits = "0123456789abcdef";
      std::string got;
      got.reserve(64);
      for (unsigned char b : digest) {
        got.push_back(hexDigits[b >> 4]);
        got.push_back(hexDigits[b & 0x0f]);
      }
      unsigned diff = 0;
      for (size_t i = 0; i < 64; ++i) {
        diff |= static_cast<unsigned>(static_cast<unsigned char>(got[i]) ^
                                      static_cast<unsigned char>(expected[i]));
      }
      return diff == 0;
    }

    inline bool accept(ICoreWebView2Certificate* cert) {
      const std::string token = readPinFile();
      if (token == "temporary") return true;
      if (token.size() != 64 || cert == nullptr) return false;
      LPWSTR pem = nullptr;
      bool ok = false;
      if (SUCCEEDED(cert->ToPemEncoding(&pem)) && pem != nullptr) {
        ok = hashMatchesPem(std::wstring(pem), token);
        CoTaskMemFree(pem);
      }
      return ok;
    }
  }
'@

$block = @'
    wil::com_ptr<ICoreWebView2_14> webView14;
    if (SUCCEEDED(webView->QueryInterface(IID_PPV_ARGS(&webView14)))) {
      failedLog(webView14->add_ServerCertificateErrorDetected(
        Callback<ICoreWebView2ServerCertificateErrorDetectedEventHandler>(
          [this](ICoreWebView2* sender, ICoreWebView2ServerCertificateErrorDetectedEventArgs* args)
          {
            ICoreWebView2Certificate* cert = nullptr;
            const bool trusted =
              SUCCEEDED(args->get_ServerCertificate(&cert)) &&
              horsebox_pin::accept(cert);
            if (cert != nullptr) {
              cert->Release();
            }
            args->put_Action(trusted
              ? COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW
              : COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_CANCEL);
            return S_OK;
          }
        ).Get(), nullptr));
    }
'@

foreach ($hostDir in $hosts) {
  if (-not (Test-Path $hostDir)) { continue }

  $gradle = Join-Path $hostDir "flutter_inappwebview_android-1.1.3\android\build.gradle"
  if (Test-Path $gradle) {
    $text = Get-Content $gradle -Raw
    if ($text -match "proguard-android\.txt") {
      $text = $text -replace "proguard-android\.txt", "proguard-android-optimize.txt"
      [System.IO.File]::WriteAllText($gradle, $text)
      Write-Host "[patch] flutter_inappwebview_android proguard"
    }
  }

  $cpp = Join-Path $hostDir "flutter_inappwebview_windows-0.6.0\windows\in_app_webview\in_app_webview.cpp"
  if (Test-Path $cpp) {
    $text = Get-Content $cpp -Raw
    if ($text -notmatch "horsebox-pin-v2") {
      if ($text -notmatch "#include <bcrypt\.h>") {
        $text = $text -replace "(#include <Shlwapi\.h>)", "`$1`r`n#include <string>`r`n#include <vector>`r`n#include <bcrypt.h>`r`n#include <wincrypt.h>`r`n#pragma comment(lib, `"bcrypt.lib`")`r`n#pragma comment(lib, `"crypt32.lib`")"
      }

      if ($text -match "namespace horsebox_pin") {
        # 从旧版 helper 升级（旧版不认 temporary）。
        $text = [regex]::Replace($text, "namespace horsebox_pin \{[\s\S]*?\}\s*\r?\n\s*void InAppWebView::registerEventHandlers", ($helper + "`r`n  void InAppWebView::registerEventHandlers"))
      }
      elseif ($text.Contains("void InAppWebView::registerEventHandlers()")) {
        $text = $text.Replace("void InAppWebView::registerEventHandlers()", $helper + "`r`n  void InAppWebView::registerEventHandlers()")
      }

      if ($text -match "/\*\s*wil::com_ptr<ICoreWebView2_14>") {
        # 原版：整段被注释掉。
        $text = [regex]::Replace($text, "/\*\s*wil::com_ptr<ICoreWebView2_14>[\s\S]*?\}\*/", $block)
      }
      elseif ($text -match "COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW") {
        # 旧版补丁：无条件放行一切证书错误。
        $text = [regex]::Replace($text, "wil::com_ptr<ICoreWebView2_14> webView14;[\s\S]*?\.Get\(\), nullptr\)\);\s*\r?\n\s*\}", $block.TrimEnd())
      }

      [System.IO.File]::WriteAllText($cpp, $text, (New-Object System.Text.UTF8Encoding($true)))
      Write-Host "[patch] flutter_inappwebview_windows certificate pinning"
    }
    else {
      $bytes = [System.IO.File]::ReadAllBytes($cpp)
      if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        [System.IO.File]::WriteAllText($cpp, $text, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "[patch] cpp encoding normalized to UTF-8 BOM"
      }
    }
  }
}

# 3. xterm 建立输入法连接时带 NO_SUGGESTIONS / NO_PERSONALIZED_LEARNING，华为、小米
#    这类输入法会据此切成「安全键盘」。全部改成普通输入，交还给系统当前输入法。
foreach ($hostDir in $hosts) {
  $edit = Join-Path $hostDir "xterm-4.0.0\lib\src\ui\custom_text_edit.dart"
  if (-not (Test-Path $edit)) { continue }
  $text = Get-Content $edit -Raw
  if ($text -match "horsebox-ime-v2") { continue }
  $nl = [string][char]13 + [string][char]10
  $text = $text.Replace("        autocorrect: false,", "        autocorrect: true,")
  $text = $text.Replace("        enableSuggestions: false,", "        enableSuggestions: true,")
  $replacement = "        // horsebox-ime-v2" + $nl + "        enableIMEPersonalizedLearning: true,"
  $text = $text.Replace("        enableIMEPersonalizedLearning: false,", $replacement)
  $text = $text.Replace("horsebox-ime-v1", "horsebox-ime-v2")
  [System.IO.File]::WriteAllText($edit, $text, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[patch] xterm IME flags patched"
}

# 校验：Windows 插件必须带上 horsebox-pin-v2，否则打出来的包会退回旧行为。
$verified = $false
foreach ($hostDir in $hosts) {
  $cpp = Join-Path $hostDir "flutter_inappwebview_windows-0.6.0\windows\in_app_webview\in_app_webview.cpp"
  if (-not (Test-Path $cpp)) { continue }
  $check = Get-Content $cpp -Raw
  if ($check -notmatch "horsebox-pin-v2") {
    Write-Host "[patch] certificate pinning patch missing: $cpp"
    exit 1
  }
  $verified = $true
}
if (-not $verified) {
  Write-Host "[patch] flutter_inappwebview_windows not found, run flutter pub get first"
  exit 1
}

Write-Host "[patch] plugins ready"

exit 0
