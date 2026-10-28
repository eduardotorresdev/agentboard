#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
@interface CAContext : NSObject
+ (instancetype)contextWithCGSConnection:(uint32_t)connection options:(NSDictionary *)options;
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
@property (readonly) uint32_t contextId;
@property (retain) CALayer *layer;
@end
extern uint32_t CGSMainConnectionID(void);
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        CAContext *context = argc > 1 && !strcmp(argv[1], "remote")
            ? [CAContext remoteContextWithOptions:@{}]
            : [CAContext contextWithCGSConnection:CGSMainConnectionID() options:@{@"kCAContextCIFilterBehavior": @"ignore"}];
        CALayer *layer = [CALayer layer];
        layer.frame = CGRectMake(0, 0, 400, 300);
        layer.backgroundColor = CGColorCreateSRGB(0.97, 0.42, 0.08, 1);
        CALayer *dot = [CALayer layer]; dot.frame = CGRectMake(40, 40, 80, 80); dot.cornerRadius = 40;
        dot.backgroundColor = CGColorCreateSRGB(0.43, 0.34, 0.81, 1); [layer addSublayer:dot];
        context.layer = layer;
        [CATransaction flush];
        printf("%u\n", context.contextId); fflush(stdout);
        // Animate so we can see liveness.
        [NSTimer scheduledTimerWithTimeInterval:1/60.0 repeats:YES block:^(NSTimer *t) {
            static double p = 0; p += 0.05;
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            dot.position = CGPointMake(200 + 140 * cos(p), 150 + 90 * sin(p));
            [CATransaction commit];
        }];
        [NSApp run];
    }
}
