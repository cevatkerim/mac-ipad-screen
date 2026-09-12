#import "VirtualDisplay.h"

// Undocumented CoreGraphics interfaces; keep all runtime assumptions in this file.
// Signatures cross-checked against Chromium's ui/display/mac/test implementation.
@interface NSObject (IPDVirtualDisplayAPI)
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray *modes;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (id)initWithDescriptor:(id)descriptor;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
- (BOOL)applySettings:(id)settings;
@end

@implementation IPDVirtualDisplay {
    id _display;
}
+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor") &&
        NSClassFromString(@"CGVirtualDisplaySettings") && NSClassFromString(@"CGVirtualDisplayMode");
}
- (CGDirectDisplayID)displayID { return [_display displayID]; }
- (BOOL)positionToRightWithError:(NSError **)error {
    uint32_t count = 0;
    CGDirectDisplayID displays[64];
    CGError result = CGGetActiveDisplayList(64, displays, &count);
    double right = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (displays[i] != self.displayID) right = MAX(right, CGRectGetMaxX(CGDisplayBounds(displays[i])));
    }
    CGDisplayConfigRef config = NULL;
    if (result == kCGErrorSuccess) result = CGBeginDisplayConfiguration(&config);
    if (result == kCGErrorSuccess) {
        result = CGConfigureDisplayOrigin(config, self.displayID, (int32_t)right, 0);
        if (result == kCGErrorSuccess) result = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        else CGCancelDisplayConfiguration(config);
    }
    if (result != kCGErrorSuccess && error) *error = [NSError errorWithDomain:@"IPadScreen.VirtualDisplay" code:result
        userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"macOS could not position the iPad beside your desktop (CoreGraphics %d).", result]}];
    return result == kCGErrorSuccess;
}
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height
                  refreshRate:(double)refreshRate retina:(BOOL)retina
                       serial:(unsigned int)serial error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSString *failure = nil;
    @try {
        if (![IPDVirtualDisplay isSupported]) {
            failure = @"This macOS version does not provide the virtual display backend. Mirroring is available.";
        } else {
            uint32_t count = 0;
            CGDirectDisplayID displays[64];
            CGError listed = CGGetActiveDisplayList(64, displays, &count);
            if (listed != kCGErrorSuccess || count == 0) {
                failure = @"No active Mac desktop was found.";
            } else {
                id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
                [descriptor setName:@"iPad Screen"];
                [descriptor setQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)];
                [descriptor setMaxPixelsWide:width];
                [descriptor setMaxPixelsHigh:height];
                [descriptor setSizeInMillimeters:CGSizeMake(width * 25.4 / 264, height * 25.4 / 264)];
                [descriptor setVendorID:0x4950];
                [descriptor setProductID:1];
                [descriptor setSerialNum:serial ?: 1];
                [descriptor setRedPrimary:CGPointMake(0.64, 0.33)];
                [descriptor setGreenPrimary:CGPointMake(0.30, 0.60)];
                [descriptor setBluePrimary:CGPointMake(0.15, 0.06)];
                [descriptor setWhitePoint:CGPointMake(0.3127, 0.3290)];
                _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
                id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
                [settings setHiDPI:retina ? 1 : 0];
                id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                    initWithWidth:retina ? width / 2 : width height:retina ? height / 2 : height
                    refreshRate:refreshRate];
                if (!_display || !mode) {
                    failure = @"macOS could not create the iPad display.";
                } else {
                    [settings setModes:@[mode]];
                    if (![_display applySettings:settings]) {
                        failure = @"macOS rejected the iPad display mode.";
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        failure = @"The virtual display interface is incompatible with this macOS version. Mirroring is available.";
    }
    if (failure) {
        _display = nil;
        if (error) *error = [NSError errorWithDomain:@"IPadScreen.VirtualDisplay" code:1
            userInfo:@{NSLocalizedDescriptionKey:failure}];
        return nil;
    }
    return self;
}
@end
