#define OS_MAC 1
#define WRAPPING_CEF_SHARED 1

#import "CmuxChromiumBridge.h"

#import <objc/message.h>
#import <objc/runtime.h>

#include <dispatch/dispatch.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <algorithm>
#include <atomic>
#include <string>
#include <string.h>
#include <vector>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_permission_handler_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_application_mac.h"
#include "libcef_dll/wrapper/libcef_dll_dylib.cc"

static std::string g_last_error;
static NSString *const CmuxChromiumReactGrabMessageNotification = @"CmuxChromiumReactGrabMessageNotification";
static NSString *const CmuxChromiumReactGrabMessagePrefix = @"__CMUX_REACT_GRAB__";
static NSString *const CmuxChromiumWindowCloseMessage = @"__CMUX_WINDOW_CLOSE__";
static NSString *const CmuxChromiumNavigationStateNotification = @"CmuxChromiumNavigationStateNotification";
static NSString *const CmuxChromiumBrowserClosedNotification = @"CmuxChromiumBrowserClosedNotification";
static NSString *const CmuxChromiumPopupRequestNotification = @"CmuxChromiumPopupRequestNotification";
static NSString *const CmuxChromiumDownloadEventNotification = @"CmuxChromiumDownloadEventNotification";
static NSString *const CmuxChromiumFaviconURLsNotification = @"CmuxChromiumFaviconURLsNotification";
static NSString *const CmuxChromiumFindResultNotification = @"CmuxChromiumFindResultNotification";
static NSString *const CmuxChromiumContextMenuActionNotification = @"CmuxChromiumContextMenuActionNotification";
static NSString *const CmuxChromiumCloseRequestNotification = @"CmuxChromiumCloseRequestNotification";
static const int CmuxChromiumMenuOpenLinkInNewTab = MENU_ID_USER_FIRST + 1;
static const int CmuxChromiumMenuOpenLinkInDefaultBrowser = MENU_ID_USER_FIRST + 2;
static const int CmuxChromiumMenuDownloadLinkedFile = MENU_ID_USER_FIRST + 3;
static const int CmuxChromiumMenuDownloadImage = MENU_ID_USER_FIRST + 4;
static const int CmuxChromiumMenuMoveTabToNewWorkspace = MENU_ID_USER_FIRST + 5;
static const int CmuxChromiumMenuInspectElement = MENU_ID_USER_FIRST + 6;
static BOOL g_initialized = NO;
static NSTimer *g_scheduled_message_loop_timer = nil;
static BOOL g_message_loop_working = NO;
static BOOL g_message_loop_reentrant = NO;
static char **g_argv = nullptr;

@class CmuxChromiumPopupWindowController;

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

static NSString *CmuxChromiumProfileName(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    return bundleIdentifier.length > 0 ? bundleIdentifier : @"default";
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

static void AddMenuItem(cef_menu_model_t *model, int commandID, NSString *label) {
    if (!model || !label) return;
    cef_string_t cef_label = {};
    SetCefString(&cef_label, label);
    model->add_item(model, commandID, &cef_label);
    cef_string_clear(&cef_label);
}

static void AddMenuSeparatorIfNeeded(cef_menu_model_t *model) {
    if (!model || model->get_count(model) == 0) return;
    model->add_separator(model);
}

static NSString *NSStringFromCefString(const cef_string_t *value) {
    if (!value || !value->str || value->length == 0) return @"";
    return [[NSString alloc] initWithCharacters:(const unichar *)value->str length:value->length] ?: @"";
}

static NSString *NSStringFromCefUserFreeString(cef_string_userfree_t value) {
    if (!value) return @"";
    NSString *result = NSStringFromCefString(value);
    cef_string_userfree_free(value);
    return result;
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

typedef struct cmux_chromium_client_t {
    cef_client_t client;
    cef_life_span_handler_t life_span_handler;
    cef_context_menu_handler_t context_menu_handler;
    cef_display_handler_t display_handler;
    cef_load_handler_t load_handler;
    cef_request_handler_t request_handler;
    cef_download_handler_t download_handler;
    cef_permission_handler_t permission_handler;
    cef_find_handler_t find_handler;
    struct cmux_chromium_browser_t *browser_handle;
    CmuxChromiumPopupWindowController *__unsafe_unretained popup_controller;
    CmuxChromiumPopupWindowController *__unsafe_unretained pending_popup_controller;
    NSView *__unsafe_unretained pending_popup_parent_view;
    struct cmux_chromium_browser_t *pending_popup_opener_handle;
    int pending_popup_id;
    CmuxChromiumPopupWindowController *__unsafe_unretained allowed_popup_controller;
    struct cmux_chromium_client_t *allowed_popup_client;
    int allowed_popup_id;
} cmux_chromium_client_t;

typedef struct cmux_chromium_browser_t {
    NSView *__unsafe_unretained parent_view;
    cef_browser_t *browser;
    cmux_chromium_client_t *client;
    CFTypeRef notification_object;
    NSRect last_sent_bounds;
    BOOL has_sent_bounds;
    struct cmux_chromium_browser_t *opener_handle;
    std::vector<struct cmux_chromium_browser_t *> child_popups;
    BOOL is_closing;
    BOOL dispose_when_closed;
} cmux_chromium_browser_t;

typedef struct cmux_chromium_navigation_entry_visitor_t {
    cef_navigation_entry_visitor_t visitor;
    std::atomic<int> ref_count;
    cmux_chromium_client_t *client;
    std::vector<std::string> urls;
    int current_index;
} cmux_chromium_navigation_entry_visitor_t;

static cmux_chromium_browser_t *CreateBrowserHandle(void) {
    auto *handle = new cmux_chromium_browser_t();
    handle->notification_object = CFBridgingRetain([NSValue valueWithPointer:handle]);
    return handle;
}

static void DeleteBrowserHandle(cmux_chromium_browser_t *handle) {
    if (!handle) return;
    if (handle->notification_object) {
        CFRelease(handle->notification_object);
        handle->notification_object = nullptr;
    }
    delete handle;
}

static id CmuxChromiumNotificationObject(cmux_chromium_browser_t *handle) {
    if (!handle || !handle->notification_object) return nil;
    return (__bridge id)handle->notification_object;
}

typedef struct {
    cef_app_t app;
    cef_browser_process_handler_t browser_process_handler;
} cmux_chromium_app_t;

static NSRect CmuxChromiumPopupContentRect(
    CGFloat requestedWidth,
    CGFloat requestedHeight,
    BOOL hasRequestedX,
    CGFloat requestedX,
    BOOL hasRequestedTopY,
    CGFloat requestedTopY,
    NSRect visibleFrame
) {
    CGFloat minWidth = 200;
    CGFloat minHeight = 150;
    CGFloat width = MIN(MAX(requestedWidth > 0 ? requestedWidth : 800, minWidth), visibleFrame.size.width);
    CGFloat height = MIN(MAX(requestedHeight > 0 ? requestedHeight : 600, minHeight), visibleFrame.size.height);

    CGFloat x = visibleFrame.origin.x + (visibleFrame.size.width - width) / 2;
    CGFloat y = visibleFrame.origin.y + (visibleFrame.size.height - height) / 2;
    if (hasRequestedX && hasRequestedTopY) {
        x = MAX(visibleFrame.origin.x, MIN(requestedX, NSMaxX(visibleFrame) - width));
        CGFloat appKitY = NSMaxY(visibleFrame) - requestedTopY - height;
        y = MAX(visibleFrame.origin.y, MIN(appKitY, NSMaxY(visibleFrame) - height));
    }

    return NSMakeRect(x, y, width, height);
}

@interface CmuxChromiumPopupPanel : NSPanel
@end

@implementation CmuxChromiumPopupPanel
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"w"]) {
        [self performClose:nil];
        return YES;
    }
    return [super performKeyEquivalent:event];
}
@end

