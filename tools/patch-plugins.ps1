# Patch third-party flutter plugins so HorseBox can build on this machine.
# 1. flutter_inappwebview_android uses an old proguard file rejected by AGP 8+.
# 2. flutter_inappwebview_windows has its server-certificate handler commented out,
#    which blocks self-signed panel certificates.

$ErrorActionPreference = 'SilentlyContinue'

$hosts = @(
  "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.flutter-io.cn",
  "$env:LOCALAPPDATA\Pub\Cache\hosted\pub.dev"
)

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
    if ($text -match "/\*\s*wil::com_ptr<ICoreWebView2_14>") {
      $replacement = @'
    wil::com_ptr<ICoreWebView2_14> webView14;
    if (SUCCEEDED(webView->QueryInterface(IID_PPV_ARGS(&webView14)))) {
      failedLog(webView14->add_ServerCertificateErrorDetected(
        Callback<ICoreWebView2ServerCertificateErrorDetectedEventHandler>(
          [this](ICoreWebView2* sender, ICoreWebView2ServerCertificateErrorDetectedEventArgs* args)
          {
            args->put_Action(COREWEBVIEW2_SERVER_CERTIFICATE_ERROR_ACTION_ALWAYS_ALLOW);
            return S_OK;
          }
        ).Get(), nullptr));
    }
'@
      $text = [regex]::Replace($text, "/\*\s*wil::com_ptr<ICoreWebView2_14>[\s\S]*?\}\*/", $replacement)
      [System.IO.File]::WriteAllText($cpp, $text)
      Write-Host "[patch] flutter_inappwebview_windows certificate"
    }
  }
}

Write-Host "[patch] plugins ready"
