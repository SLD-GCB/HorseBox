@echo off
setlocal EnableExtensions
title HorseBox 打包

rem 用法：
rem   build-all.bat                 交互式，双端都打
rem   build-all.bat win             只打 Windows（可跟版本号）
rem   build-all.bat android 3.3     只打 Android，版本 3.3，元数据默认 33
rem   build-all.bat android 3.3 3300  只打 Android，元数据就用 3300
rem   build-all.bat all 3.3 3300    双端，版本 3.3，元数据 3300
rem 环境变量：CLEAN=0 跳过 clean；NO_PAUSE=1 结束不暂停；BUILDNO=3300 等同第三个参数

set "ROOT=%~dp0"
set "UI=%ROOT%UI"
set "DIST=%ROOT%app"
set "FLUTTER=D:\flutter\bin\flutter.bat"
set "SDK=%LOCALAPPDATA%\Android\Sdk"
set "NDK_VER=27.2.12479018"
set "GRADLE_HASH=619e6l8zt76uzaekhqdol0b60"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FINDSTR=%SystemRoot%\System32\findstr.exe"

rem ---------------------------------------------------------------- 参数
set "TARGET=%~1"
set "ARGVER="
set "ARGBUILD="
if /i "%TARGET%"=="all" goto :arg_ok
if /i "%TARGET%"=="win" goto :arg_ok
if /i "%TARGET%"=="android" goto :arg_ok
rem 第一个参数不是目标平台：当成版本号，目标默认双端
set "TARGET=all"
set "ARGVER=%~1"
set "ARGBUILD=%~2"
goto :arg_done

:arg_ok
set "ARGVER=%~2"
set "ARGBUILD=%~3"

:arg_done
echo ============================================
echo   HorseBox 打包（Windows + Android）
echo ============================================
echo   目标：%TARGET%
echo.

if not exist "%FLUTTER%" (
  echo [错误] 找不到 Flutter：%FLUTTER%
  goto fail
)
if not exist "%ROOT%tools\nuget.exe" (
  echo [错误] 缺少 tools\nuget.exe，WebView2 构建需要它
  goto fail
)

if /i "%TARGET%"=="win" goto :checks_done

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

:checks_done
set "ANDROID_HOME=%SDK%"
set "ANDROID_NDK_HOME=%SDK%\ndk\%NDK_VER%"
set "PATH=%ROOT%tools;%JAVA_HOME%\bin;%SDK%\platform-tools;C:\Windows\System32;C:\Windows;C:\Program Files\Git\cmd;%PATH%"

rem ---------------------------------------------------------------- 版本号
set "DEFVER="
"%FINDSTR%" /b "version:" "%UI%\pubspec.yaml" > "%TEMP%\hbver.txt" 2>nul
for /f "tokens=2 delims=:" %%v in (%TEMP%\hbver.txt) do set "DEFVER=%%v"
del "%TEMP%\hbver.txt" >nul 2>nul
if defined DEFVER set "DEFVER=%DEFVER: =%"
for /f "tokens=1 delims=+" %%v in ("%DEFVER%") do set "DEFVER=%%v"
if not defined DEFVER set "DEFVER=0.1.0"
if exist "%ROOT%.version" set /p LASTVER=<"%ROOT%.version"
if defined LASTVER set "DEFVER=%LASTVER%"

set "VER=%ARGVER%"
if not defined VER (
  set /p "VER=输入版本号（回车默认 %DEFVER%）: "
)
if not defined VER set "VER=%DEFVER%"
rem 元数据（versionCode）：第三个参数 > BUILDNO 环境变量 > 版本号去掉小数点
set "BUILD="
if defined ARGBUILD set "BUILD=%ARGBUILD%"
if not defined BUILD if defined BUILDNO set "BUILD=%BUILDNO%"
if not defined BUILD set "BUILD=%VER:.=%"
echo %BUILD%| "%FINDSTR%" /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
  echo [错误] 元数据必须是纯数字，收到：%BUILD%
  goto fail
)
echo [版本] %VER% (versionCode %BUILD%)
echo.

if not exist "%DIST%" mkdir "%DIST%"

pushd "%UI%"
if /i not "%CLEAN%"=="0" (
  echo [0] 清理构建缓存...
  call "%FLUTTER%" clean
  if exist "%UI%\.dart_tool" rmdir /s /q "%UI%\.dart_tool" >nul 2>nul
) else (
  echo [0] 跳过清理（CLEAN=0）
)
call "%FLUTTER%" pub get
if errorlevel 1 (
  popd
  goto fail
)

echo [1] 修补依赖插件...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\patch-plugins.ps1"
if errorlevel 1 (
  echo [错误] 插件修补失败，WebView2 会跳过证书指纹校验
  popd
  goto fail
)

rem ---------------------------------------------------------------- Windows
if /i "%TARGET%"=="android" goto :skip_windows

