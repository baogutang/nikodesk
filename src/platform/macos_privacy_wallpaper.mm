#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <sys/stat.h>
#include <unistd.h>

static NSArray<NSWindow*> *npsWindows;
static NSArray<NSDictionary*> *npsScreens;
static bool npsShown=false;

@interface NPSWallpaperPanel : NSPanel
@end
@implementation NPSWallpaperPanel
- (BOOL)canBecomeKeyWindow {return NO;}
- (BOOL)canBecomeMainWindow {return NO;}
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen*)screen {return frame;}
@end

static CGImageRef NPSImage(const uint8_t *pixels,uint32_t width,uint32_t height) {
    @autoreleasepool {
    if(!pixels || !width || !height || width>4096 || height>4096)return nullptr;
    NSData *bytes=[NSData dataWithBytes:pixels length:static_cast<size_t>(width)*height*4];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=CGImageCreate(width,height,8,32,width*4,colors,
        kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,nullptr,false,kCGRenderingIntentDefault);
    CGColorSpaceRelease(colors);CGDataProviderRelease(provider);return image;
    }
}

@interface NPSWallpaperView : NSView
@property(strong) id wallpaper;
@property(strong) id mask;
@property bool hint;
@property bool clock;
@end
@implementation NPSWallpaperView
- (BOOL)isFlipped {return YES;}
- (BOOL)isOpaque {return YES;}
- (void)drawRect:(NSRect)dirty {
    CGContextRef context=NSGraphicsContext.currentContext.CGContext;
    CGRect bounds=NSRectToCGRect(self.bounds);
    CGContextSetRGBFillColor(context,0,0,0,1);CGContextFillRect(context,bounds);
    CGImageRef image=(__bridge CGImageRef)self.wallpaper;
    if(image) {
        CGFloat width=CGImageGetWidth(image),height=CGImageGetHeight(image);
        CGFloat scale=MAX(bounds.size.width/width,bounds.size.height/height);
        CGRect destination=CGRectMake((bounds.size.width-width*scale)/2,(bounds.size.height-height*scale)/2,width*scale,height*scale);
        CGContextSaveGState(context);CGContextTranslateCTM(context,0,bounds.size.height);CGContextScaleCTM(context,1,-1);
        CGContextSetInterpolationQuality(context,kCGInterpolationHigh);CGContextDrawImage(context,destination,image);
        CGImageRef mask=(__bridge CGImageRef)self.mask;
        if(mask)CGContextDrawImage(context,bounds,mask);
        CGContextRestoreGState(context);
    }
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:.72]};
    if(self.hint)[@"⌃⌥⇧ Esc 恢复" drawAtPoint:NSMakePoint(24,MAX(0,bounds.size.height-36)) withAttributes:attributes];
    if(self.clock){
        NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateFormat=@"HH:mm";
        NSString *clock=[formatter stringFromDate:[NSDate date]];
        NSSize size=[clock sizeWithAttributes:attributes];
        [clock drawAtPoint:NSMakePoint(MAX(24,bounds.size.width-size.width-24),24) withAttributes:attributes];
    }
}
@end

static NSArray<NSDictionary*> *NPSScreens() {
    NSMutableArray *screens=[NSMutableArray new];
    for(NSScreen *screen in NSScreen.screens) {
        NSNumber *display=screen.deviceDescription[@"NSScreenNumber"];
        if(!display)return nil;
        [screens addObject:@{@"id":display,@"frame":NSStringFromRect(screen.frame)}];
    }
    return screens.count?screens:nil;
}
extern "C" bool NPSWindowSupported() {
    return getuid()!=0 && CGPreflightScreenCaptureAccess() && AXIsProcessTrusted();
}
extern "C" bool NPSWindowPipes() {
    struct stat input{},output{};
    return fstat(STDIN_FILENO,&input)==0 && fstat(STDOUT_FILENO,&output)==0 && S_ISFIFO(input.st_mode) && S_ISFIFO(output.st_mode);
}
extern "C" bool NPSWindowsStyle(const uint8_t *pixels,uint32_t width,uint32_t height,bool hint,bool clock) {
    CGImageRef image=NPSImage(pixels,width,height);if(!image)return false;
    for(NSWindow *window in npsWindows) {
        NPSWallpaperView *view=(NPSWallpaperView*)window.contentView;
        view.wallpaper=(__bridge id)image;view.hint=hint;view.clock=clock;view.needsDisplay=YES;
    }
    CGImageRelease(image);return npsWindows.count>0;
}
extern "C" void NPSWindowsClose() {
    for(NSWindow *window in npsWindows){[window orderOut:nil];[window close];}
    npsWindows=nil;npsScreens=nil;npsShown=false;
}
extern "C" bool NPSWindowsCreate(const uint8_t *pixels,uint32_t width,uint32_t height,bool hint,bool clock) {
    if(!NSThread.isMainThread || npsWindows)return false;
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    npsScreens=NPSScreens();if(!npsScreens || npsScreens.count>32)return false;
    NSMutableArray<NSWindow*> *windows=[NSMutableArray new];
    for(NSScreen *screen in NSScreen.screens){
        NSPanel *window=[[NPSWallpaperPanel alloc] initWithContentRect:screen.frame
            styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        if(!window){for(NSWindow *existing in windows)[existing close];return false;}
        window.releasedWhenClosed=NO;window.opaque=YES;window.backgroundColor=NSColor.blackColor;
        window.ignoresMouseEvents=YES;window.hidesOnDeactivate=NO;window.animationBehavior=NSWindowAnimationBehaviorNone;
        window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        window.contentView=[[NPSWallpaperView alloc] initWithFrame:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height)];
        // Register an on-screen window behind the desktop before content
        // discovery. Only V can raise it after every excluded capture is ready.
        window.level=CGWindowLevelForKey(kCGDesktopWindowLevelKey)-1;
        [window orderBack:nil];[windows addObject:window];
    }
    npsWindows=windows;
    if(!NPSWindowsStyle(pixels,width,height,hint,clock)){NPSWindowsClose();return false;}
    return [npsScreens isEqual:NPSScreens()];
}
extern "C" bool NPSWindowsShow() {
    if(![npsScreens isEqual:NPSScreens()])return false;
    for(NSWindow *window in npsWindows){window.level=CGWindowLevelForKey(kCGScreenSaverWindowLevelKey)+1;[window orderFrontRegardless];}
    npsShown=true;return npsWindows.count>0;
}
extern "C" bool NPSWindowsMotionAllowed() {
    return !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}
extern "C" bool NPSWindowsTick(const uint8_t *pixels,uint32_t width,uint32_t height) {
    @autoreleasepool {
        if(![npsScreens isEqual:NPSScreens()])return false;
        CGImageRef mask=NPSImage(pixels,width,height);if(!mask)return false;
        for(NSWindow *window in npsWindows){
            NPSWallpaperView *view=(NPSWallpaperView*)window.contentView;view.mask=(__bridge id)mask;
            if(npsShown){[window orderFrontRegardless];if(!window.visible){CGImageRelease(mask);return false;}}
            view.needsDisplay=YES;[window displayIfNeeded];
        }
        CGImageRelease(mask);
        for(int i=0;i<64;++i){
            NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES];
            if(!event)break;[NSApp sendEvent:event];
        }
        [NSApp updateWindows];return true;
    }
}