@interface CmuxChromiumPopupWindowController : NSObject <NSWindowDelegate>
@property(nonatomic, readonly) NSView *parentView;
- (instancetype)initWithURL:(NSString *)url popupFeatures:(const cef_popup_features_t *)popupFeatures openerView:(NSView *)openerView;
- (void)setBrowserHandle:(void *)browserHandle;
- (void)browserDidClose;
- (void)closePopup;
- (void)updateURL:(NSString *)url;
- (void)updateTitle:(NSString *)title;
@end

@implementation CmuxChromiumPopupWindowController {
    CmuxChromiumPopupPanel *_panel;
    NSTextField *_urlLabel;
    NSView *_parentView;
    void *_browserHandle;
    BOOL _browserDidClose;
}

static char CmuxChromiumPopupAssociatedObjectKey;

- (instancetype)initWithURL:(NSString *)url popupFeatures:(const cef_popup_features_t *)popupFeatures openerView:(NSView *)openerView {
    self = [super init];
    if (!self) return nil;

    NSScreen *screen = openerView.window.screen ?: NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
    CGFloat requestedWidth = popupFeatures && popupFeatures->widthSet ? popupFeatures->width : 800;
    CGFloat requestedHeight = popupFeatures && popupFeatures->heightSet ? popupFeatures->height : 600;
    NSRect contentRect = CmuxChromiumPopupContentRect(
        requestedWidth,
        requestedHeight,
        popupFeatures && popupFeatures->xSet,
        popupFeatures ? popupFeatures->x : 0,
        popupFeatures && popupFeatures->ySet,
        popupFeatures ? popupFeatures->y : 0,
        visibleFrame
    );

    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    _panel = [[CmuxChromiumPopupPanel alloc] initWithContentRect:contentRect styleMask:styleMask backing:NSBackingStoreBuffered defer:NO];
    _panel.identifier = @"cmux.browser-popup";
    _panel.level = NSNormalWindowLevel;
    _panel.hidesOnDeactivate = NO;
    _panel.releasedWhenClosed = NO;
    _panel.minSize = NSMakeSize(200, 150);
    _panel.title = url.length > 0 ? url : @"";
    _panel.delegate = self;

    NSView *containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, contentRect.size.width, contentRect.size.height)];
    containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _urlLabel = [NSTextField labelWithString:url ?: @""];
    _urlLabel.font = [NSFont systemFontOfSize:11];
    _urlLabel.textColor = NSColor.secondaryLabelColor;
    _urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _urlLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _parentView = [[NSView alloc] initWithFrame:NSZeroRect];
    _parentView.translatesAutoresizingMaskIntoConstraints = NO;
    _parentView.wantsLayer = YES;
    _parentView.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    [containerView addSubview:_urlLabel];
    [containerView addSubview:_parentView];
    _panel.contentView = containerView;
    [NSLayoutConstraint activateConstraints:@[
        [_urlLabel.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:4],
        [_urlLabel.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:8],
        [_urlLabel.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-8],
        [_urlLabel.heightAnchor constraintEqualToConstant:16],
        [_parentView.topAnchor constraintEqualToAnchor:_urlLabel.bottomAnchor constant:2],
        [_parentView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor],
        [_parentView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor],
        [_parentView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor],
    ]];

    objc_setAssociatedObject(_panel, &CmuxChromiumPopupAssociatedObjectKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [_panel makeKeyAndOrderFront:self];
    return self;
}

- (NSView *)parentView {
    return _parentView;
}

- (void)setBrowserHandle:(void *)browserHandle {
    _browserHandle = browserHandle;
}

- (void)browserDidClose {
    _browserDidClose = YES;
    _browserHandle = nullptr;
    if (_panel.visible) {
        [_panel close];
    }
}

- (void)closePopup {
    [_panel performClose:nil];
}

- (void)updateURL:(NSString *)url {
    _urlLabel.stringValue = url ?: @"";
}

- (void)updateTitle:(NSString *)title {
    if (title.length > 0) {
        _panel.title = title;
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    if (!_browserDidClose && _browserHandle) {
        cmux_chromium_close_browser(_browserHandle);
    }
    _browserHandle = nullptr;
    objc_setAssociatedObject(_panel, &CmuxChromiumPopupAssociatedObjectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

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

static void CEF_CALLBACK NavigationEntryVisitorAddRef(cef_base_ref_counted_t *base) {
    auto *visitor = (cmux_chromium_navigation_entry_visitor_t *)((char *)base - offsetof(cmux_chromium_navigation_entry_visitor_t, visitor));
    visitor->ref_count.fetch_add(1, std::memory_order_relaxed);
}

static int CEF_CALLBACK NavigationEntryVisitorRelease(cef_base_ref_counted_t *base) {
    auto *visitor = (cmux_chromium_navigation_entry_visitor_t *)((char *)base - offsetof(cmux_chromium_navigation_entry_visitor_t, visitor));
    if (visitor->ref_count.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        delete visitor;
        return 1;
    }
    return 0;
}

static int CEF_CALLBACK NavigationEntryVisitorHasOneRef(cef_base_ref_counted_t *base) {
    auto *visitor = (cmux_chromium_navigation_entry_visitor_t *)((char *)base - offsetof(cmux_chromium_navigation_entry_visitor_t, visitor));
    return visitor->ref_count.load(std::memory_order_acquire) == 1 ? 1 : 0;
}

static int CEF_CALLBACK NavigationEntryVisitorHasAtLeastOneRef(cef_base_ref_counted_t *base) {
    auto *visitor = (cmux_chromium_navigation_entry_visitor_t *)((char *)base - offsetof(cmux_chromium_navigation_entry_visitor_t, visitor));
    return visitor->ref_count.load(std::memory_order_acquire) > 0 ? 1 : 0;
}

static cmux_chromium_client_t *CreateClient(void);

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

static int CmuxChromiumRemoteDebuggingPortValue(void) {
    static int port = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *identifier = NSBundle.mainBundle.bundleIdentifier ?: NSBundle.mainBundle.executablePath ?: @"cmux";
        uint32_t hash = 2166136261u;
        for (NSUInteger index = 0; index < identifier.length; index++) {
            hash ^= [identifier characterAtIndex:index];
            hash *= 16777619u;
        }
        port = 40000 + (int)(hash % 20000);
    });
    return port;
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
    char remoteOrigin[64];
    snprintf(remoteOrigin, sizeof(remoteOrigin), "http://127.0.0.1:%d", CmuxChromiumRemoteDebuggingPortValue());
    AppendSwitchWithValue(command_line, "remote-allow-origins", remoteOrigin);
    AppendSwitchWithValue(
        command_line,
        "disable-features",
        "DesktopPWAs,DesktopPWAsWithoutExtensions,DesktopPWAsRunOnOsLogin,WebAppEnableShortcutsMenu"
    );
}

static const int64_t CmuxMessageLoopMaxDelayMs = 1000 / 30;
static const int64_t CmuxMessageLoopIdleDelayPlaceholderMs = INT_MAX;

static void CmuxDoMessageLoopWork(void);

static void CmuxScheduleMessageLoopWorkOnMain(int64_t delay_ms) {
    if (delay_ms == CmuxMessageLoopIdleDelayPlaceholderMs && g_scheduled_message_loop_timer) {
        return;
    }

    [g_scheduled_message_loop_timer invalidate];
    g_scheduled_message_loop_timer = nil;

    if (delay_ms <= 0) {
        CmuxDoMessageLoopWork();
        return;
    }

    NSTimeInterval delaySeconds = MIN(delay_ms, CmuxMessageLoopMaxDelayMs) / 1000.0;
    g_scheduled_message_loop_timer = [NSTimer timerWithTimeInterval:delaySeconds repeats:NO block:^(__unused NSTimer *timer) {
        g_scheduled_message_loop_timer = nil;
        CmuxDoMessageLoopWork();
    }];
    [NSRunLoop.currentRunLoop addTimer:g_scheduled_message_loop_timer forMode:NSRunLoopCommonModes];
    [NSRunLoop.currentRunLoop addTimer:g_scheduled_message_loop_timer forMode:NSEventTrackingRunLoopMode];
}

static void CmuxPostMessageLoopWork(int64_t delay_ms) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CmuxScheduleMessageLoopWorkOnMain(delay_ms);
    });
}

