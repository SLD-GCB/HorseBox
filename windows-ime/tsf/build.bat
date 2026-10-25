@echo off
setlocal
cd /d "%~dp0"
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
if errorlevel 1 goto fail
cmake --build build --config Release
if errorlevel 1 goto fail
echo.
echo Built: %~dp0build\Release\horsebox-ime.dll
goto end
:fail
echo Build failed.
:end