echo [2] 构建 Windows Release...
call "%FLUTTER%" build windows --release --no-tree-shake-icons
if errorlevel 1 (
  popd
  goto fail
)

echo [3] 打包 Windows...
call "%ROOT%windows\package.bat"
if errorlevel 1 (
  popd
  goto fail
)

set "ZIP=%DIST%\HorseBox-%VER%-windows-x64.zip"
rem 拼音词库只给安卓内置键盘用，Windows 包里没意义，打包前剔掉
if exist "%UI%\build\windows\x64\runner\Release\data\flutter_assets\assets\ime" rmdir /s /q "%UI%\build\windows\x64\runner\Release\data\flutter_assets\assets\ime"
if exist "%ZIP%" del /f /q "%ZIP%" >nul
"%PS%" -NoProfile -Command "Compress-Archive -Path '%UI%\build\windows\x64\runner\Release\*' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 (
  popd
  goto fail
)

:skip_windows
rem ---------------------------------------------------------------- Android
if /i "%TARGET%"=="win" goto :skip_android

echo [4] 构建 Android Release（arm64 + x86_64，按 ABI 分包）...
call "%ROOT%android\sync-libbox.bat"
if errorlevel 1 (
  popd
  goto fail
)
rem -P force-version-code-ignoring-abi=true：不要 Flutter 按 ABI 给 versionCode 加偏移，
rem 用户给多少就是多少（代价是各 ABI 的 APK 版本号相同，自建仓库无所谓）
call "%FLUTTER%" build apk --release --no-tree-shake-icons --target-platform android-arm64,android-x64 --split-per-abi --build-name=%VER% --build-number=%BUILD% -P force-version-code-ignoring-abi=true
if errorlevel 1 (
  popd
  goto fail
)

echo [5] 打包 Android...
set "APK=%UI%\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
if not exist "%APK%" (
  echo [错误] 找不到 APK：%APK%
  popd
  goto fail
)
copy /y "%APK%" "%DIST%\HorseBox-%VER%-android-arm64.apk" >nul
rem [5.1] 校验词库资源确实打进了 APK
"%PS%" -NoProfile -Command "$apk='%DIST%\HorseBox-%VER%-android-arm64.apk'; Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[IO.Compression.ZipFile]::OpenRead($apk); $names=@($z.Entries.FullName); $z.Dispose(); $need=@('assets/flutter_assets/assets/ime/pinyin.tsv.gz','assets/flutter_assets/assets/ime/en_words.tsv.gz','assets/flutter_assets/assets/ime/st_chars.tsv'); $bad=0; foreach($n in $need){ if($names -notcontains $n){ Write-Host ('[错误] APK 缺少资源: ' + $n); $bad=1 } }; if($bad -eq 1){ exit 1 } else { Write-Host '[5.1] 词库资源校验通过' }"
if errorlevel 1 (
  popd
  goto fail
)

rem [5.2] 确认 APK 里的 versionCode 就是要求的数字（Flutter 默认会按 ABI 加偏移）
"%PS%" -NoProfile -Command "$m = Get-Content '%UI%\build\app\outputs\apk\release\output-metadata.json' -Raw | ConvertFrom-Json; $e = $m.elements | Where-Object { $_.filters.value -eq 'arm64-v8a' } | Select-Object -First 1; if ($e) { Write-Host ('[5.2] arm64 versionCode=' + $e.versionCode + ' / 要求 %BUILD%'); if ([int]$e.versionCode -ne %BUILD%) { Write-Host '[错误] versionCode 与要求不一致'; exit 1 } } else { Write-Host '[5.2] 找不到 arm64 输出，跳过校验' }"
if errorlevel 1 (
  popd
  goto fail
)


rem [6] 发布：放在构建和校验之后，推上去的才是刚打出来的这个包
if /i "%PUSH_FDROID%"=="1" (
  echo [6] 推送到 F-Droid...
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%tools\push-fdroid.ps1" -Apk "%DIST%\HorseBox-%VER%-android-arm64.apk" -VersionCode "%VER%_%BUILD%"
)

:skip_android
popd

echo %VER%> "%ROOT%.version"

echo.
echo ============================================
echo   打包完成（版本 %VER%）
echo ============================================
if /i not "%TARGET%"=="android" if exist "%ZIP%" (
  echo Windows: %ZIP%
  for %%f in ("%ZIP%") do echo           %%~zf 字节
)
if /i not "%TARGET%"=="win" (
  echo Android: %DIST%\HorseBox-%VER%-android-arm64.apk
  for %%f in ("%DIST%\HorseBox-%VER%-android-arm64.apk") do echo           %%~zf 字节
)
echo.
if not defined NO_PAUSE pause
exit /b 0

:fail
echo.
echo 打包失败，请查看上面的错误信息。
if not defined NO_PAUSE pause
exit /b 1
