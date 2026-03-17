//
//  CGVirtualDisplay-Bridge.h
//  UltraXReal
//
//  Bridging header for Apple's private CGVirtualDisplay API.
//  Reverse-engineered from macOS_headers and validated against
//  FluffyDisplay, Lumen, and Chromium implementations.
//

#ifndef CGVirtualDisplay_Bridge_h
#define CGVirtualDisplay_Bridge_h

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// MARK: - CGVirtualDisplayMode

@interface CGVirtualDisplayMode : NSObject

@property (readonly) unsigned int widthInPixels;
@property (readonly) unsigned int heightInPixels;
@property (readonly) double refreshRate;

- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;

@end

// MARK: - CGVirtualDisplayDescriptor

@interface CGVirtualDisplayDescriptor : NSObject

@property (assign) unsigned int vendorID;
@property (assign) unsigned int productID;
@property (assign) unsigned int serialNum;
@property (copy) NSString *name;
@property (assign) CGSize sizeInMillimeters;
@property (assign) unsigned int maxPixelsWide;
@property (assign) unsigned int maxPixelsHigh;
@property (copy) dispatch_queue_t queue;

@end

// MARK: - CGVirtualDisplaySettings

@interface CGVirtualDisplaySettings : NSObject

@property (copy) NSArray<CGVirtualDisplayMode *> *modes;

@end

// MARK: - CGVirtualDisplay

@interface CGVirtualDisplay : NSObject

@property (readonly) CGDirectDisplayID displayID;

- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;

@end

// MARK: - XReal IMU Driver (USB HID)

#include "Vendor/hidapi/hidapi.h"
#include "Vendor/xreal-imu/device.h"
#include "Vendor/xreal-imu/device_imu.h"
#include "Vendor/xreal-imu/hid_ids.h"

#endif /* CGVirtualDisplay_Bridge_h */