static void CmuxDoMessageLoopWork(void) {
    if (!g_initialized) return;

    if (g_message_loop_working) {
        g_message_loop_reentrant = YES;
        return;
    }

    g_message_loop_reentrant = NO;
    g_message_loop_working = YES;
    cef_do_message_loop_work();
    g_message_loop_working = NO;

    if (g_message_loop_reentrant) {
        CmuxPostMessageLoopWork(0);
    } else if (!g_scheduled_message_loop_timer) {
        CmuxPostMessageLoopWork(CmuxMessageLoopIdleDelayPlaceholderMs);
    }
}

static void CEF_CALLBACK OnScheduleMessagePumpWork(
    cef_browser_process_handler_t *self,
    int64_t delay_ms
) {
    CmuxPostMessageLoopWork(delay_ms);
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

static cef_context_menu_handler_t *CEF_CALLBACK GetContextMenuHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->context_menu_handler;
}

static cef_display_handler_t *CEF_CALLBACK GetDisplayHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->display_handler;
}

static cef_load_handler_t *CEF_CALLBACK GetLoadHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->load_handler;
}

static cef_request_handler_t *CEF_CALLBACK GetRequestHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->request_handler;
}

static cef_download_handler_t *CEF_CALLBACK GetDownloadHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->download_handler;
}

static cef_permission_handler_t *CEF_CALLBACK GetPermissionHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->permission_handler;
}

static cef_find_handler_t *CEF_CALLBACK GetFindHandler(cef_client_t *self) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)self;
    return &client->find_handler;
}

static BOOL CmuxChromiumPopupFeaturesWereSpecified(const cef_popup_features_t *popupFeatures) {
    return popupFeatures &&
        (popupFeatures->xSet || popupFeatures->ySet || popupFeatures->widthSet || popupFeatures->heightSet || popupFeatures->isPopup);
}

static BOOL CmuxChromiumShouldOpenURLExternally(NSString *urlString) {
    Class policyClass = NSClassFromString(@"CmuxChromiumNavigationPolicy");
    SEL selector = @selector(shouldOpenURLExternally:);
    if (!policyClass || ![policyClass respondsToSelector:selector]) return NO;
    BOOL (*send)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
    return send(policyClass, selector, urlString ?: @"");
}

static NSString *CmuxChromiumBrowserURL(cef_browser_t *browser) {
    if (!browser) return @"";
    cef_frame_t *frame = browser->get_main_frame(browser);
    if (!frame) return @"";
    cef_string_userfree_t frame_url = frame->get_url(frame);
    NSString *url = NSStringFromCefString(frame_url);
    cef_string_userfree_free(frame_url);
    frame->base.release(&frame->base);
    return url ?: @"";
}

static void CmuxChromiumPostPopupRequest(
    cmux_chromium_client_t *client,
    NSString *url,
    BOOL userGesture,
    BOOL popupFeaturesWereSpecified,
    NSString *openerURL
) {
    cmux_chromium_browser_t *browserHandle = client ? client->browser_handle : nullptr;
    if (!browserHandle) return;
    id notificationObject = CmuxChromiumNotificationObject(browserHandle);
    NSValue *browserHandleValue = [NSValue valueWithPointer:browserHandle];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumPopupRequestNotification
                                                          object:notificationObject
                                                        userInfo:@{
                                                            @"browserHandle": browserHandleValue,
                                                            @"url": url ?: @"",
                                                            @"userGesture": @(userGesture),
                                                            @"popupFeaturesWereSpecified": @(popupFeaturesWereSpecified),
                                                            @"openerURL": openerURL ?: @""
        }];
    });
}

static void CmuxChromiumPostContextMenuAction(cmux_chromium_client_t *client, NSString *action, NSDictionary *extraUserInfo) {
    cmux_chromium_browser_t *browserHandle = client ? client->browser_handle : nullptr;
    if (!browserHandle) return;
    id notificationObject = CmuxChromiumNotificationObject(browserHandle);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary *userInfo = [@{
            @"browserHandle": [NSValue valueWithPointer:browserHandle],
            @"action": action ?: @""
        } mutableCopy];
        if (extraUserInfo) {
            [userInfo addEntriesFromDictionary:extraUserInfo];
        }
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumContextMenuActionNotification
                                                          object:notificationObject
                                                        userInfo:userInfo];
    });
}

static void CmuxChromiumPostCloseRequest(cmux_chromium_client_t *client) {
    if (!client || !client->browser_handle) return;
    NSValue *browserHandle = [NSValue valueWithPointer:client->browser_handle];
    id notificationObject = CmuxChromiumNotificationObject(client->browser_handle);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumCloseRequestNotification
                                                          object:notificationObject
                                                        userInfo:@{ @"browserHandle": browserHandle }];
    });
}

static void CmuxChromiumInstallWindowCloseBridge(cef_frame_t *frame) {
    if (!frame || !frame->is_main(frame)) return;
    static const char *script =
        "(function(){"
        "if(window.__CMUX_WINDOW_CLOSE_BRIDGE_INSTALLED__)return;"
        "Object.defineProperty(window,'__CMUX_WINDOW_CLOSE_BRIDGE_INSTALLED__',{value:true});"
        "Object.defineProperty(window,'close',{value:function(){console.info('__CMUX_WINDOW_CLOSE__');},configurable:true});"
        "})();";
    cef_string_t cef_code = {};
    cef_string_t cef_url = {};
    cef_string_from_utf8(script, strlen(script), &cef_code);
    cef_string_from_utf8("cmux://window-close", strlen("cmux://window-close"), &cef_url);
    frame->execute_java_script(frame, &cef_code, &cef_url, 1);
    cef_string_clear(&cef_code);
    cef_string_clear(&cef_url);
}

static void CmuxChromiumStartDownload(cef_browser_t *browser, NSString *url) {
    if (!browser || url.length == 0) return;
    cef_browser_host_t *host = browser->get_host(browser);
    if (!host) return;
    cef_string_t cef_url = {};
    SetCefString(&cef_url, url);
    host->start_download(host, &cef_url);
    cef_string_clear(&cef_url);
    host->base.release(&host->base);
}

static NSString *CmuxChromiumContextMenuLinkURL(cef_context_menu_params_t *params) {
    if (!params) return @"";
    return NSStringFromCefUserFreeString(params->get_link_url(params));
}

static NSString *CmuxChromiumContextMenuSourceURL(cef_context_menu_params_t *params) {
    if (!params) return @"";
    return NSStringFromCefUserFreeString(params->get_source_url(params));
}

static NSString *CmuxChromiumContextMenuMediaType(cef_context_menu_params_t *params) {
    if (!params) return @"";
    switch (params->get_media_type(params)) {
    case CM_MEDIATYPE_IMAGE:
        return @"image";
    case CM_MEDIATYPE_VIDEO:
        return @"video";
    case CM_MEDIATYPE_AUDIO:
        return @"audio";
    case CM_MEDIATYPE_CANVAS:
        return @"canvas";
    case CM_MEDIATYPE_FILE:
        return @"file";
    case CM_MEDIATYPE_PLUGIN:
        return @"plugin";
    default:
        return @"";
    }
}

