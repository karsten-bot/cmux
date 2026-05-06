#define OS_MAC 1
#define WRAPPING_CEF_SHARED 1

#import "CmuxChromiumBridge.h"

#import <objc/runtime.h>

#include <dispatch/dispatch.h>
#include <stddef.h>
#include <string>
#include <string.h>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_application_mac.h"
#include "libcef_dll/wrapper/libcef_dll_dylib.cc"

static std::string g_last_error;
static NSString *const CmuxChromiumReactGrabMessageNotification = @"CmuxChromiumReactGrabMessageNotification";
static NSString *const CmuxChromiumReactGrabMessagePrefix = @"__CMUX_REACT_GRAB__";
static BOOL g_initialized = NO;
static NSTimer *g_message_loop_timer = nil;
static NSTimer *g_scheduled_message_loop_timer = nil;
static char **g_argv = nullptr;

static NSString *CmuxChromiumFrameworkPath(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) return nil;
    return [frameworksURL URLByAppendingPathComponent:@"Chromium Embedded Framework.framework/Chromium Embedded Framework"].path;
}

static NSString *CmuxChromiumFrameworkDirectoryPath(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) return nil;
    return [frameworksURL URLByAppendingPathComponent:@"Chromium Embedded Framework.framework"].path;
}

static NSString *CmuxChromiumResourcesPath(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) return nil;
    return [frameworksURL URLByAppendingPathComponent:@"Chromium Embedded Framework.framework/Resources"].path;
}

static NSString *CmuxChromiumHelperPath(void) {
    NSURL *frameworksURL = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworksURL) return nil;
    return [frameworksURL URLByAppendingPathComponent:@"cmux Chromium Helper.app/Contents/MacOS/cmux Chromium Helper"].path;
}

static void SetLastError(NSString *message) {
    g_last_error = message.UTF8String ?: "Chromium failed";
}

static void SetCefString(cef_string_t *target, NSString *value) {
    const char *utf8 = value.UTF8String ?: "";
    cef_string_from_utf8(utf8, strlen(utf8), target);
}

@interface NSApplication (CmuxChromiumCefAppProtocol) <CefAppProtocol>
@end

@implementation NSApplication (CmuxChromiumCefAppProtocol)
- (BOOL)isHandlingSendEvent {
    return [objc_getAssociatedObject(self, @selector(isHandlingSendEvent)) boolValue];
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    objc_setAssociatedObject(self, @selector(isHandlingSendEvent), @(handlingSendEvent), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

static void CmuxInstallChromiumEventBridge(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalMethod = class_getInstanceMethod(NSApplication.class, @selector(sendEvent:));
        typedef void (*SendEventImplementation)(id, SEL, NSEvent *);
        SendEventImplementation originalImplementation = (SendEventImplementation)method_getImplementation(originalMethod);
        void (^replacementBlock)(NSApplication *, NSEvent *) = ^(NSApplication *application, NSEvent *event) {
            BOOL wasHandlingSendEvent = [application isHandlingSendEvent];
            [application setHandlingSendEvent:YES];

            originalImplementation(application, @selector(sendEvent:), event);

            [application setHandlingSendEvent:wasHandlingSendEvent];
        };
        method_setImplementation(originalMethod, imp_implementationWithBlock(replacementBlock));
    });
}

typedef struct {
    cef_client_t client;
    cef_life_span_handler_t life_span_handler;
    cef_display_handler_t display_handler;
    cef_load_handler_t load_handler;
    struct cmux_chromium_browser_t *browser_handle;
} cmux_chromium_client_t;

typedef struct cmux_chromium_browser_t {
    NSView *__unsafe_unretained parent_view;
    cef_browser_t *browser;
    cmux_chromium_client_t *client;
    BOOL is_closing;
} cmux_chromium_browser_t;

typedef struct {
    cef_app_t app;
    cef_browser_process_handler_t browser_process_handler;
} cmux_chromium_app_t;

