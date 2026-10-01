// Private CoreGraphics ABI, as documented by Chromium's virtual_display_util_mac.mm.
// Copyright 2022 The Chromium Authors, BSD-3-Clause. See res/licenses/Chromium-BSD.txt.
// NikoDesk checks the ABI at runtime and retains only the displays it creates.
#include "macos_virtual_display.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface NikoCGDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID, productID, serialNum;
@property(strong, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong, nonatomic) id queue;
@end
@interface NikoCGDisplayMode : NSObject
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface NikoCGDisplaySettings : NSObject
@property(strong, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface NikoCGDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

static bool hasSelectors(Class klass, NSArray<NSString *> *selectors) {
    if (!klass) return false;
    for (NSString *selector in selectors) {
        if (![klass instancesRespondToSelector:NSSelectorFromString(selector)]) return false;
    }
    return true;
}
bool NikoMacVirtualDisplaySupported(void) {
    @autoreleasepool {
        return hasSelectors(NSClassFromString(@"CGVirtualDisplay"),
                   @[@"initWithDescriptor:", @"applySettings:", @"displayID"])
            && hasSelectors(NSClassFromString(@"CGVirtualDisplayDescriptor"),
                   @[@"setVendorID:", @"setProductID:", @"setSerialNum:", @"setName:",
                     @"setSizeInMillimeters:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
                     @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:", @"setQueue:"])
            && hasSelectors(NSClassFromString(@"CGVirtualDisplayMode"), @[@"initWithWidth:height:refreshRate:"])
            && hasSelectors(NSClassFromString(@"CGVirtualDisplaySettings"), @[@"setModes:", @"setHiDPI:"]);
    }
}
void *NikoMacVirtualDisplayCreate(uint32_t slot, uint32_t *displayID, uint32_t *serial, bool *applied) {
    if (!displayID || !serial || !applied || slot < 1 || slot > 4) return nullptr;
    *displayID = 0;
    *serial = 0;
    *applied = false;
    @autoreleasepool {
        @try {
            if (!NikoMacVirtualDisplaySupported()) return nullptr;
            uint32_t number = 0;
            while (number == 0) arc4random_buf(&number, sizeof(number));
            NikoCGDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
            descriptor.vendorID = 0x4e49;
            descriptor.productID = slot;
            descriptor.serialNum = number;
            if ([descriptor respondsToSelector:NSSelectorFromString(@"setSerialNumber:")])
                [descriptor setValue:@(number) forKey:@"serialNumber"];
            descriptor.name = [NSString stringWithFormat:@"NikoDesk Virtual Display %u", slot];
            descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
            descriptor.maxPixelsWide = 3840;
            descriptor.maxPixelsHigh = 2160;
            descriptor.sizeInMillimeters = CGSizeMake(600, 338);
            descriptor.redPrimary = CGPointMake(0.64, 0.33);
            descriptor.greenPrimary = CGPointMake(0.30, 0.60);
            descriptor.bluePrimary = CGPointMake(0.15, 0.06);
            descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
            NikoCGDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
            if (!display) return nullptr;
            NikoCGDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
            settings.hiDPI = 0;
            NSMutableArray *modes = [NSMutableArray array];
            const unsigned int dimensions[][2] = {{1920,1080}, {2560,1440}, {3840,2160}};
            for (const auto& size : dimensions) {
                id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                    initWithWidth:size[0] height:size[1] refreshRate:60];
                if (!mode) return nullptr;
                [modes addObject:mode];
            }
            settings.modes = modes;
            // Even on failure retain the object so the caller can explicitly
            // release and verify removal, rather than lose a created screen.
            *applied = [display applySettings:settings];
            *displayID = display.displayID;
            *serial = number;
            return (void *)CFBridgingRetain(display);
        } @catch (NSException *) {
            return nullptr;
        }
    }
}
bool NikoMacVirtualDisplayOnline(uint32_t displayID, uint32_t serial) {
    return displayID != 0 && serial != 0 && CGDisplayIsOnline(displayID)
        && CGDisplayVendorNumber(displayID) == 0x4e49 && CGDisplaySerialNumber(displayID) == serial;
}
void NikoMacVirtualDisplayRelease(void *display) {
    if (!display) return;
    @autoreleasepool { CFRelease(display); }
}