static int CmuxChromiumContextMenuCommandForAction(NSString *action) {
    if ([action isEqualToString:@"openLinkInNewTab"]) return CmuxChromiumMenuOpenLinkInNewTab;
    if ([action isEqualToString:@"openLinkInDefaultBrowser"]) return CmuxChromiumMenuOpenLinkInDefaultBrowser;
    if ([action isEqualToString:@"downloadLinkedFile"]) return CmuxChromiumMenuDownloadLinkedFile;
    if ([action isEqualToString:@"downloadImage"]) return CmuxChromiumMenuDownloadImage;
    if ([action isEqualToString:@"moveTabToNewWorkspace"]) return CmuxChromiumMenuMoveTabToNewWorkspace;
    if ([action isEqualToString:@"inspectElement"]) return CmuxChromiumMenuInspectElement;
    return 0;
}

static NSString *CmuxChromiumContextMenuActionForCommand(int commandID) {
    switch (commandID) {
    case CmuxChromiumMenuOpenLinkInNewTab:
        return @"openLinkInNewTab";
    case CmuxChromiumMenuOpenLinkInDefaultBrowser:
        return @"openLinkInDefaultBrowser";
    case CmuxChromiumMenuDownloadLinkedFile:
        return @"downloadLinkedFile";
    case CmuxChromiumMenuDownloadImage:
        return @"downloadImage";
    case CmuxChromiumMenuMoveTabToNewWorkspace:
        return @"moveTabToNewWorkspace";
    case CmuxChromiumMenuInspectElement:
        return @"inspectElement";
    default:
        return @"";
    }
}

static NSArray<NSDictionary *> *CmuxChromiumContextMenuItems(NSString *linkURL, NSString *sourceURL, NSString *mediaType) {
    Class policyClass = NSClassFromString(@"CmuxChromiumContextMenuPolicy");
    SEL selector = @selector(menuItemsWithLinkURL:sourceURL:mediaType:);
    if (!policyClass || ![policyClass respondsToSelector:selector]) return @[];
    NSArray<NSDictionary *> *(*send)(id, SEL, NSString *, NSString *, NSString *) =
        (NSArray<NSDictionary *> *(*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend;
    NSArray<NSDictionary *> *items = send(policyClass, selector, linkURL ?: @"", sourceURL ?: @"", mediaType ?: @"");
    return [items isKindOfClass:NSArray.class] ? items : @[];
}

static void AddPermissionKey(NSMutableArray<NSString *> *keys, uint32_t permissions, uint32_t flag, NSString *key) {
    if ((permissions & flag) != 0) {
        [keys addObject:key];
    }
}

static NSArray<NSString *> *CmuxChromiumMediaPermissionKeys(uint32_t permissions) {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    AddPermissionKey(keys, permissions, CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE, @"microphone");
    AddPermissionKey(keys, permissions, CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE, @"camera");
    AddPermissionKey(keys, permissions, CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE, @"desktopAudio");
    AddPermissionKey(keys, permissions, CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE, @"desktopVideo");
    return keys;
}

static NSArray<NSString *> *CmuxChromiumPermissionKeys(uint32_t permissions) {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_AR_SESSION, @"arSession");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, @"cameraPanTiltZoom");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_CAMERA_STREAM, @"camera");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL, @"capturedSurfaceControl");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_CLIPBOARD, @"clipboard");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, @"topLevelStorageAccess");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_DISK_QUOTA, @"diskQuota");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_LOCAL_FONTS, @"localFonts");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_GEOLOCATION, @"geolocation");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_HAND_TRACKING, @"handTracking");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_IDENTITY_PROVIDER, @"identityProvider");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_IDLE_DETECTION, @"idleDetection");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_MIC_STREAM, @"microphone");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_MIDI_SYSEX, @"midiSysex");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, @"multipleDownloads");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_NOTIFICATIONS, @"notifications");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_KEYBOARD_LOCK, @"keyboardLock");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_POINTER_LOCK, @"pointerLock");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, @"protectedMediaIdentifier");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER, @"registerProtocolHandler");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_STORAGE_ACCESS, @"storageAccess");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_VR_SESSION, @"vrSession");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_WEB_APP_INSTALLATION, @"webAppInstallation");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, @"windowManagement");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, @"fileSystemAccess");
#if CEF_API_ADDED(13600)
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_LOCAL_NETWORK_ACCESS, @"localNetwork");
#endif
#if CEF_API_ADDED(14500)
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_LOCAL_NETWORK, @"localNetwork");
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, @"loopbackNetwork");
#endif
#if CEF_API_ADDED(14700)
    AddPermissionKey(keys, permissions, CEF_PERMISSION_TYPE_SENSORS, @"sensors");
#endif
    return keys;
}

static NSDictionary *CmuxChromiumPermissionPromptConfiguration(NSString *origin, NSArray<NSString *> *permissionKeys) {
    Class policyClass = NSClassFromString(@"CmuxChromiumPermissionPromptPolicy");
    SEL selector = @selector(promptConfigurationWithOrigin:permissionKeys:);
    if (policyClass && [policyClass respondsToSelector:selector]) {
        NSDictionary *(*send)(id, SEL, NSString *, NSArray<NSString *> *) =
            (NSDictionary *(*)(id, SEL, NSString *, NSArray<NSString *> *))objc_msgSend;
        NSDictionary *configuration = send(policyClass, selector, origin ?: @"", permissionKeys ?: @[]);
        if ([configuration isKindOfClass:NSDictionary.class]) {
            return configuration;
        }
    }
    return @{
        @"title": origin.length > 0
            ? [NSString stringWithFormat:@"Allow %@ to use browser permissions?", origin]
            : @"Allow this site to use browser permissions?",
        @"message": @"cmux will ask again next time.",
        @"allowTitle": @"Allow",
        @"denyTitle": @"Don't Allow",
    };
}

static NSWindow *CmuxChromiumBrowserWindow(cef_browser_t *browser) {
    if (!browser) return nil;
    cef_browser_host_t *host = browser->get_host(browser);
    if (!host) return nil;
    void *window_handle = host->get_window_handle(host);
    host->base.release(&host->base);
    NSView *view = (__bridge NSView *)window_handle;
    return view.window;
}

static void CmuxChromiumShowPermissionPrompt(
    cef_browser_t *browser,
    NSString *origin,
    NSArray<NSString *> *permissionKeys,
    void (^decisionHandler)(BOOL allow)
) {
    NSWindow *window = CmuxChromiumBrowserWindow(browser);
    NSDictionary *configuration = CmuxChromiumPermissionPromptConfiguration(origin, permissionKeys);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = configuration[@"title"] ?: @"Allow this site to use browser permissions?";
        alert.informativeText = configuration[@"message"] ?: @"cmux will ask again next time.";
        [alert addButtonWithTitle:configuration[@"allowTitle"] ?: @"Allow"];
        [alert addButtonWithTitle:configuration[@"denyTitle"] ?: @"Don't Allow"];

        void (^complete)(NSModalResponse) = ^(NSModalResponse response) {
            decisionHandler(response == NSAlertFirstButtonReturn);
        };
        if (window) {
            [alert beginSheetModalForWindow:window completionHandler:complete];
        } else {
            complete([alert runModal]);
        }
    });
}

