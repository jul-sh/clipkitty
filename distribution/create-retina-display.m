// Creates a virtual Retina (HiDPI) display for CI screenshot capture.
// Compile: clang -framework CoreGraphics -framework Foundation -o create-retina-display create-retina-display.m
// Run as background process — the virtual display disappears when the process exits.
// Writes the display ID to /tmp/retina-display-id on success.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

static void printDisplays(const char *label) {
    uint32_t maxDisplays = 16;
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(maxDisplays, displays, &count);
    printf("%s: %u display(s)\n", label, count);
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID did = displays[i];
        CGRect bounds = CGDisplayBounds(did);
        printf("  Display %u: %zux%zu px, bounds=(%.0f,%.0f %.0fx%.0f)%s\n",
               did, CGDisplayPixelsWide(did), CGDisplayPixelsHigh(did),
               bounds.origin.x, bounds.origin.y,
               bounds.size.width, bounds.size.height,
               CGDisplayIsMain(did) ? " [MAIN]" : "");
    }
}

static bool selectHiDPIMode(CGDirectDisplayID displayID) {
    NSDictionary *opts = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(displayID, (__bridge CFDictionaryRef)opts);
    if (!modes) return false;

    CGDisplayModeRef bestMode = NULL;
    size_t bestPixels = 0;
    CFIndex n = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < n; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t pw = CGDisplayModeGetPixelWidth(mode);
        size_t lw = CGDisplayModeGetWidth(mode);
        if (pw > lw && pw > bestPixels) {
            bestMode = mode;
            bestPixels = pw;
        }
    }

    bool success = false;
    if (bestMode) {
        printf("  Selecting HiDPI mode: %zux%zu logical, %zux%zu pixels\n",
               CGDisplayModeGetWidth(bestMode), CGDisplayModeGetHeight(bestMode),
               CGDisplayModeGetPixelWidth(bestMode), CGDisplayModeGetPixelHeight(bestMode));
        success = (CGDisplaySetDisplayMode(displayID, bestMode, NULL) == kCGErrorSuccess);
        printf("  Result: %s\n", success ? "OK" : "FAILED");
    }
    CFRelease(modes);
    return success;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printDisplays("Before");

        // Remember the existing display so we can move it aside
        CGDirectDisplayID existingDisplay = CGMainDisplayID();

        // --- Create descriptor ---
        Class descClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        id desc = [[descClass alloc] init];
        [desc setValue:dispatch_get_main_queue() forKey:@"queue"];
        [desc setValue:@"CI Retina Display" forKey:@"name"];
        [desc setValue:@(3360U) forKey:@"maxPixelsWide"];
        [desc setValue:@(2100U) forKey:@"maxPixelsHigh"];
        [desc setValue:[NSValue valueWithSize:NSMakeSize(300.0, 188.0)] forKey:@"sizeInMillimeters"];
        [desc setValue:@(0xCC01U) forKey:@"productID"];
        [desc setValue:@(0xCC02U) forKey:@"vendorID"];
        [desc setValue:@(0U) forKey:@"serialNum"];

        // --- Create display ---
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        id display = [[displayClass alloc] performSelector:NSSelectorFromString(@"initWithDescriptor:") withObject:desc];
        if (!display) {
            fprintf(stderr, "ERROR: Failed to create virtual display\n");
            return 1;
        }

        // --- Configure modes (both 1x and 2x) ---
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        SEL initSel = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
        NSMethodSignature *modeSig = [modeClass instanceMethodSignatureForSelector:initSel];

        // 2x mode: 1680x1050 logical → 3360x2100 pixels
        NSInvocation *inv1 = [NSInvocation invocationWithMethodSignature:modeSig];
        [inv1 setSelector:initSel];
        uint32_t w1 = 1680, h1 = 1050; double r = 60.0;
        [inv1 setArgument:&w1 atIndex:2]; [inv1 setArgument:&h1 atIndex:3]; [inv1 setArgument:&r atIndex:4];
        id mode1 = [[modeClass alloc] init];
        [inv1 invokeWithTarget:mode1];
        __unsafe_unretained id m1r; [inv1 getReturnValue:&m1r]; mode1 = m1r;

        // 1x mode: 3360x2100 logical → 3360x2100 pixels
        NSInvocation *inv2 = [NSInvocation invocationWithMethodSignature:modeSig];
        [inv2 setSelector:initSel];
        uint32_t w2 = 3360, h2 = 2100;
        [inv2 setArgument:&w2 atIndex:2]; [inv2 setArgument:&h2 atIndex:3]; [inv2 setArgument:&r atIndex:4];
        id mode2 = [[modeClass alloc] init];
        [inv2 invokeWithTarget:mode2];
        __unsafe_unretained id m2r; [inv2 getReturnValue:&m2r]; mode2 = m2r;

        // Apply settings
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        id settings = [[settingsClass alloc] init];
        [settings setValue:@[mode1, mode2] forKey:@"modes"];
        [settings setValue:@(1U) forKey:@"hiDPI"];
        [display performSelector:NSSelectorFromString(@"applySettings:") withObject:settings];

        CGDirectDisplayID displayID = [[display valueForKey:@"displayID"] unsignedIntValue];
        printf("Virtual display created (ID: %u)\n", displayID);

        // Select HiDPI mode
        selectHiDPIMode(displayID);

        // --- Make virtual display primary by moving existing display out of the way ---
        CGDisplayConfigRef config;
        CGError err = CGBeginDisplayConfiguration(&config);
        if (err == kCGErrorSuccess) {
            // Put virtual display at origin (primary position)
            CGConfigureDisplayOrigin(config, displayID, 0, 0);
            // Move existing display to the right of the virtual display
            int32_t offset = (int32_t)CGDisplayBounds(displayID).size.width;
            if (offset == 0) offset = 1680; // fallback
            CGConfigureDisplayOrigin(config, existingDisplay, offset, 0);
            err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
            printf("Display arrangement: %s\n", err == kCGErrorSuccess ? "OK" : "FAILED");
            if (err != kCGErrorSuccess) CGCancelDisplayConfiguration(config);
        }

        sleep(2);
        printf("\n");
        printDisplays("After");

        // Write display ID to file for use by other scripts
        FILE *f = fopen("/tmp/retina-display-id", "w");
        if (f) {
            fprintf(f, "%u\n", displayID);
            fclose(f);
        }

        fflush(stdout);
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
