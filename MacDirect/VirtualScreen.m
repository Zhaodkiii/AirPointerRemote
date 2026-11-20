#import <AppKit/AppKit.h>

#import "VirtualScreen.h"

// Runtime interfaces on Apple Silicon macOS. Resolve by name so unavailable
// implementations produce a setup error instead of a load-time crash.
@interface NSObject (VirtualScreenRuntime)
- (instancetype)initWithDescriptor:(id)descriptor;
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height refreshRate:(double)rate;
- (BOOL)applySettings:(id)settings;
- (unsigned)displayID;
@end

@implementation VirtualScreen {
    id _display;
}
- (instancetype)initForSharing {
    self = [super init];
    if (!self) return nil;
    @try {
        id descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
        id settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
        if (!descriptor || !settings) return nil;
        [descriptor setValue:@"Lid Desktop" forKey:@"name"];
        [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
        [descriptor setValue:@0x4c44 forKey:@"vendorID"];
        [descriptor setValue:@1 forKey:@"productID"];
        [descriptor setValue:@1 forKey:@"serialNum"];
        [descriptor setValue:@1600 forKey:@"maxPixelsWide"];
        [descriptor setValue:@900 forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(300,169)] forKey:@"sizeInMillimeters"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3127,0.3290)] forKey:@"whitePoint"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.640,0.330)] forKey:@"redPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.300,0.600)] forKey:@"greenPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.150,0.060)] forKey:@"bluePrimary"];
        id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1600 height:900 refreshRate:60];
        if (!mode) return nil;
        [settings setValue:@[mode] forKey:@"modes"];
        _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (![_display applySettings:settings] || ![_display displayID]) return nil;
        _displayID = [_display displayID];
    } @catch (NSException *exception) {
        NSLog(@"Virtual display unavailable: %@", exception.reason);
        return nil;
    }
    return self;
}
@end
