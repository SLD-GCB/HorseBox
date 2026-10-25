#pragma once
#include <windows.h>
#include <string>
#include <vector>

struct EngCandidate {
    std::wstring word;
    int consumed = 0;
};

class EngineBridge {
public:
    static EngineBridge& Instance();

    // appDir: DLL 所在目录（以反斜杠结尾），里面应有 horsebox_ime_engine.dll 和 dict 子目录
    bool Load(const std::wstring& appDir);
    bool Ready() const { return _ready; }

    std::vector<EngCandidate> Candidates(const std::string& pinyin, int limit);
    std::vector<std::wstring> EnglishSuggest(const std::string& prefix, int limit);
    std::wstring ToTraditional(const std::wstring& text);
    // 模糊音 / 句子模式 / 词频记忆，对应设置页的三个开关
    void SetOptions(bool fuzzy, bool sentence, bool learn);
    void Learn(const std::string& code, const std::wstring& word, int position);
    void LearningLoad(const std::wstring& path);
    void LearningFlush(const std::wstring& path);
    // 加密落盘由外壳负责：引擎只吃/吐文本
    void LearningLoadText(const std::string& text);
    std::string LearningDump();
    int LearningCount();

private:
    EngineBridge() = default;
    HMODULE _mod = nullptr;
    bool _ready = false;

    using LoadFn = int (*)(const char*);
    using CandsFn = char* (*)(const char*, int);
    using TradFn = char* (*)(const char*);
    using FreeFn = void (*)(char*);
    using LearnFn = void (*)(const char*, const char*, int);
    using OptionsFn = void (*)(int, int, int);
    using PathFn = void (*)(const char*);
    using CountFn = int (*)();
    using DumpFn = char* (*)();

    LoadFn _load = nullptr;
    CandsFn _cands = nullptr;
    CandsFn _en = nullptr;
    TradFn _trad = nullptr;
    FreeFn _free = nullptr;
    LearnFn _learn = nullptr;
    OptionsFn _options = nullptr;
    PathFn _lload = nullptr;
    PathFn _lflush = nullptr;
    CountFn _lcount = nullptr;
    PathFn _ltext = nullptr;  // 同名签名：void(const char*)，这里吃的是内容不是路径
    DumpFn _ldump = nullptr;
};

std::wstring Utf8ToWide(const std::string& s);
std::string WideToUtf8(const std::wstring& s);