static void CEF_CALLBACK NoopAddRef(cef_base_ref_counted_t *self) {}
static int CEF_CALLBACK NoopRelease(cef_base_ref_counted_t *self) { return 0; }
static int CEF_CALLBACK NoopHasOneRef(cef_base_ref_counted_t *self) { return 0; }
static int CEF_CALLBACK NoopHasAtLeastOneRef(cef_base_ref_counted_t *self) { return 1; }

static void InitBase(cef_base_ref_counted_t *base, size_t size) {
    memset(base, 0, size);
    base->size = size;
    base->add_ref = NoopAddRef;
    base->release = NoopRelease;
    base->has_one_ref = NoopHasOneRef;
    base->has_at_least_one_ref = NoopHasAtLeastOneRef;
}

static void AppendSwitch(cef_command_line_t *command_line, const char *name) {
    cef_string_t cef_name = {};
    cef_string_from_utf8(name, strlen(name), &cef_name);
    command_line->append_switch(command_line, &cef_name);
    cef_string_clear(&cef_name);
}

static void AppendSwitchWithValue(cef_command_line_t *command_line, const char *name, const char *value) {
    cef_string_t cef_name = {};
    cef_string_t cef_value = {};
    cef_string_from_utf8(name, strlen(name), &cef_name);
    cef_string_from_utf8(value, strlen(value), &cef_value);
    command_line->append_switch_with_value(command_line, &cef_name, &cef_value);
    cef_string_clear(&cef_name);
    cef_string_clear(&cef_value);
}

static void CEF_CALLBACK OnBeforeCommandLineProcessing(
    cef_app_t *self,
    const cef_string_t *process_type,
    cef_command_line_t *command_line
) {
    AppendSwitch(command_line, "disable-background-networking");
    AppendSwitch(command_line, "disable-component-update");
    AppendSwitch(command_line, "disable-domain-reliability");
    AppendSwitch(command_line, "disable-sync");
    AppendSwitch(command_line, "use-mock-keychain");
    AppendSwitchWithValue(command_line, "remote-allow-origins", "http://127.0.0.1:9223");
    AppendSwitchWithValue(
        command_line,
        "disable-features",
        "DesktopPWAs,DesktopPWAsWithoutExtensions,DesktopPWAsRunOnOsLogin,WebAppEnableShortcutsMenu"
    );
}

static void CmuxDoMessageLoopWork(void) {
    if (g_initialized) {
        cef_do_message_loop_work();
    }
}

static void CEF_CALLBACK OnScheduleMessagePumpWork(
    cef_browser_process_handler_t *self,
    int64_t delay_ms
) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_scheduled_message_loop_timer invalidate];
        g_scheduled_message_loop_timer = [NSTimer scheduledTimerWithTimeInterval:MAX(0, delay_ms) / 1000.0
                                                                          repeats:NO
                                                                            block:^(__unused NSTimer *timer) {
            CmuxDoMessageLoopWork();
        }];
    });
}

static cef_browser_process_handler_t *CEF_CALLBACK GetBrowserProcessHandler(cef_app_t *self) {
    cmux_chromium_app_t *app = (cmux_chromium_app_t *)self;
    return &app->browser_process_handler;
}

static cef_app_t *CmuxChromiumApp(void) {
    static cmux_chromium_app_t app = {};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        InitBase(&app.app.base, sizeof(cef_app_t));
        InitBase(&app.browser_process_handler.base, sizeof(cef_browser_process_handler_t));
        app.app.on_before_command_line_processing = OnBeforeCommandLineProcessing;
        app.app.get_browser_process_handler = GetBrowserProcessHandler;
        app.browser_process_handler.on_schedule_message_pump_work = OnScheduleMessagePumpWork;
    });
    return &app.app;
}

static cef_life_span_handler_t *CEF_CALLBACK GetLifeSpanHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->life_span_handler;
}

static cef_display_handler_t *CEF_CALLBACK GetDisplayHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->display_handler;
}

static cef_load_handler_t *CEF_CALLBACK GetLoadHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->load_handler;
}

static void CEF_CALLBACK OnBeforeClose(cef_life_span_handler_t *self, cef_browser_t *browser) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, life_span_handler));
    if (client->browser_handle && client->browser_handle->browser == browser) {
        client->browser_handle->browser = nullptr;
        client->browser_handle->parent_view = nil;
        client->browser_handle->is_closing = YES;
    }
    browser->base.release(&browser->base);
}

