#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
/// Owns exactly one temporary display. Releasing the owner removes that display.
@interface IPDVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
+ (BOOL)isSupported;
- (BOOL)positionToRightWithError:(NSError **)error;
- (nullable instancetype)initWithWidth:(unsigned int)width
                               height:(unsigned int)height
                          refreshRate:(double)refreshRate
                               retina:(BOOL)retina
                               serial:(unsigned int)serial
                                error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
