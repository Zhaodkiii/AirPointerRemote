#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
@interface VirtualScreen : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initForSharing;
- (nullable instancetype)initForAdaptiveDesktopWithWidth:(unsigned)width height:(unsigned)height
    NS_SWIFT_NAME(init(adaptiveWidth:height:));
- (BOOL)resizeToWidth:(unsigned)width height:(unsigned)height NS_SWIFT_NAME(resize(width:height:));
@end
NS_ASSUME_NONNULL_END
