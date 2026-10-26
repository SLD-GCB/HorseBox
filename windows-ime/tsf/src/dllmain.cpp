#include "Globals.h"

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID /*reserved*/) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_hInst = hinst;
        DisableThreadLibraryCalls(hinst);
    }
    return TRUE;
}
