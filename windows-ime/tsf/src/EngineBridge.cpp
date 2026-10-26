#include "EngineBridge.h"
#include <cstdlib>

std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    if (n <= 0) return L"";
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n);
    return out;
}

std::string WideToUtf8(const std::wstring& s) {
    if (s.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return "";
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), n, nullptr, nullptr);
    return out;
}

EngineBridge& EngineBridge::Instance() {
    static EngineBridge inst;
    return inst;
}

bool EngineBridge::Load(const std::wstring& appDir) {
    if (_ready) return true;
    std::wstring engine = appDir + L"horsebox_ime_engine.dll";
    _mod = LoadLibraryW(engine.c_str());
    if (!_mod) return false;
    _load = (LoadFn)GetProcAddress(_mod, "hb_load");
    _cands = (CandsFn)GetProcAddress(_mod, "hb_candidates");
    _en = (CandsFn)GetProcAddress(_mod, "hb_english_suggest");
    _trad = (TradFn)GetProcAddress(_mod, "hb_to_traditional");
    _free = (FreeFn)GetProcAddress(_mod, "hb_free");
    _learn = (LearnFn)GetProcAddress(_mod, "hb_learn");
    _options = (OptionsFn)GetProcAddress(_mod, "hb_options");
    _lload = (PathFn)GetProcAddress(_mod, "hb_learning_load");
    _lflush = (PathFn)GetProcAddress(_mod, "hb_learning_flush");
    _lcount = (CountFn)GetProcAddress(_mod, "hb_learning_count");
    _ltext = (PathFn)GetProcAddress(_mod, "hb_learning_load_text");
    _ldump = (DumpFn)GetProcAddress(_mod, "hb_learning_dump");
    if (!_load || !_cands || !_free) return false;
    std::string dict = WideToUtf8(appDir + L"dict");
    if (_load(dict.c_str()) <= 0) return false;
    _ready = true;
    return true;
}

static std::vector<std::string> SplitLines(char* p) {
    std::vector<std::string> lines;
    if (!p) return lines;
    std::string s(p);
    size_t pos = 0;
    while (pos <= s.size()) {
        size_t nl = s.find('\n', pos);
        std::string line = (nl == std::string::npos) ? s.substr(pos) : s.substr(pos, nl - pos);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!line.empty()) lines.push_back(line);
        if (nl == std::string::npos) break;
        pos = nl + 1;
    }
    return lines;
}

std::vector<EngCandidate> EngineBridge::Candidates(const std::string& pinyin, int limit) {
    std::vector<EngCandidate> out;
    if (!_ready || pinyin.empty()) return out;
    char* p = _cands(pinyin.c_str(), limit);
    if (!p) return out;
    auto lines = SplitLines(p);
    _free(p);
    for (auto& line : lines) {
        size_t tab = line.find('\t');
        std::string word = (tab == std::string::npos) ? line : line.substr(0, tab);
        int consumed = (tab == std::string::npos) ? 0 : atoi(line.c_str() + tab + 1);
        EngCandidate c;
        c.word = Utf8ToWide(word);
        c.consumed = consumed;
        out.push_back(c);
    }
    return out;
}

std::vector<std::wstring> EngineBridge::EnglishSuggest(const std::string& prefix, int limit) {
    std::vector<std::wstring> out;
    if (!_ready || !_en || prefix.empty()) return out;
    char* p = _en(prefix.c_str(), limit);
    if (!p) return out;
    auto lines = SplitLines(p);
    _free(p);
    for (auto& w : lines) out.push_back(Utf8ToWide(w));
    return out;
}

std::wstring EngineBridge::ToTraditional(const std::wstring& text) {
    if (!_ready || !_trad || text.empty()) return text;
    std::string u = WideToUtf8(text);
    char* p = _trad(u.c_str());
    if (!p) return text;
    std::string r(p);
    _free(p);
    return Utf8ToWide(r);
}

void EngineBridge::SetOptions(bool fuzzy, bool sentence, bool learn) {
    if (!_ready || !_options) return;
    _options(fuzzy ? 1 : 0, sentence ? 1 : 0, learn ? 1 : 0);
}

void EngineBridge::Learn(const std::string& code, const std::wstring& word, int position) {
    if (!_ready || !_learn) return;
    std::string w = WideToUtf8(word);
    _learn(code.c_str(), w.c_str(), position);
}

void EngineBridge::LearningLoad(const std::wstring& path) {
    if (!_ready || !_lload) return;
    std::string p = WideToUtf8(path);
    _lload(p.c_str());
}

void EngineBridge::LearningFlush(const std::wstring& path) {
    if (!_ready || !_lflush) return;
    std::string p = WideToUtf8(path);
    _lflush(p.c_str());
}

void EngineBridge::LearningLoadText(const std::string& text) {
    if (!_ready || !_ltext || text.empty()) return;
    _ltext(text.c_str());
}

std::string EngineBridge::LearningDump() {
    if (!_ready || !_ldump) return "";
    char* p = _ldump();
    if (!p) return "";
    std::string out(p);
    _free(p);
    return out;
}

int EngineBridge::LearningCount() {
    return (_ready && _lcount) ? _lcount() : 0;
}