static void CEF_CALLBACK OnBeforeContextMenu(
    cef_context_menu_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    cef_context_menu_params_t *params,
    cef_menu_model_t *model
) {
    if (!model || !params) return;

    NSArray<NSDictionary *> *items = CmuxChromiumContextMenuItems(
        CmuxChromiumContextMenuLinkURL(params),
        CmuxChromiumContextMenuSourceURL(params),
        CmuxChromiumContextMenuMediaType(params)
    );
    for (NSDictionary *item in items) {
        if ([item[@"separator"] boolValue]) {
            model->add_separator(model);
            continue;
        }
        if ([item[@"separatorIfNeeded"] boolValue]) {
            AddMenuSeparatorIfNeeded(model);
            continue;
        }
        int commandID = CmuxChromiumContextMenuCommandForAction(item[@"action"]);
        NSString *title = item[@"title"];
        if (commandID != 0 && [title isKindOfClass:NSString.class] && title.length > 0) {
            AddMenuItem(model, commandID, title);
        }
    }
}

static int CEF_CALLBACK OnContextMenuCommand(
    cef_context_menu_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    cef_context_menu_params_t *params,
    int command_id,
    cef_event_flags_t event_flags
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, context_menu_handler));
    NSString *linkURL = CmuxChromiumContextMenuLinkURL(params);
    NSString *sourceURL = CmuxChromiumContextMenuSourceURL(params);

    switch (command_id) {
    case CmuxChromiumMenuOpenLinkInNewTab:
    case CmuxChromiumMenuOpenLinkInDefaultBrowser:
        CmuxChromiumPostContextMenuAction(client, CmuxChromiumContextMenuActionForCommand(command_id), @{
            @"linkURL": linkURL ?: @"",
            @"sourceURL": sourceURL ?: @"",
            @"openerURL": CmuxChromiumBrowserURL(browser)
        });
        return 1;
    case CmuxChromiumMenuDownloadLinkedFile:
        CmuxChromiumStartDownload(browser, linkURL);
        return 1;
    case CmuxChromiumMenuDownloadImage:
        CmuxChromiumStartDownload(browser, sourceURL);
        return 1;
    case CmuxChromiumMenuMoveTabToNewWorkspace:
        CmuxChromiumPostContextMenuAction(client, @"moveTabToNewWorkspace", nil);
        return 1;
    case CmuxChromiumMenuInspectElement:
        CmuxChromiumPostContextMenuAction(client, @"inspectElement", @{
            @"x": @(params ? params->get_xcoord(params) : 0),
            @"y": @(params ? params->get_ycoord(params) : 0)
        });
        return 1;
    default:
        return 0;
    }
}

static BOOL CmuxChromiumDispositionOpensTab(cef_window_open_disposition_t disposition) {
    switch (disposition) {
    case CEF_WOD_SINGLETON_TAB:
    case CEF_WOD_NEW_FOREGROUND_TAB:
    case CEF_WOD_NEW_BACKGROUND_TAB:
    case CEF_WOD_NEW_WINDOW:
    case CEF_WOD_SWITCH_TO_TAB:
        return YES;
    default:
        return NO;
    }
}

static void CmuxChromiumDetachChildPopup(cmux_chromium_browser_t *child) {
    if (!child || !child->opener_handle) return;
    auto &children = child->opener_handle->child_popups;
    children.erase(std::remove(children.begin(), children.end(), child), children.end());
    child->opener_handle = nullptr;
}

static void CmuxChromiumClearAllowedPopup(cmux_chromium_client_t *client, int popup_id, BOOL closePanel) {
    if (!client || !client->allowed_popup_client || client->allowed_popup_id != popup_id) return;
    if (closePanel) {
        [client->allowed_popup_controller browserDidClose];
    }
    if (!client->allowed_popup_client->browser_handle) {
        free(client->allowed_popup_client);
    }
    client->allowed_popup_controller = nil;
    client->allowed_popup_client = nullptr;
    client->allowed_popup_id = 0;
}

static int CEF_CALLBACK OnOpenURLFromTab(
    cef_request_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    const cef_string_t *target_url,
    cef_window_open_disposition_t target_disposition,
    int user_gesture
) {
    if (!browser || !target_url || !target_url->str || target_url->length == 0) return 0;
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, request_handler));
    NSString *url = NSStringFromCefString(target_url);

    if (CmuxChromiumDispositionOpensTab(target_disposition)) {
        CmuxChromiumPostPopupRequest(
            client,
            url,
            user_gesture ? YES : NO,
            NO,
            CmuxChromiumBrowserURL(browser)
        );
        return 1;
    }

    return 0;
}

static void CEF_CALLBACK OnBeforeClose(cef_life_span_handler_t *self, cef_browser_t *browser) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, life_span_handler));
    cmux_chromium_browser_t *handle = client->browser_handle;
    if (handle && handle->browser == browser) {
        CmuxChromiumClearAllowedPopup(client, client->allowed_popup_id, YES);
        std::vector<cmux_chromium_browser_t *> children = handle->child_popups;
        handle->child_popups.clear();
        for (cmux_chromium_browser_t *child : children) {
            if (child) {
                child->opener_handle = nullptr;
                cmux_chromium_close_browser(child);
            }
        }
        CmuxChromiumDetachChildPopup(handle);
        handle->browser = nullptr;
        handle->parent_view = nil;
        handle->is_closing = YES;
        handle->client = nullptr;
        client->browser_handle = nullptr;
        [client->popup_controller browserDidClose];
        client->popup_controller = nil;
    }
    browser->base.release(&browser->base);
    if (handle) {
        if (handle->dispose_when_closed) {
            DeleteBrowserHandle(handle);
        } else {
            id notificationObject = CmuxChromiumNotificationObject(handle);
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumBrowserClosedNotification
                                                                  object:notificationObject
                                                                userInfo:@{ @"browserHandle": [NSValue valueWithPointer:handle] }];
            });
        }
    }
    free(client);
}

static int CEF_CALLBACK OnBeforePopup(
    cef_life_span_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    int popup_id,
    const cef_string_t *target_url,
    const cef_string_t *target_frame_name,
    cef_window_open_disposition_t target_disposition,
    int user_gesture,
    const cef_popup_features_t *popupFeatures,
    cef_window_info_t *windowInfo,
    cef_client_t **client,
    cef_browser_settings_t *settings,
    cef_dictionary_value_t **extra_info,
    int *no_javascript_access
) {
    if (!browser || !target_url || !target_url->str || target_url->length == 0) return 0;
    cmux_chromium_client_t *cmux_client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, life_span_handler));
    NSString *url = NSStringFromCefString(target_url);

    BOOL popupFeaturesWereSpecified = CmuxChromiumPopupFeaturesWereSpecified(popupFeatures);
    if (CmuxChromiumShouldOpenURLExternally(url) || CmuxChromiumDispositionOpensTab(target_disposition) || !popupFeaturesWereSpecified) {
        CmuxChromiumPostPopupRequest(
            cmux_client,
            url,
            user_gesture ? YES : NO,
            popupFeaturesWereSpecified,
            CmuxChromiumBrowserURL(browser)
        );
        return 1;
    }

    __block CmuxChromiumPopupWindowController *popupController = nil;
    if ([NSThread isMainThread]) {
        popupController = [[CmuxChromiumPopupWindowController alloc] initWithURL:url popupFeatures:popupFeatures openerView:cmux_client->browser_handle->parent_view];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            popupController = [[CmuxChromiumPopupWindowController alloc] initWithURL:url popupFeatures:popupFeatures openerView:cmux_client->browser_handle->parent_view];
        });
    }
    if (!popupController) {
        CmuxChromiumPostPopupRequest(
            cmux_client,
            url,
            user_gesture ? YES : NO,
            popupFeaturesWereSpecified,
            CmuxChromiumBrowserURL(browser)
        );
        return 1;
    }

    cmux_chromium_client_t *popupClient = CreateClient();
    popupClient->pending_popup_controller = popupController;
    popupClient->pending_popup_parent_view = popupController.parentView;
    popupClient->pending_popup_opener_handle = cmux_client->browser_handle;
    popupClient->pending_popup_id = popup_id;
    cmux_client->allowed_popup_controller = popupController;
    cmux_client->allowed_popup_client = popupClient;
    cmux_client->allowed_popup_id = popup_id;

    windowInfo->parent_view = (__bridge void *)popupController.parentView;
    windowInfo->bounds.x = 0;
    windowInfo->bounds.y = 0;
    windowInfo->bounds.width = MAX(1, (int)popupController.parentView.bounds.size.width);
    windowInfo->bounds.height = MAX(1, (int)popupController.parentView.bounds.size.height);
    windowInfo->runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    *client = &popupClient->client;
    return 0;
}

