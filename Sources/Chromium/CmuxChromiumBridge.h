#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

BOOL cmux_chromium_runtime_available(void);
BOOL cmux_chromium_initialize(void);
int cmux_chromium_remote_debugging_port(void);
const char *cmux_chromium_last_error(void);
void * _Nullable cmux_chromium_create_browser(NSView *parentView, const char *url);
void cmux_chromium_close_browser(void *browserHandle);
void cmux_chromium_dispose_browser(void *browserHandle);
void cmux_chromium_resize_browser(void *browserHandle);
void cmux_chromium_load_url(void *browserHandle, const char *url);
void cmux_chromium_execute_javascript(void *browserHandle, const char *script);
void cmux_chromium_go_back(void *browserHandle);
void cmux_chromium_go_forward(void *browserHandle);
void cmux_chromium_reload(void *browserHandle);
void cmux_chromium_stop_loading(void *browserHandle);
void cmux_chromium_set_focus(void *browserHandle, BOOL focus);
void cmux_chromium_set_zoom_level(void *browserHandle, double zoomLevel);
void cmux_chromium_find(void *browserHandle, const char *searchText, BOOL forward, BOOL findNext);
void cmux_chromium_stop_finding(void *browserHandle, BOOL clearSelection);
BOOL cmux_chromium_has_dev_tools(void *browserHandle);
void cmux_chromium_show_dev_tools(void *browserHandle);
void cmux_chromium_close_dev_tools(void *browserHandle);
NSView * _Nullable cmux_chromium_browser_view(void *browserHandle);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
