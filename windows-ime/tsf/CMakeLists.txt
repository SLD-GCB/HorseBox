cmake_minimum_required(VERSION 3.20)
project(horsebox_ime_tsf CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(horsebox-ime SHARED
    src/dllmain.cpp
    src/Globals.cpp
    src/EngineBridge.cpp
    src/CandidateWindow.cpp
    src/TextService.cpp
    src/Register.cpp
    src/Dpapi.cpp
    src/Paths.cpp
    horsebox-ime.def
)

target_compile_definitions(horsebox-ime PRIVATE UNICODE _UNICODE _CRT_SECURE_NO_WARNINGS NOMINMAX)
target_compile_options(horsebox-ime PRIVATE /utf-8)
target_link_libraries(horsebox-ime PRIVATE ole32 oleaut32 uuid user32 gdi32 advapi32 crypt32 gdiplus)

set_target_properties(horsebox-ime PROPERTIES OUTPUT_NAME "horsebox-ime")

add_executable(horsebox-imectl tool/main.cpp src/Dpapi.cpp src/Paths.cpp)
target_compile_definitions(horsebox-imectl PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(horsebox-imectl PRIVATE /utf-8)
target_link_libraries(horsebox-imectl PRIVATE ole32 oleaut32 uuid advapi32 psapi crypt32)