static void CEF_CALLBACK OnBeforePopupAborted(
    cef_life_span_handler_t *self,
    cef_browser_t *browser,
    int popup_id
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, life_span_handler));
    CmuxChromiumClearAllowedPopup(client, popup_id, YES);
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
    NSString *notificationName = nil;
    NSString *payload = nil;
    if ([text hasPrefix:CmuxChromiumReactGrabMessagePrefix]) {
        notificationName = CmuxChromiumReactGrabMessageNotification;
        payload = [text substringFromIndex:CmuxChromiumReactGrabMessagePrefix.length];
    } else if ([text isEqualToString:CmuxChromiumWindowCloseMessage]) {
        if (client->popup_controller) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [client->popup_controller closePopup];
            });
        } else {
            CmuxChromiumPostCloseRequest(client);
        }
        return 1;
    } else {
        return 0;
    }

    cmux_chromium_browser_t *browser_handle = client->browser_handle;
    if (!browser_handle) return 0;
    id notificationObject = CmuxChromiumNotificationObject(browser_handle);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:notificationName
                                                          object:notificationObject
                                                        userInfo:@{
                                                            @"browserHandle": [NSValue valueWithPointer:browser_handle],
                                                            @"payload": payload
                                                        }];
    });
    return 1;
}

static void CEF_CALLBACK OnLoadStart(
    cef_load_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    cef_transition_type_t transition_type
) {
    CmuxChromiumInstallWindowCloseBridge(frame);
}

static void PostNavigationState(cmux_chromium_client_t *client, cef_browser_t *browser, NSDictionary *changes) {
    if (!client || !client->browser_handle || !browser) return;
    id notificationObject = CmuxChromiumNotificationObject(client->browser_handle);
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:changes ?: @{}];
    payload[@"browserHandle"] = [NSValue valueWithPointer:client->browser_handle];
    payload[@"canGoBack"] = @(browser->can_go_back(browser) ? YES : NO);
    payload[@"canGoForward"] = @(browser->can_go_forward(browser) ? YES : NO);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumNavigationStateNotification
                                                          object:notificationObject
                                                        userInfo:payload];
    });
}

static NSString *CmuxChromiumNavigationEntryURL(cef_navigation_entry_t *entry) {
    if (!entry || !entry->is_valid(entry)) return @"";
    NSString *displayURL = NSStringFromCefUserFreeString(entry->get_display_url(entry));
    if (displayURL.length > 0) return displayURL;
    return NSStringFromCefUserFreeString(entry->get_url(entry));
}

static NSArray<NSString *> *CmuxChromiumNavigationEntryStrings(const std::vector<std::string> &urls, size_t start, size_t end) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (size_t index = start; index < end; index++) {
        NSString *url = [NSString stringWithUTF8String:urls[index].c_str()];
        if (url.length > 0) {
            [result addObject:url];
        }
    }
    return result;
}

static void CmuxChromiumPostNavigationEntries(cmux_chromium_navigation_entry_visitor_t *visitor) {
    if (!visitor || !visitor->client || !visitor->client->browser_handle) return;
    int currentIndex = visitor->current_index;
    size_t count = visitor->urls.size();
    NSArray<NSString *> *backHistoryURLStrings = @[];
    NSArray<NSString *> *forwardHistoryURLStrings = @[];
    if (currentIndex >= 0 && (size_t)currentIndex < count) {
        backHistoryURLStrings = CmuxChromiumNavigationEntryStrings(visitor->urls, 0, (size_t)currentIndex);
        forwardHistoryURLStrings = CmuxChromiumNavigationEntryStrings(visitor->urls, (size_t)currentIndex + 1, count);
    }

    NSValue *browserHandle = [NSValue valueWithPointer:visitor->client->browser_handle];
    id notificationObject = CmuxChromiumNotificationObject(visitor->client->browser_handle);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumNavigationStateNotification
                                                          object:notificationObject
                                                        userInfo:@{
                                                            @"browserHandle": browserHandle,
                                                            @"backHistoryURLStrings": backHistoryURLStrings,
                                                            @"forwardHistoryURLStrings": forwardHistoryURLStrings,
                                                        }];
    });
}

static int CEF_CALLBACK VisitNavigationEntry(
    cef_navigation_entry_visitor_t *self,
    cef_navigation_entry_t *entry,
    int current,
    int index,
    int total
) {
    auto *visitor = (cmux_chromium_navigation_entry_visitor_t *)self;
    NSString *url = CmuxChromiumNavigationEntryURL(entry);
    visitor->urls.push_back(url.UTF8String ?: "");
    if (current) {
        visitor->current_index = index;
    }
    if (index + 1 >= total) {
        CmuxChromiumPostNavigationEntries(visitor);
    }
    return 1;
}

static void CmuxChromiumRefreshNavigationEntries(cmux_chromium_client_t *client, cef_browser_t *browser) {
    if (!client || !client->browser_handle || !browser) return;
    cef_browser_host_t *host = browser->get_host(browser);
    if (!host) return;

    auto *visitor = new cmux_chromium_navigation_entry_visitor_t();
    memset(&visitor->visitor, 0, sizeof(cef_navigation_entry_visitor_t));
    visitor->visitor.base.size = sizeof(cef_navigation_entry_visitor_t);
    visitor->visitor.base.add_ref = NavigationEntryVisitorAddRef;
    visitor->visitor.base.release = NavigationEntryVisitorRelease;
    visitor->visitor.base.has_one_ref = NavigationEntryVisitorHasOneRef;
    visitor->visitor.base.has_at_least_one_ref = NavigationEntryVisitorHasAtLeastOneRef;
    visitor->visitor.visit = VisitNavigationEntry;
    visitor->ref_count.store(1, std::memory_order_relaxed);
    visitor->client = client;
    visitor->current_index = -1;

    host->get_navigation_entries(host, &visitor->visitor, 0);
    visitor->visitor.base.release(&visitor->visitor.base);
    host->base.release(&host->base);
}

static void CEF_CALLBACK OnAddressChange(
    cef_display_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    const cef_string_t *url
) {
    if (frame && !frame->is_main(frame)) return;
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, display_handler));
    PostNavigationState(client, browser, @{ @"url": NSStringFromCefString(url) });
    [client->popup_controller updateURL:NSStringFromCefString(url)];
}

static void CEF_CALLBACK OnTitleChange(
    cef_display_handler_t *self,
    cef_browser_t *browser,
    const cef_string_t *title
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, display_handler));
    PostNavigationState(client, browser, @{ @"title": NSStringFromCefString(title) });
    [client->popup_controller updateTitle:NSStringFromCefString(title)];
}

