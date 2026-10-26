@echo off
setlocal
set "ROOT=%~dp0.."
set "SRC=%ROOT%\UI\build\windows\x64\runner\Release"
if not exist "%SRC%\horsebox.exe" (
  echo [error] Windows build not found: %SRC%
  exit /b 1
)
if not exist "%SRC%\core" mkdir "%SRC%\core"
copy /y "%ROOT%\core\sing-box.exe" "%SRC%\core\" >nul
copy /y "%ROOT%\core\libcronet.dll" "%SRC%\core\" >nul

rem ---------------------------------------------------------------- 输入法（Windows TSF）
set "IME=%ROOT%\windows-ime\tsf\build\Release"
rem 有 CMake 时先增量编译，确保复制的是最新 DLL
where cmake >nul 2>nul
if not errorlevel 1 (
  if exist "%ROOT%\windows-ime\tsf\build\CMakeCache.txt" (
    cmake --build "%ROOT%\windows-ime\tsf\build" --config Release >nul
    echo [ime] rebuilt
  )
)
if exist "%IME%\horsebox-ime.dll" (
  if not exist "%SRC%\ime" mkdir "%SRC%\ime"
  copy /y "%IME%\horsebox-ime.dll" "%SRC%\ime\" >nul
  if errorlevel 1 echo [warn] horsebox-ime.dll copy failed - close apps using it
  copy /y "%IME%\horsebox_ime_engine.dll" "%SRC%\ime\" >nul
  copy /y "%IME%\horsebox-imectl.exe" "%SRC%\ime\" >nul
  if not exist "%SRC%\ime\dict" mkdir "%SRC%\ime\dict"
  xcopy /e /i /y "%IME%\dict\*" "%SRC%\ime\dict\" >nul
  for %%f in ("%SRC%\ime\horsebox-ime.dll") do echo [ime] horsebox-ime.dll %%~zf bytes
) else (
  echo [warn] IME not built: %IME%
)

exit /b 0
