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
    BOOL _adaptive;
}
- (instancetype)initForSharing {
    return [self initWithWidth:1600 height:900 name:@"Lid Desktop" vendor:0x4c44 serial:1];
}
- (instancetype)initForAdaptiveDesktopWithWidth:(unsigned)width height:(unsigned)height {
    // A pending orientation change and the currently shared display may coexist.
    static unsigned serial = 0;
    self = [self initWithWidth:width height:height name:@"iPhone Desktop" vendor:0x4150 serial:++serial];
    if (self) _adaptive = YES;
    return self;
}
- (instancetype)initWithWidth:(unsigned)width height:(unsigned)height name:(NSString *)name
                       vendor:(unsigned)vendor serial:(unsigned)serial {
    self = [super init];
    if (!self) return nil;
    @try {
        id descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
        id settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
        if (!descriptor || !settings) return nil;
        [descriptor setValue:name forKey:@"name"];
        [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];
        [descriptor setValue:@(vendor) forKey:@"vendorID"];
        [descriptor setValue:@1 forKey:@"productID"];
        [descriptor setValue:@(serial) forKey:@"serialNum"];
        [descriptor setValue:@(vendor == 0x4150 ? 1920 : width) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(vendor == 0x4150 ? 1920 : height) forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(300.0 * width / MAX(width, height), 300.0 * height / MAX(width, height))] forKey:@"sizeInMillimeters"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3127,0.3290)] forKey:@"whitePoint"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.640,0.330)] forKey:@"redPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.300,0.600)] forKey:@"greenPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.150,0.060)] forKey:@"bluePrimary"];
        id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:60];
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
- (BOOL)resizeToWidth:(unsigned)width height:(unsigned)height {
    if (!_adaptive || !_displayID || width < 320 || height < 320 || width > 1920 || height > 1920) return NO;
    if (CGDisplayPixelsWide(_displayID) == width && CGDisplayPixelsHigh(_displayID) == height) return YES;
    @try {
        id settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
        id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:60];
        if (!settings || !mode) return NO;
        [settings setValue:@[mode] forKey:@"modes"];
        if (![_display applySettings:settings]) return NO;
        if (CGDisplayPixelsWide(_displayID) == width && CGDisplayPixelsHigh(_displayID) == height) return YES;
        NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(_displayID, NULL));
        for (id item in modes) {
            CGDisplayModeRef option = (__bridge CGDisplayModeRef)item;
            if (CGDisplayModeGetWidth(option) == width && CGDisplayModeGetHeight(option) == height) {
                return CGDisplaySetDisplayMode(_displayID, option, NULL) == kCGErrorSuccess;
            }
        }
        return NO;
    } @catch (NSException *exception) {
        NSLog(@"Could not resize the iPhone desktop: %@", exception.reason);
        return NO;
    }
}
@end