static int CEF_CALLBACK OnConsoleMessage(
    cef_display_handler_t *self,
    cef_browser_t *browser,
    cef_log_severity_t level,
    const cef_string_t *message,
    const cef_string_t *source,
    int line
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, display_handler));
    if (!message || !message->str) return 0;
    NSString *text = [[NSString alloc] initWithCharacters:(const unichar *)message->str length:message->length];
    if (![text hasPrefix:CmuxChromiumReactGrabMessagePrefix]) {
        return 0;
    }

    NSString *payload = [text substringFromIndex:CmuxChromiumReactGrabMessagePrefix.length];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!client->browser_handle) return;
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumReactGrabMessageNotification
                                                          object:nil
                                                        userInfo:@{
                                                            @"browserHandle": [NSValue valueWithPointer:client->browser_handle],
                                                            @"payload": payload
                                                        }];
    });
    return 1;
}

static void CEF_CALLBACK OnAfterCreated(cef_life_span_handler_t *self, cef_browser_t *browser) {
    browser->base.release(&browser->base);
}

static cmux_chromium_client_t *CreateClient(void) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)calloc(1, sizeof(cmux_chromium_client_t));
    InitBase(&client->client.base, sizeof(cef_client_t));
    InitBase(&client->life_span_handler.base, sizeof(cef_life_span_handler_t));
    InitBase(&client->display_handler.base, sizeof(cef_display_handler_t));
    InitBase(&client->load_handler.base, sizeof(cef_load_handler_t));
    client->client.get_life_span_handler = GetLifeSpanHandler;
    client->client.get_display_handler = GetDisplayHandler;
    client->client.get_load_handler = GetLoadHandler;
    client->life_span_handler.on_after_created = OnAfterCreated;
    client->life_span_handler.on_before_close = OnBeforeClose;
    client->display_handler.on_console_message = OnConsoleMessage;
    return client;
}

BOOL cmux_chromium_runtime_available(void) {
    NSString *frameworkPath = CmuxChromiumFrameworkPath();
    NSString *helperPath = CmuxChromiumHelperPath();
    return frameworkPath.length > 0 &&
        helperPath.length > 0 &&
        [NSFileManager.defaultManager isExecutableFileAtPath:frameworkPath] &&
        [NSFileManager.defaultManager isExecutableFileAtPath:helperPath];
}

BOOL cmux_chromium_initialize(void) {
    if (g_initialized) return YES;
    if (!cmux_chromium_runtime_available()) {
        SetLastError(@"CEF framework or helper is missing from the app bundle.");
        return NO;
    }

    CmuxInstallChromiumEventBridge();

    NSString *frameworkPath = CmuxChromiumFrameworkPath();
    if (!cef_load_library(frameworkPath.UTF8String)) {
        SetLastError([NSString stringWithFormat:@"Could not load CEF framework at %@", frameworkPath]);
        return NO;
    }
    cef_api_hash(CEF_API_VERSION, 0);

    const char *argv0 = NSBundle.mainBundle.executablePath.UTF8String ?: "cmux";
    g_argv = (char **)calloc(1, sizeof(char *));
    g_argv[0] = strdup(argv0);
    cef_main_args_t args = {};
    args.argc = 1;
    args.argv = g_argv;

    cef_settings_t settings = {};
    settings.size = sizeof(cef_settings_t);
    settings.no_sandbox = 1;
    settings.external_message_pump = 1;
    settings.remote_debugging_port = 9223;
    SetCefString(&settings.browser_subprocess_path, CmuxChromiumHelperPath());
    SetCefString(&settings.framework_dir_path, CmuxChromiumFrameworkDirectoryPath());
    SetCefString(&settings.main_bundle_path, NSBundle.mainBundle.bundlePath);
    SetCefString(&settings.resources_dir_path, CmuxChromiumResourcesPath());

    NSURL *appSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *cacheURL = [[appSupport URLByAppendingPathComponent:@"cmux" isDirectory:YES] URLByAppendingPathComponent:@"Chromium" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:cacheURL withIntermediateDirectories:YES attributes:nil error:nil];
    SetCefString(&settings.root_cache_path, cacheURL.path);
    SetCefString(&settings.cache_path, [cacheURL URLByAppendingPathComponent:@"Default" isDirectory:YES].path);
    SetCefString(&settings.log_file, [cacheURL URLByAppendingPathComponent:@"debug.log"].path);

    if (!cef_initialize(&args, &settings, CmuxChromiumApp(), nullptr)) {
        SetLastError(@"cef_initialize returned false.");
        return NO;
    }

    cef_string_clear(&settings.browser_subprocess_path);
    cef_string_clear(&settings.framework_dir_path);
    cef_string_clear(&settings.main_bundle_path);
    cef_string_clear(&settings.resources_dir_path);
    cef_string_clear(&settings.root_cache_path);
    cef_string_clear(&settings.cache_path);
    cef_string_clear(&settings.log_file);

    g_initialized = YES;
    g_message_loop_timer = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(__unused NSTimer *timer) {
        CmuxDoMessageLoopWork();
    }];
    return YES;
}

