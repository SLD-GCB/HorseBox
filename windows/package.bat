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
exit /b 0
