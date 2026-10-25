#pragma once
#include <windows.h>
#include <string>
#include <vector>

// 用 DPAPI（当前用户作用域）加解密。落盘的敏感内容一律走这里，不留明文。
bool DpapiProtect(const std::vector<BYTE>& plain, std::vector<BYTE>& sealed);
bool DpapiUnprotect(const std::vector<BYTE>& sealed, std::vector<BYTE>& plain);

std::string Base64Encode(const std::vector<BYTE>& data);
bool Base64Decode(const std::string& text, std::vector<BYTE>& out);