const char *cmux_chromium_last_error(void) {
    return g_last_error.c_str();
}

void *cmux_chromium_create_browser(NSView *parentView, const char *url) {
    if (!cmux_chromium_initialize()) return nullptr;

    cmux_chromium_client_t *client = CreateClient();
    cef_window_info_t window_info = {};
    window_info.size = sizeof(cef_window_info_t);
    window_info.parent_view = (__bridge void *)parentView;
    window_info.bounds.x = 0;
    window_info.bounds.y = 0;
    window_info.bounds.width = MAX(1, (int)parentView.bounds.size.width);
    window_info.bounds.height = MAX(1, (int)parentView.bounds.size.height);
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

    cef_browser_settings_t browser_settings = {};
    browser_settings.size = sizeof(cef_browser_settings_t);

    cef_string_t cef_url = {};
    cef_string_from_utf8(url ?: "about:blank", strlen(url ?: "about:blank"), &cef_url);
    cef_browser_t *browser = cef_browser_host_create_browser_sync(&window_info, &client->client, &cef_url, &browser_settings, nullptr, nullptr);
    cef_string_clear(&cef_url);

    if (!browser) {
        SetLastError(@"CEF did not create a browser.");
        free(client);
        return nullptr;
    }

    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)calloc(1, sizeof(cmux_chromium_browser_t));
    handle->parent_view = parentView;
    handle->browser = browser;
    handle->client = client;
    client->browser_handle = handle;
    cmux_chromium_resize_browser(handle);
    return handle;
}

NSView *cmux_chromium_browser_view(void *browserHandle) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->browser) return nil;
    cef_browser_host_t *host = handle->browser->get_host(handle->browser);
    if (!host) return nil;
    void *window_handle = host->get_window_handle(host);
    host->base.release(&host->base);
    return (__bridge NSView *)window_handle;
}

static NSView *AttachBrowserView(cmux_chromium_browser_t *handle) {
    if (!handle || !handle->parent_view) return nil;
    NSView *browserView = cmux_chromium_browser_view(handle);
    if (!browserView) return nil;

    if (browserView.superview != handle->parent_view) {
        [browserView removeFromSuperview];
        [handle->parent_view addSubview:browserView positioned:NSWindowBelow relativeTo:nil];
    }

    browserView.hidden = NO;
    browserView.frame = handle->parent_view.bounds;
    browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return browserView;
}

void cmux_chromium_resize_browser(void *browserHandle) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->parent_view) return;
    AttachBrowserView(handle);
    if (!handle->browser) return;
    cef_browser_host_t *host = handle->browser->get_host(handle->browser);
    if (!host) return;
    host->was_resized(host);
    host->base.release(&host->base);
}

void cmux_chromium_close_browser(void *browserHandle) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle) return;
    if (!handle->browser || handle->is_closing) return;

    handle->is_closing = YES;
    cef_browser_host_t *host = handle->browser->get_host(handle->browser);
    if (host) {
        host->close_browser(host, 1);
        host->base.release(&host->base);
    }
}

