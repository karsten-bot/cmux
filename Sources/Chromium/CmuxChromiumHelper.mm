#define OS_MAC 1
#define WRAPPING_CEF_SHARED 1

#include <string>
#include <string.h>

#include "include/cef_api_hash.h"
#include "libcef_dll/wrapper/libcef_dll_dylib.cc"

static std::string FrameworkPathFromExecutable(const char *argv0) {
    std::string executable = argv0 ? argv0 : "";
    const std::string marker = ".app/Contents/MacOS/";
    size_t marker_position = executable.rfind(marker);
    if (marker_position == std::string::npos) return "";
    size_t helper_app_start = executable.rfind('/', marker_position);
    if (helper_app_start == std::string::npos) return "";
    return executable.substr(0, helper_app_start) + "/Chromium Embedded Framework.framework/Chromium Embedded Framework";
}

int main(int argc, char *argv[]) {
    std::string framework_path = FrameworkPathFromExecutable(argc > 0 ? argv[0] : nullptr);
    if (framework_path.empty() || !cef_load_library(framework_path.c_str())) {
        return 1;
    }

    cef_api_hash(CEF_API_VERSION, 0);

    cef_main_args_t args = {};
    args.argc = argc;
    args.argv = argv;
    int result = cef_execute_process(&args, nullptr, nullptr);
    cef_unload_library();
    return result;
}
