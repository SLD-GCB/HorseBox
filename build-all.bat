@echo off
setlocal EnableExtensions
title HorseBox 双端打包

set "ROOT=%~dp0"
set "UI=%ROOT%UI"
set "DIST=%ROOT%app"
set "FLUTTER=D:\flutter\bin\flutter.bat"
set "SDK=%LOCALAPPDATA%\Android\Sdk"
set "NDK_VER=27.2.12479018"
set "GRADLE_HASH=619e6l8zt76uzaekhqdol0b60"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FINDSTR=%SystemRoot%\System32\findstr.exe"

echo ============================================
echo   HorseBox 打包（Windows + Android）
echo ============================================
echo.

if not exist "%FLUTTER%" (
  echo [错误] 找不到 Flutter：%FLUTTER%
  goto fail
)

set "JAVA_HOME=%USERPROFILE%\.jdks\jbr-21.0.11"
if not exist "%JAVA_HOME%\bin\java.exe" (
  echo [错误] 找不到 JDK 21：%JAVA_HOME%
  goto fail
)

if not exist "%SDK%\platforms" (
  echo [错误] 找不到 Android SDK：%SDK%
  goto fail
)
if not exist "%SDK%\ndk\%NDK_VER%\source.properties" (
  echo [错误] 找不到 NDK %NDK_VER%
  echo        本脚本不会下载 NDK，请先安装好再打包
  goto fail
)
if not exist "%UI%\android\app\libs\libbox.aar" (
  echo [错误] 缺少 libbox.aar：UI\android\app\libs\libbox.aar
  goto fail
)
if not exist "%USERPROFILE%\.gradle\wrapper\dists\gradle-9.8.0-all\%GRADLE_HASH%\gradle-9.8.0\bin\gradle.bat" (
  echo [错误] 本地没有 Gradle 9.8.0 缓存
  echo        本脚本不会下载 Gradle，请先在 Android Studio 里成功构建过一次
  goto fail
)

set "ANDROID_HOME=%SDK%"
set "ANDROID_NDK_HOME=%SDK%\ndk\%NDK_VER%"
set "PATH=%JAVA_HOME%\bin;%SDK%\platform-tools;C:\Windows\System32;C:\Windows;C:\Program Files\Git\cmd;%PATH%"

set "DEFVER="
"%FINDSTR%" /b "version:" "%UI%\pubspec.yaml" > "%TEMP%\hbver.txt" 2>nul
for /f "tokens=2 delims=:" %%v in (%TEMP%\hbver.txt) do set "DEFVER=%%v"
del "%TEMP%\hbver.txt" >nul 2>nul
if defined DEFVER set "DEFVER=%DEFVER: =%"
for /f "tokens=1 delims=+" %%v in ("%DEFVER%") do set "DEFVER=%%v"
if not defined DEFVER set "DEFVER=0.1.0"

set "VER="
set /p "VER=输入版本号（回车默认 %DEFVER%）: "
if not defined VER set "VER=%DEFVER%"
echo [版本] %VER%
echo.

if not exist "%DIST%" mkdir "%DIST%"

pushd "%UI%"
if /i not "%CLEAN%"=="0" (
  echo [0/4] 清理构建缓存...
  call "%FLUTTER%" clean
  if exist "%UI%\.dart_tool" rmdir /s /q "%UI%\.dart_tool" >nul 2>nul
  call "%FLUTTER%" pub get
  if errorlevel 1 (
    popd
    goto fail
  )
) else (
  echo [0/4] 跳过清理（CLEAN=0）
  call "%FLUTTER%" pub get
  if errorlevel 1 (
    popd
    goto fail
  )
)

echo [1/4] 构建 Windows Release...
call "%FLUTTER%" build windows --release
if errorlevel 1 (
  popd
  goto fail
)

echo [2/4] 打包 Windows...
call "%ROOT%windows\package.bat"
if errorlevel 1 (
  popd
  goto fail
)

set "ZIP=%DIST%\HorseBox-%VER%-windows-x64.zip"
if exist "%ZIP%" del /f /q "%ZIP%" >nul
"%PS%" -NoProfile -Command "Compress-Archive -Path '%UI%\build\windows\x64\runner\Release\*' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 (
  popd
  goto fail
)

echo [3/4] 构建 Android Release（arm64 + x86_64，按 ABI 分包）...
call "%ROOT%android\sync-libbox.bat"
if errorlevel 1 (
  popd
  goto fail
)
call "%FLUTTER%" build apk --release --target-platform android-arm64,android-x64 --split-per-abi --build-name=%VER% --build-number=1
if errorlevel 1 (
  popd
  goto fail
)

echo [4/4] 打包 Android...
set "APK=%UI%\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
if not exist "%APK%" (
  echo [错误] 找不到 APK：%APK%
  popd
  goto fail
)
copy /y "%APK%" "%DIST%\HorseBox-%VER%-android-arm64.apk" >nul
popd

echo.
echo ============================================
echo   打包完成
echo ============================================
echo Windows: %ZIP%
echo Android: %DIST%\HorseBox-%VER%-android-arm64.apk
echo.
if not defined NO_PAUSE pause
exit /b 0

:fail
echo.
echo 打包失败，请查看上面的错误信息。
if not defined NO_PAUSE pause
exit /b 1
