// Shows another process's layer (by CAContext id) in a window, at display rate.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
@interface CALayerHost : CALayer
@property uint32_t contextId;
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        uint32_t contextId = (uint32_t)atoll(argv[1]);
        double scale = argc > 2 ? atof(argv[2]) : 0.5;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 1280 * scale + 40, 720 * scale + 40)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        window.title = @"layer host spike";
        NSView *view = window.contentView;
        view.wantsLayer = YES;
        view.layer.backgroundColor = NSColor.systemGrayColor.CGColor;
        CALayer *card = [CALayer layer];
        card.frame = CGRectMake(20, 20, 1280 * scale, 720 * scale);
        card.masksToBounds = YES;
        card.cornerRadius = 14;
        card.backgroundColor = NSColor.whiteColor.CGColor;
        CALayerHost *host = [CALayerHost layer];
        host.contextId = contextId;
        host.anchorPoint = CGPointZero;
        host.transform = CATransform3DMakeScale(scale, scale, 1); // board zoom: a transform, no re-render
        [card addSublayer:host];
        [view.layer addSublayer:card];
        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        printf("%d\n", (int)window.windowNumber); fflush(stdout);
        [app run];
    }
    return 0;
}
