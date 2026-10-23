#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <sys/stat.h>
#include <unistd.h>
#include "macos_privacy_unlock.h"
#include "macos_privacy_scene.h"

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
// A Nightline scene drawn by Core Animation instead of the picture, or nil.
@property(strong) NSString *scene;
@property(strong) CALayer *overlay;
@end
@implementation NPSWallpaperView
- (BOOL)isFlipped {return YES;}
- (BOOL)isOpaque {return YES;}
- (void)drawRect:(NSRect)dirty {
    CGContextRef context=NSGraphicsContext.currentContext.CGContext;
    CGRect bounds=NSRectToCGRect(self.bounds);
    CGContextSetRGBFillColor(context,0,0,0,1);CGContextFillRect(context,bounds);
    if(self.scene)return;
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
}
@end

// The scene, or for a picture the status overlay above it, as sublayers of
// the view's own layer. Rebuilt whenever the style changes.
static void NPSInstallOverlay(NPSWallpaperView *view,NSWindow *window,bool motion,uint32_t brightness,uint32_t intensity) {
    NPSSceneOptions options;
    options.motion=motion && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    options.brightness=view.scene?brightness/100.0:1;
    options.intensity=intensity/100.0;
    // The local way out is always shown on a Mac, as before; `hint` is kept for the protocol.
    options.hint=true;
    options.clock=view.clock;
    options.scale=window.backingScaleFactor;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    [view.overlay removeFromSuperlayer];
    view.overlay=NPSSceneBuild(view.scene,view.bounds,options);
    // This view is flipped, so its layer already has a top-left origin.
    view.overlay.geometryFlipped=NO;
    [view.layer addSublayer:view.overlay];
    [CATransaction commit];
}

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
extern "C" bool NPSWindowsStyle(const uint8_t *pixels,uint32_t width,uint32_t height,bool hint,bool clock,
        const char *scene,bool motion,uint32_t brightness,uint32_t intensity) {
    NSString *name=scene?[NSString stringWithUTF8String:scene]:nil;
    if(name && !NPSSceneKnown(name))return false;
    CGImageRef image=NPSImage(pixels,width,height);if(!image)return false;
    for(NSWindow *window in npsWindows) {
        NPSWallpaperView *view=(NPSWallpaperView*)window.contentView;
        view.wallpaper=(__bridge id)image;view.hint=hint;view.clock=clock;view.scene=name;view.mask=nil;
        view.needsDisplay=YES;
        NPSInstallOverlay(view,window,motion,brightness,intensity);
    }
    CGImageRelease(image);return npsWindows.count>0;
}
extern "C" void NPSWindowsClose() {
    NPSUnlockClose();
    for(NSWindow *window in npsWindows){[window orderOut:nil];[window close];}
    npsWindows=nil;npsScreens=nil;npsShown=false;
}
extern "C" bool NPSWindowsCreate(const uint8_t *pixels,uint32_t width,uint32_t height,bool hint,bool clock,
        const char *scene,bool motion,uint32_t brightness,uint32_t intensity) {
    if(!NSThread.isMainThread || npsWindows)return false;
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    npsScreens=NPSScreens();if(!npsScreens || npsScreens.count>32)return false;
    NSMutableArray<NSWindow*> *windows=[NSMutableArray new];
    for(NSScreen *screen in NSScreen.screens){
        NSPanel *window=[[NPSWallpaperPanel alloc] initWithContentRect:screen.frame
            styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        if(!window){for(NSWindow *existing in windows)[existing close];return false;}
        window.releasedWhenClosed=NO;window.opaque=YES;window.backgroundColor=NSColor.blackColor;
        window.ignoresMouseEvents=YES;window.hidesOnDeactivate=NO;window.animationBehavior=NSWindowAnimationBehaviorNone;
        window.collectionBehavior=NPSCoverBehavior();
        window.contentView=[[NPSWallpaperView alloc] initWithFrame:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height)];
        window.contentView.wantsLayer=YES;
        // Register an on-screen window behind the desktop before content
        // discovery. Only V can raise it after every excluded capture is ready.
        window.level=CGWindowLevelForKey(kCGDesktopWindowLevelKey)-1;
        [window orderBack:nil];[windows addObject:window];
    }
    npsWindows=windows;
    if(!NPSWindowsStyle(pixels,width,height,hint,clock,scene,motion,brightness,intensity)){NPSWindowsClose();return false;}
    return [npsScreens isEqual:NPSScreens()];
}
extern "C" bool NPSWindowsShow() {
    if(![npsScreens isEqual:NPSScreens()])return false;
    for(NSWindow *window in npsWindows){window.level=CGWindowLevelForKey(kCGScreenSaverWindowLevelKey)+1;[window orderFrontRegardless];}
    npsShown=true;return npsWindows.count>0;
}
extern "C" bool NPSWindowsRequestUnlock() {return npsShown && NPSUnlockShow();}
extern "C" bool NPSWindowsUnlocked() {return npsUnlock.verified;}
extern "C" bool NPSWindowsMotionAllowed() {
    return !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}
extern "C" bool NPSWindowsTick(const uint8_t *pixels,uint32_t width,uint32_t height) {
    @autoreleasepool {
        if(![npsScreens isEqual:NPSScreens()])return false;
        CGImageRef mask=NPSImage(pixels,width,height);if(!mask)return false;
        for(NSWindow *window in npsWindows){
            NPSWallpaperView *view=(NPSWallpaperView*)window.contentView;
            if(npsShown){[window orderFrontRegardless];if(!window.visible){CGImageRelease(mask);return false;}}
            // A scene animates in the window server; only a picture's effect mask is redrawn here.
            if(!view.scene){view.mask=(__bridge id)mask;view.needsDisplay=YES;[window displayIfNeeded];}
            if(view.overlay)NPSSceneTick(view.overlay);
        }
        CGImageRelease(mask);
        for(int i=0;i<64;++i){
            NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES];
            if(!event)break;[NSApp sendEvent:event];
        }
        [NSApp updateWindows];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.001,true);
        return true;
    }
}
