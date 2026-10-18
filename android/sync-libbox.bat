@echo off
setlocal
set "ROOT=%~dp0.."
set "SRC=%ROOT%\core\libbox.aar"
set "DST=%ROOT%\UI\android\app\libs"
if not exist "%SRC%" (
  echo [error] missing core\libbox.aar
  exit /b 1
)
if not exist "%DST%" mkdir "%DST%"
copy /y "%SRC%" "%DST%\libbox.aar" >nul
exit /b 0
