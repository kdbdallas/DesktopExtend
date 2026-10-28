#import "include/CVirtualDisplay.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

static os_log_t DELog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.port21.DesktopExtend", "virtualdisplay"); });
    return log;
}

#pragma mark - Private CoreGraphics interfaces
//
// These are redeclarations of private CoreGraphics classes. They are never
// referenced as link-time symbols; instances come from `objc_getClass` so a
// missing class degrades to nil rather than a launch failure.

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic, assign) uint32_t hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, assign) uint32_t serialNum;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) uint32_t maxPixelsWide;
@property (nonatomic, assign) uint32_t maxPixelsHigh;
@property (nonatomic, assign) CGPoint redPrimary;
@property (nonatomic, assign) CGPoint greenPrimary;
@property (nonatomic, assign) CGPoint bluePrimary;
@property (nonatomic, assign) CGPoint whitePoint;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) CGDirectDisplayID displayID;
@end

#pragma mark -

@implementation DEVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (BOOL)isSupported {
    return objc_getClass("CGVirtualDisplay") != NULL
        && objc_getClass("CGVirtualDisplayDescriptor") != NULL
        && objc_getClass("CGVirtualDisplaySettings") != NULL
        && objc_getClass("CGVirtualDisplayMode") != NULL;
}

- (nullable instancetype)initWithName:(NSString *)name
                            pointSize:(CGSize)pointSize
                                scale:(NSUInteger)scale {
    self = [super init];
    if (!self) return nil;
    if (!DEVirtualDisplay.supported) {
        os_log_error(DELog(), "private CGVirtualDisplay classes are unavailable");
        return nil;
    }
    if (pointSize.width < 1 || pointSize.height < 1 || scale < 1) {
        os_log_error(DELog(), "invalid geometry %{public}.0fx%{public}.0f @%lux",
                     pointSize.width, pointSize.height, (unsigned long)scale);
        return nil;
    }

    _pointSize = pointSize;
    _scale = scale;

    uint32_t modeW = (uint32_t)lround(pointSize.width);
    uint32_t modeH = (uint32_t)lround(pointSize.height);
    uint32_t pixelsW = modeW * (uint32_t)scale;
    uint32_t pixelsH = modeH * (uint32_t)scale;

    CGVirtualDisplayDescriptor *descriptor =
        [[objc_getClass("CGVirtualDisplayDescriptor") alloc] init];
    if (!descriptor) {
        os_log_error(DELog(), "could not allocate CGVirtualDisplayDescriptor");
        return nil;
    }

    descriptor.name = name;
    descriptor.vendorID = 0x444E;   // "DE"
    descriptor.productID = 0x0001;
    descriptor.serialNum = 0x0001;
    descriptor.maxPixelsWide = pixelsW;
    descriptor.maxPixelsHigh = pixelsH;

    // Claim a physically small panel so the WindowServer treats the high pixel
    // count as Retina density rather than synthesising 1x scaled modes.
    descriptor.sizeInMillimeters = CGSizeMake(pointSize.width / 4.35,
                                              pointSize.height / 4.35);

    // sRGB / Rec.709 primaries and a D65 white point.
    descriptor.redPrimary   = CGPointMake(0.6400, 0.3300);
    descriptor.greenPrimary = CGPointMake(0.3000, 0.6000);
    descriptor.bluePrimary  = CGPointMake(0.1500, 0.0600);
    descriptor.whitePoint   = CGPointMake(0.3127, 0.3290);

    descriptor.queue = dispatch_get_main_queue();
    descriptor.terminationHandler = ^(id a, id b) {};

    os_log_info(DELog(), "creating virtual display %{public}@: mode %ux%u pts, max %ux%u px",
                name, modeW, modeH, pixelsW, pixelsH);

    _display = [[objc_getClass("CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display) {
        os_log_error(DELog(), "initWithDescriptor: returned nil");
        return nil;
    }

    CGVirtualDisplaySettings *settings =
        [[objc_getClass("CGVirtualDisplaySettings") alloc] init];
    if (!settings) return nil;

    CGVirtualDisplayMode *mode = [[objc_getClass("CGVirtualDisplayMode") alloc]
                                  initWithWidth:modeW height:modeH refreshRate:60.0];
    if (!mode) return nil;

    settings.modes = @[mode];
    settings.hiDPI = (scale > 1) ? 1 : 0;

    if (![_display applySettings:settings]) {
        os_log_error(DELog(), "applySettings: failed");
        _display = nil;
        return nil;
    }
    os_log_info(DELog(), "virtual display registered as id %u", _display.displayID);
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? _display.displayID : kCGNullDirectDisplay;
}

- (void)dealloc {
    // Releasing the CGVirtualDisplay tears the display down in the WindowServer.
    _display = nil;
}

@end
