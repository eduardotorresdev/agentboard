// Minimal Playwright-compatible WebKit embedder (headless path only), derived from Playwright's
// mac embedder. Each page's layer is exported through a CAContext so another process can host it.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <WebKit/_WKBrowserInspector.h>
#import <WebKit/WKWebsiteDataStorePrivate.h>
#import <WebKit/_WKWebsiteDataStoreConfiguration.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/WKWebViewConfigurationPrivate.h>
#import <WebKit/WKPreferencesPrivate.h>
#import <WebKit/WKProcessPoolPrivate.h>
#import <WebKit/_WKProcessPoolConfiguration.h>

@interface CAContext : NSObject
+ (instancetype)contextWithCGSConnection:(uint32_t)connection options:(NSDictionary *)options;
@property (readonly) uint32_t contextId;
@property (retain) CALayer *layer;
@end
extern uint32_t CGSMainConnectionID(void);
@interface WKWebsiteDataStore (Session)
- (uint64_t)sessionID;
@end

@interface Embedder : NSObject <NSApplicationDelegate, _WKBrowserInspectorDelegate, WKUIDelegate>
@end

@implementation Embedder {
    NSMutableSet *_contexts;
    NSMutableArray *_keep;
    WKWebViewConfiguration *_default;
    int _pages;
}

- (instancetype)init {
    self = [super init];
    _contexts = [NSMutableSet new];
    _keep = [NSMutableArray new];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    return self;
}

- (WKWebViewConfiguration *)defaultConfiguration {
    if (!_default) {
        _default = [WKWebViewConfiguration new];
        _WKWebsiteDataStoreConfiguration *c = [[_WKWebsiteDataStoreConfiguration alloc] initNonPersistentConfiguration];
        _default.websiteDataStore = [[WKWebsiteDataStore alloc] _initWithConfiguration:c];
        _default._controlledByAutomation = true;
        _default.preferences._hiddenPageDOMTimerThrottlingEnabled = NO;
        _default.preferences._pageVisibilityBasedProcessSuppressionEnabled = NO;
        _default.preferences._domTimersThrottlingEnabled = NO;
    }
    return _default;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [_WKBrowserInspector initializeRemoteInspectorPipe:self headless:YES];
}

- (WKWebView *)createNewPage:(uint64_t)sessionID {
    NSLog(@"AB createNewPage %llu", sessionID);
    WKWebViewConfiguration *configuration = [[self defaultConfiguration] copy];
    NSLog(@"AB copied config");
    for (_WKBrowserContext *context in _contexts) {
        if ([[context dataStore] sessionID] != sessionID) continue;
        configuration.websiteDataStore = context.dataStore;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        configuration.processPool = context.processPool;
#pragma clang diagnostic pop
    }
    NSLog(@"AB contexts matched");
    NSRect rect = NSMakeRect(0, 0, 1280, 720);
    NSScreen *screen = NSScreen.screens.firstObject;
    NSRect frame = screen ? NSOffsetRect(rect, -10000, screen.frame.size.height - rect.size.height + 10000) : rect;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
    window.collectionBehavior = NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
    WKWebView *webView = [[WKWebView alloc] initWithFrame:window.contentView.bounds configuration:configuration];
    webView._windowOcclusionDetectionEnabled = NO;
    webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    webView.UIDelegate = self;
    [window.contentView addSubview:webView];
    [window setIsVisible:YES];
    [_keep addObject:window];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];

    NSLog(@"AB window ready");
    // Export the page: the offscreen window already renders into its own CAContext; report that
    // context so another process can host the window's layer tree as is.
    window.contentView.wantsLayer = YES;
    int page = _pages++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CAContext *context = [window.contentView.layer valueForKey:@"context"];
        NSString *file = NSProcessInfo.processInfo.environment[@"AB_CONTEXT_FILE"];
        NSLog(@"AB page %d window context %u", page, context.contextId);
        if (file) {
            NSString *line = [NSString stringWithFormat:@"%d %u\n", page, context.contextId];
            if (![[NSFileManager defaultManager] fileExistsAtPath:file]) [[NSFileManager defaultManager] createFileAtPath:file contents:nil attributes:nil];
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:file];
            [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
        }
    });
    return webView;
}

- (_WKBrowserContext *)createBrowserContext:(NSString *)proxyServer WithBypassList:(NSString *)bypass {
    _WKBrowserContext *context = [_WKBrowserContext new];
    _WKWebsiteDataStoreConfiguration *c = [[_WKWebsiteDataStoreConfiguration alloc] initNonPersistentConfiguration];
    context.dataStore = [[WKWebsiteDataStore alloc] _initWithConfiguration:c];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    context.processPool = [[WKProcessPool alloc] _initWithConfiguration:[_WKProcessPoolConfiguration new]];
#pragma clang diagnostic pop
    [_contexts addObject:context];
    // WebKit adopts the returned context (+1), as Playwright's embedder returns it unreleased.
    return (__bridge _WKBrowserContext *)CFBridgingRetain(context);
}

- (void)deleteBrowserContext:(uint64_t)sessionID {
    for (_WKBrowserContext *context in [_contexts copy])
        if ([[context dataStore] sessionID] == sessionID) [_contexts removeObject:context];
}

- (void)quit { [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0]; }

- (void)webViewDidClose:(WKWebView *)webView { [webView.window close]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"WebKitLinkedOnOrAfterEverything"];
        NSApplication *app = [NSApplication sharedApplication];
        Embedder *delegate = [Embedder new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
