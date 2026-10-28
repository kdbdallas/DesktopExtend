#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A defensive wrapper around CoreGraphics' private virtual-display classes
/// (CGVirtualDisplay & friends).
///
/// Every private class is resolved at runtime via `objc_getClass`, so if a
/// future macOS build removes or renames them this reports `supported == NO`
/// instead of failing to launch.
@interface DEVirtualDisplay : NSObject

/// NO when the private CoreGraphics classes are missing on this OS build.
@property (class, readonly, getter=isSupported) BOOL supported;

/// Creates a display measuring `pointSize` points, backed at `scale`x.
///
/// The private API is particular here: the mode is expressed in *points*, and
/// the descriptor's max pixel dimensions must be exactly `scale` times the
/// mode. Getting that pairing wrong silently yields a 1x display.
- (nullable instancetype)initWithName:(NSString *)name
                            pointSize:(CGSize)pointSize
                                scale:(NSUInteger)scale;

/// The display ID the WindowServer assigned, or `kCGNullDirectDisplay`.
@property (readonly) CGDirectDisplayID displayID;
@property (readonly) CGSize pointSize;
@property (readonly) NSUInteger scale;

@end

NS_ASSUME_NONNULL_END
