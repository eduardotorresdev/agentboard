// Loaded into Playwright's WebKit process (DYLD_INSERT_LIBRARIES). Playwright keeps each page in
// an off-screen window; this reports which Core Animation context draws each page, so the board
// can show the page's layers as they are, at the display's rate, without copying pixels.
//
// A page is recognized by the marker its first URL carries (`about:blank#agentboard=<id>`). Each
// report is a JSON line appended to the file named by AGENTBOARD_EVENTS.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static NSMapTable<WKWebView *, NSString *> *pageIDs;
static NSMutableDictionary<NSString *, NSString *> *lastReports;
static NSString *const marker = @"#agentboard=";

static void collectWebViews(NSView *view, NSMutableArray<WKWebView *> *found) {
    if ([view isKindOfClass:[WKWebView class]]) {
        [found addObject:(WKWebView *)view];
        return;
    }
    for (NSView *child in view.subviews) collectWebViews(child, found);
}

static void appendReport(NSString *line) {
    NSString *path = NSProcessInfo.processInfo.environment[@"AGENTBOARD_EVENTS"];
    if (!path) return;
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static void scanWindows(void) {
    for (NSWindow *window in NSApp.windows) {
        if (!window.contentView) continue;
        NSMutableArray<WKWebView *> *webViews = [NSMutableArray new];
        collectWebViews(window.contentView, webViews);
        for (WKWebView *webView in webViews) {
            NSString *page = [pageIDs objectForKey:webView];
            if (!page) {
                NSString *url = webView.URL.absoluteString.stringByRemovingPercentEncoding ?: @"";
                NSRange found = [url rangeOfString:marker];
                if (found.location == NSNotFound) continue;
                page = [url substringFromIndex:NSMaxRange(found)];
                [pageIDs setObject:page forKey:webView];
            }
            id context = [webView.layer valueForKey:@"context"];
            unsigned contextID = context ? [[context valueForKey:@"contextId"] unsignedIntValue] : 0;
            if (!contextID) continue;
            NSSize size = webView.bounds.size;
            NSString *line = [NSString stringWithFormat:@"{\"page\":\"%@\",\"contextID\":%u,\"width\":%g,\"height\":%g}",
                                                        page, contextID, size.width, size.height];
            if ([lastReports[page] isEqualToString:line]) continue;
            lastReports[page] = line;
            appendReport(line);
        }
    }
}

__attribute__((constructor)) static void startScanning(void) {
    pageIDs = [NSMapTable weakToStrongObjectsMapTable];
    lastReports = [NSMutableDictionary new];
    dispatch_async(dispatch_get_main_queue(), ^{
        // Cheap (a handful of windows), and it also catches resizes from viewport changes.
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { scanWindows(); }];
    });
}
