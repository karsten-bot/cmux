#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

BOOL cmux_chromium_runtime_available(void);
BOOL cmux_chromium_initialize(void);
const char *cmux_chromium_last_error(void);
void * _Nullable cmux_chromium_create_browser(NSView *parentView, const char *url);
void cmux_chromium_close_browser(void *browserHandle);
void cmux_chromium_resize_browser(void *browserHandle);
void cmux_chromium_load_url(void *browserHandle, const char *url);
void cmux_chromium_go_back(void *browserHandle);
void cmux_chromium_go_forward(void *browserHandle);
void cmux_chromium_reload(void *browserHandle);
void cmux_chromium_stop_loading(void *browserHandle);
BOOL cmux_chromium_has_dev_tools(void *browserHandle);
void cmux_chromium_show_dev_tools(void *browserHandle);
void cmux_chromium_close_dev_tools(void *browserHandle);
NSView * _Nullable cmux_chromium_browser_view(void *browserHandle);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