static void CEF_CALLBACK OnFaviconURLChange(
    cef_display_handler_t *self,
    cef_browser_t *browser,
    cef_string_list_t icon_urls
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, display_handler));
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    size_t count = cef_string_list_size(icon_urls);
    for (size_t index = 0; index < count; index++) {
        cef_string_t value = {};
        if (!cef_string_list_value(icon_urls, index, &value)) continue;
        NSString *url = NSStringFromCefString(&value);
        cef_string_clear(&value);
        if (url.length > 0) {
            [urls addObject:url];
        }
    }

    cmux_chromium_browser_t *browserHandle = client->browser_handle;
    if (!browserHandle) return;
    id notificationObject = CmuxChromiumNotificationObject(browserHandle);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumFaviconURLsNotification
                                                          object:notificationObject
                                                        userInfo:@{
                                                            @"browserHandle": [NSValue valueWithPointer:browserHandle],
                                                            @"urls": urls
                                                        }];
    });
}

static void CEF_CALLBACK OnFullscreenModeChange(
    cef_display_handler_t *self,
    cef_browser_t *browser,
    int fullscreen
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, display_handler));
    PostNavigationState(client, browser, @{ @"isFullscreen": @(fullscreen ? YES : NO) });
}

static void CEF_CALLBACK OnLoadingStateChange(
    cef_load_handler_t *self,
    cef_browser_t *browser,
    int is_loading,
    int can_go_back,
    int can_go_forward
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, load_handler));
    PostNavigationState(client, browser, @{
        @"isLoading": @(is_loading ? YES : NO),
        @"canGoBack": @(can_go_back ? YES : NO),
        @"canGoForward": @(can_go_forward ? YES : NO)
    });
}

static int CEF_CALLBACK CanDownload(
    cef_download_handler_t *self,
    cef_browser_t *browser,
    const cef_string_t *url,
    const cef_string_t *request_method
) {
    return 1;
}

static int CEF_CALLBACK OnBeforeDownload(
    cef_download_handler_t *self,
    cef_browser_t *browser,
    cef_download_item_t *download_item,
    const cef_string_t *suggested_name,
    cef_before_download_callback_t *callback
) {
    if (!callback) return 0;
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, download_handler));
    NSString *filename = NSStringFromCefString(suggested_name);
    uint32_t download_id = download_item && download_item->get_id ? download_item->get_id(download_item) : 0;
    cmux_chromium_browser_t *browserHandle = client->browser_handle;
    if (!browserHandle) return 0;
    id notificationObject = CmuxChromiumNotificationObject(browserHandle);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumDownloadEventNotification
                                                          object:notificationObject
                                                        userInfo:@{
                                                            @"browserHandle": [NSValue valueWithPointer:browserHandle],
                                                            @"status": @"started",
                                                            @"filename": filename,
                                                            @"id": @(download_id)
                                                        }];
    });
    cef_string_t download_path = {};
    callback->cont(callback, &download_path, 1);
    return 1;
}

static void CEF_CALLBACK OnDownloadUpdated(
    cef_download_handler_t *self,
    cef_browser_t *browser,
    cef_download_item_t *download_item,
    cef_download_item_callback_t *callback
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, download_handler));
    if (!download_item || !download_item->is_valid || !download_item->is_valid(download_item)) return;

    NSString *status = @"progress";
    if (download_item->is_complete && download_item->is_complete(download_item)) {
        status = @"finished";
    } else if (download_item->is_canceled && download_item->is_canceled(download_item)) {
        status = @"failed";
    } else if (download_item->is_interrupted && download_item->is_interrupted(download_item)) {
        status = @"failed";
    }

    NSString *filename = download_item->get_suggested_file_name
        ? NSStringFromCefUserFreeString(download_item->get_suggested_file_name(download_item))
        : @"";
    NSString *url = download_item->get_url
        ? NSStringFromCefUserFreeString(download_item->get_url(download_item))
        : @"";
    NSString *path = download_item->get_full_path
        ? NSStringFromCefUserFreeString(download_item->get_full_path(download_item))
        : @"";
    int64_t received_bytes = download_item->get_received_bytes ? download_item->get_received_bytes(download_item) : 0;
    int64_t total_bytes = download_item->get_total_bytes ? download_item->get_total_bytes(download_item) : 0;
    uint32_t download_id = download_item->get_id ? download_item->get_id(download_item) : 0;
    cmux_chromium_browser_t *browserHandle = client->browser_handle;
    if (!browserHandle) return;
    id notificationObject = CmuxChromiumNotificationObject(browserHandle);

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumDownloadEventNotification
                                                          object:notificationObject
                                                        userInfo:@{
                                                            @"browserHandle": [NSValue valueWithPointer:browserHandle],
                                                            @"status": status,
                                                            @"filename": filename,
                                                            @"url": url,
                                                            @"path": path,
                                                            @"receivedBytes": @(received_bytes),
                                                            @"totalBytes": @(total_bytes),
                                                            @"id": @(download_id)
                                                        }];
    });
}

static int CEF_CALLBACK OnRequestMediaAccessPermission(
    cef_permission_handler_t *self,
    cef_browser_t *browser,
    cef_frame_t *frame,
    const cef_string_t *requesting_origin,
    uint32_t requested_permissions,
    cef_media_access_callback_t *callback
) {
    if (!callback) return 0;
    callback->base.add_ref(&callback->base);
    CmuxChromiumShowPermissionPrompt(
        browser,
        NSStringFromCefString(requesting_origin),
        CmuxChromiumMediaPermissionKeys(requested_permissions),
        ^(BOOL allow) {
            if (allow) {
                callback->cont(callback, requested_permissions);
            } else {
                callback->cancel(callback);
            }
            callback->base.release(&callback->base);
        }
    );
    return 1;
}

static int CEF_CALLBACK OnShowPermissionPrompt(
    cef_permission_handler_t *self,
    cef_browser_t *browser,
    uint64_t prompt_id,
    const cef_string_t *requesting_origin,
    uint32_t requested_permissions,
    cef_permission_prompt_callback_t *callback
) {
    if (!callback) return 0;
    callback->base.add_ref(&callback->base);
    CmuxChromiumShowPermissionPrompt(
        browser,
        NSStringFromCefString(requesting_origin),
        CmuxChromiumPermissionKeys(requested_permissions),
        ^(BOOL allow) {
            callback->cont(callback, allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
            callback->base.release(&callback->base);
        }
    );
    return 1;
}

static void CEF_CALLBACK OnDismissPermissionPrompt(
    cef_permission_handler_t *self,
    cef_browser_t *browser,
    uint64_t prompt_id,
    cef_permission_request_result_t result
) {
}

static void CEF_CALLBACK OnFindResult(
    cef_find_handler_t *self,
    cef_browser_t *browser,
    int identifier,
    int count,
    const cef_rect_t *selectionRect,
    int activeMatchOrdinal,
    int finalUpdate
) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, find_handler));
    cmux_chromium_browser_t *browserHandle = client->browser_handle;
    if (!browserHandle) return;
    id notificationObject = CmuxChromiumNotificationObject(browserHandle);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CmuxChromiumFindResultNotification
                                                          object:notificationObject
                                                        userInfo:@{
                                                            @"browserHandle": [NSValue valueWithPointer:browserHandle],
                                                            @"identifier": @(identifier),
                                                            @"count": @(count),
                                                            @"activeMatchOrdinal": @(activeMatchOrdinal),
                                                            @"finalUpdate": @(finalUpdate ? YES : NO)
                                                        }];
    });
}

