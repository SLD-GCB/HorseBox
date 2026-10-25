#pragma once
#include <string>

// 默认数据目录：%APPDATA%\HorseBox
std::wstring DefaultDataDir();

// App 的数据目录：默认目录，或 bootstrap.json 里 data_dir 指定的自定义目录
std::wstring ResolveDataDir();

// 让下次 ResolveDataDir 重新读 bootstrap.json（设置里改了目录后）
void InvalidateDataDir();

// 新位置没有就用老位置（改过目录的老用户迁移读取）
std::wstring FirstExisting(const std::wstring& primary, const std::wstring& legacy);