static void WithBrowser(void *browserHandle, void (^block)(cef_browser_t *browser)) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->browser) return;
    block(handle->browser);
}

void cmux_chromium_load_url(void *browserHandle, const char *url) {
    WithBrowser(browserHandle, ^(cef_browser_t *browser) {
        cef_frame_t *frame = browser->get_main_frame(browser);
        if (!frame) return;
        cef_string_t cef_url = {};
        cef_string_from_utf8(url ?: "about:blank", strlen(url ?: "about:blank"), &cef_url);
        frame->load_url(frame, &cef_url);
        cef_string_clear(&cef_url);
        frame->base.release(&frame->base);
    });
}

void cmux_chromium_execute_javascript(void *browserHandle, const char *script) {
    WithBrowser(browserHandle, ^(cef_browser_t *browser) {
        cef_frame_t *frame = browser->get_main_frame(browser);
        if (!frame) return;
        cef_string_t cef_code = {};
        cef_string_t cef_url = {};
        cef_string_from_utf8(script ?: "", strlen(script ?: ""), &cef_code);
        cef_string_from_utf8("cmux://react-grab", strlen("cmux://react-grab"), &cef_url);
        frame->execute_java_script(frame, &cef_code, &cef_url, 1);
        cef_string_clear(&cef_code);
        cef_string_clear(&cef_url);
        frame->base.release(&frame->base);
    });
}

void cmux_chromium_go_back(void *browserHandle) {
    WithBrowser(browserHandle, ^(cef_browser_t *browser) { if (browser->can_go_back(browser)) browser->go_back(browser); });
}

void cmux_chromium_go_forward(void *browserHandle) {
    WithBrowser(browserHandle, ^(cef_browser_t *browser) { if (browser->can_go_forward(browser)) browser->go_forward(browser); });
}

void cmux_chromium_reload(void *browserHandle) {
    WithBrowser(browserHandle, ^(cef_browser_t *browser) { browser->reload(browser); });
}

void cmux_chromium_stop_loading(void *browserHandle) {
    WithBrowser(browserHandle, ^(cef_browser_t *browser) { browser->stop_load(browser); });
}

void cmux_chromium_set_focus(void *browserHandle, BOOL focus) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->browser) return;

    NSView *browserView = AttachBrowserView(handle);
    if (focus && browserView.window) {
        [browserView.window makeFirstResponder:browserView];
    } else if (!focus && browserView.window.firstResponder == browserView) {
        [browserView.window makeFirstResponder:nil];
    }

    cef_browser_host_t *host = handle->browser->get_host(handle->browser);
    if (!host) return;
    host->set_focus(host, focus ? 1 : 0);
    host->base.release(&host->base);
}

BOOL cmux_chromium_has_dev_tools(void *browserHandle) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->browser) return NO;
    cef_browser_host_t *host = handle->browser->get_host(handle->browser);
    if (!host) return NO;
    BOOL result = host->has_dev_tools(host) ? YES : NO;
    host->base.release(&host->base);
    return result;
}

void cmux_chromium_show_dev_tools(void *browserHandle) {
    WithBrowser(browserHandle, ^(cef_browser_t *browser) {
        cef_browser_host_t *host = browser->get_host(browser);
        if (!host) return;
        if (host->has_dev_tools(host)) {
            host->base.release(&host->base);
            return;
        }
        cef_window_info_t window_info = {};
        window_info.size = sizeof(cef_window_info_t);
        window_info.bounds.width = 1100;
        window_info.bounds.height = 780;
        cef_browser_settings_t settings = {};
        settings.size = sizeof(cef_browser_settings_t);
        host->show_dev_tools(host, &window_info, nullptr, &settings, nullptr);
        host->base.release(&host->base);
    });
}

void cmux_chromium_close_dev_tools(void *browserHandle) {
    WithBrowser(browserHandle, ^(cef_browser_t *browser) {
        cef_browser_host_t *host = browser->get_host(browser);
        if (!host) return;
        host->close_dev_tools(host);
        host->base.release(&host->base);
    });
}