static void CEF_CALLBACK OnAfterCreated(cef_life_span_handler_t *self, cef_browser_t *browser) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, life_span_handler));
    if (client->pending_popup_controller && client->pending_popup_parent_view) {
        browser->base.add_ref(&browser->base);
        cmux_chromium_browser_t *handle = CreateBrowserHandle();
        handle->parent_view = client->pending_popup_parent_view;
        handle->browser = browser;
        handle->client = client;
        handle->opener_handle = client->pending_popup_opener_handle;
        client->browser_handle = handle;
        if (handle->opener_handle && handle->opener_handle->client) {
            CmuxChromiumClearAllowedPopup(handle->opener_handle->client, client->pending_popup_id, NO);
        }
        client->popup_controller = client->pending_popup_controller;
        if (handle->opener_handle) {
            handle->opener_handle->child_popups.push_back(handle);
        }
        [client->pending_popup_controller setBrowserHandle:handle];
        client->pending_popup_controller = nil;
        client->pending_popup_parent_view = nil;
        client->pending_popup_opener_handle = nullptr;
        client->pending_popup_id = 0;
        cmux_chromium_resize_browser(handle);
    }
    browser->base.release(&browser->base);
}

static int CEF_CALLBACK DoClose(cef_life_span_handler_t *self, cef_browser_t *browser) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)((char *)self - offsetof(cmux_chromium_client_t, life_span_handler));
    cmux_chromium_browser_t *handle = client->browser_handle;
    if (handle && handle->browser == browser) {
        handle->is_closing = YES;
    }
    cef_browser_host_t *host = browser->get_host(browser);
    if (host) {
        NSView *browserView = (__bridge NSView *)host->get_window_handle(host);
        [browserView removeFromSuperview];
        host->base.release(&host->base);
    }
    return 1;
}

static cmux_chromium_client_t *CreateClient(void) {
    cmux_chromium_client_t *client = (cmux_chromium_client_t *)calloc(1, sizeof(cmux_chromium_client_t));
    InitBase(&client->client.base, sizeof(cef_client_t));
    InitBase(&client->life_span_handler.base, sizeof(cef_life_span_handler_t));
    InitBase(&client->context_menu_handler.base, sizeof(cef_context_menu_handler_t));
    InitBase(&client->display_handler.base, sizeof(cef_display_handler_t));
    InitBase(&client->load_handler.base, sizeof(cef_load_handler_t));
    InitBase(&client->request_handler.base, sizeof(cef_request_handler_t));
    InitBase(&client->download_handler.base, sizeof(cef_download_handler_t));
    InitBase(&client->permission_handler.base, sizeof(cef_permission_handler_t));
    InitBase(&client->find_handler.base, sizeof(cef_find_handler_t));
    client->client.get_life_span_handler = GetLifeSpanHandler;
    client->client.get_context_menu_handler = GetContextMenuHandler;
    client->client.get_display_handler = GetDisplayHandler;
    client->client.get_load_handler = GetLoadHandler;
    client->client.get_request_handler = GetRequestHandler;
    client->client.get_download_handler = GetDownloadHandler;
    client->client.get_permission_handler = GetPermissionHandler;
    client->client.get_find_handler = GetFindHandler;
    client->life_span_handler.on_after_created = OnAfterCreated;
    client->life_span_handler.do_close = DoClose;
    client->life_span_handler.on_before_popup = OnBeforePopup;
    client->life_span_handler.on_before_popup_aborted = OnBeforePopupAborted;
    client->life_span_handler.on_before_close = OnBeforeClose;
    client->context_menu_handler.on_before_context_menu = OnBeforeContextMenu;
    client->context_menu_handler.on_context_menu_command = OnContextMenuCommand;
    client->display_handler.on_address_change = OnAddressChange;
    client->display_handler.on_title_change = OnTitleChange;
    client->display_handler.on_favicon_urlchange = OnFaviconURLChange;
    client->display_handler.on_fullscreen_mode_change = OnFullscreenModeChange;
    client->display_handler.on_console_message = OnConsoleMessage;
    client->load_handler.on_load_start = OnLoadStart;
    client->load_handler.on_loading_state_change = OnLoadingStateChange;
    client->request_handler.on_open_urlfrom_tab = OnOpenURLFromTab;
    client->download_handler.can_download = CanDownload;
    client->download_handler.on_before_download = OnBeforeDownload;
    client->download_handler.on_download_updated = OnDownloadUpdated;
    client->permission_handler.on_request_media_access_permission = OnRequestMediaAccessPermission;
    client->permission_handler.on_show_permission_prompt = OnShowPermissionPrompt;
    client->permission_handler.on_dismiss_permission_prompt = OnDismissPermissionPrompt;
    client->find_handler.on_find_result = OnFindResult;
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
    settings.remote_debugging_port = CmuxChromiumRemoteDebuggingPortValue();
    SetCefString(&settings.browser_subprocess_path, CmuxChromiumHelperPath());
    SetCefString(&settings.framework_dir_path, CmuxChromiumFrameworkDirectoryPath());
    SetCefString(&settings.main_bundle_path, NSBundle.mainBundle.bundlePath);
    SetCefString(&settings.resources_dir_path, CmuxChromiumResourcesPath());

    NSURL *appSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *cacheURL = [[[appSupport URLByAppendingPathComponent:@"cmux" isDirectory:YES]
        URLByAppendingPathComponent:@"Chromium" isDirectory:YES]
        URLByAppendingPathComponent:CmuxChromiumProfileName() isDirectory:YES];
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
    CmuxScheduleMessageLoopWorkOnMain(0);
    return YES;
}

const char *cmux_chromium_last_error(void) {
    return g_last_error.c_str();
}

int cmux_chromium_remote_debugging_port(void) {
    return CmuxChromiumRemoteDebuggingPortValue();
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

    cmux_chromium_browser_t *handle = CreateBrowserHandle();
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

id cmux_chromium_notification_object(void *browserHandle) {
    return CmuxChromiumNotificationObject((cmux_chromium_browser_t *)browserHandle);
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
    if (!NSEqualRects(browserView.frame, handle->parent_view.bounds)) {
        browserView.frame = handle->parent_view.bounds;
    }
    browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return browserView;
}

void cmux_chromium_resize_browser(void *browserHandle) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->parent_view) return;
    AttachBrowserView(handle);
    if (!handle->browser) return;
    NSRect bounds = handle->parent_view.bounds;
    if (handle->has_sent_bounds && NSEqualRects(handle->last_sent_bounds, bounds)) {
        return;
    }
    handle->last_sent_bounds = bounds;
    handle->has_sent_bounds = YES;
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

void cmux_chromium_dispose_browser(void *browserHandle) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle) return;

    if (!handle->browser) {
        DeleteBrowserHandle(handle);
        return;
    }

    handle->dispose_when_closed = YES;
    cmux_chromium_close_browser(handle);
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

void cmux_chromium_refresh_navigation_entries(void *browserHandle) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->browser || !handle->client) return;
    CmuxChromiumRefreshNavigationEntries(handle->client, handle->browser);
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

void cmux_chromium_set_zoom_level(void *browserHandle, double zoomLevel) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->browser) return;
    cef_browser_host_t *host = handle->browser->get_host(handle->browser);
    if (!host) return;
    host->set_zoom_level(host, zoomLevel);
    host->base.release(&host->base);
}

void cmux_chromium_find(void *browserHandle, const char *searchText, BOOL forward, BOOL findNext) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->browser) return;
    cef_browser_host_t *host = handle->browser->get_host(handle->browser);
    if (!host) return;
    cef_string_t cef_search_text = {};
    cef_string_from_utf8(searchText ?: "", strlen(searchText ?: ""), &cef_search_text);
    host->find(host, &cef_search_text, forward ? 1 : 0, 0, findNext ? 1 : 0);
    cef_string_clear(&cef_search_text);
    host->base.release(&host->base);
}

void cmux_chromium_stop_finding(void *browserHandle, BOOL clearSelection) {
    cmux_chromium_browser_t *handle = (cmux_chromium_browser_t *)browserHandle;
    if (!handle || !handle->browser) return;
    cef_browser_host_t *host = handle->browser->get_host(handle->browser);
    if (!host) return;
    host->stop_finding(host, clearSelection ? 1 : 0);
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
