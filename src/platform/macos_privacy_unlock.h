#pragma once
#import <OpenDirectory/OpenDirectory.h>

static NSString *NPSLocalText(NSString *zh,NSString *en) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"]?zh:en;
}

@interface NPSUnlockPanel : NSPanel
@end
@implementation NPSUnlockPanel
- (BOOL)canBecomeKeyWindow {return YES;}
- (BOOL)canBecomeMainWindow {return NO;}
@end

@interface NPSUnlockController : NSObject
@property(strong) NSPanel *panel;
@property(strong) NSSecureTextField *password;
@property(strong) NSTextField *feedback;
@property(strong) NSButton *submit;
@property bool busy;
@property bool verified;
@property bool cancelled;
@property NSTimeInterval retryAfter;
- (void)cancel:(id)sender;
- (void)verify:(id)sender;
- (void)completed:(bool)verified available:(bool)available;
@end
@implementation NPSUnlockController
- (void)completed:(bool)verified available:(bool)available {
    self.busy=false;self.submit.enabled=YES;self.password.enabled=YES;
    if(self.cancelled)return;
    if(verified){self.verified=true;return;}
    self.retryAfter=NSProcessInfo.processInfo.systemUptime+3;
    self.feedback.stringValue=available?
        NPSLocalText(@"密码未通过验证，请重试。",@"Password verification failed. Retry."):
        NPSLocalText(@"系统账户暂不可验证，请从控制端关闭隐私屏。",@"System account verification is unavailable. Turn privacy off from the controller.");
    [self.panel makeFirstResponder:self.password];
}
- (void)cancel:(id)sender {
    self.cancelled=true;
    self.password.stringValue=@"";
    [self.panel orderOut:nil];
}
- (void)verify:(id)sender {
    if(self.busy)return;
    if(NSProcessInfo.processInfo.systemUptime<self.retryAfter){
        self.feedback.stringValue=NPSLocalText(@"请稍后再试。",@"Wait a moment before retrying.");return;
    }
    NSString *password=self.password.stringValue;
    self.password.stringValue=@"";
    if(!password.length || password.length>512){
        self.feedback.stringValue=NPSLocalText(@"请输入系统登录密码。",@"Enter the system login password.");return;
    }
    self.busy=true;self.submit.enabled=NO;self.password.enabled=NO;
    self.feedback.stringValue=NPSLocalText(@"正在验证…",@"Verifying…");
    // The password stays in the excluded local helper. Neither the pipes nor
    // the remote-session protocol ever carry it.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            NSError *error=nil;
            ODNode *node=[ODNode nodeWithSession:ODSession.defaultSession type:kODNodeTypeAuthentication error:&error];
            ODRecord *account=[node recordWithRecordType:kODRecordTypeUsers name:NSUserName() attributes:nil error:&error];
            const bool available=account!=nil;
            const bool verified=available && [account verifyPassword:password error:&error];
            dispatch_async(dispatch_get_main_queue(),^{
                [self completed:verified available:available];
            });
        }
    });
}
@end

static NPSUnlockController *npsUnlock;
static void NPSUnlockClose() {
    npsUnlock.password.stringValue=@"";
    [npsUnlock.panel orderOut:nil];[npsUnlock.panel close];npsUnlock=nil;
}
static bool NPSUnlockShow() {
    if(npsUnlock.busy)return true;
    if(!npsUnlock){
        npsUnlock=[NPSUnlockController new];
        NSRect frame=NSMakeRect(0,0,460,240);
        NSPanel *panel=[[NPSUnlockPanel alloc] initWithContentRect:frame
            styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        if(!panel){npsUnlock=nil;return false;}
        panel.releasedWhenClosed=NO;panel.hidesOnDeactivate=NO;panel.opaque=YES;
        panel.backgroundColor=[NSColor colorWithWhite:.13 alpha:1];
        panel.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        panel.level=CGWindowLevelForKey(kCGScreenSaverWindowLevelKey)+2;
        panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        npsUnlock.panel=panel;
        NSTextField *title=[NSTextField labelWithString:NPSLocalText(@"退出隐私屏",@"Exit privacy screen")];
        title.frame=NSMakeRect(24,194,412,28);title.font=[NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
        NSTextField *detail=[NSTextField labelWithString:NPSLocalText(@"输入当前 Mac 账户的系统登录密码。",@"Enter the current Mac account's login password.")];
        detail.frame=NSMakeRect(24,162,412,22);detail.font=[NSFont systemFontOfSize:13];
        NSSecureTextField *password=[[NSSecureTextField alloc] initWithFrame:NSMakeRect(24,116,412,32)];
        password.placeholderString=NPSLocalText(@"系统登录密码",@"System login password");
        password.font=[NSFont systemFontOfSize:16];password.target=npsUnlock;password.action=@selector(verify:);
        npsUnlock.password=password;
        NSTextField *feedback=[NSTextField labelWithString:@""];
        feedback.frame=NSMakeRect(24,73,412,34);feedback.font=[NSFont systemFontOfSize:12];feedback.maximumNumberOfLines=2;
        npsUnlock.feedback=feedback;
        NSButton *cancel=[NSButton buttonWithTitle:NPSLocalText(@"保持隐私屏",@"Keep privacy on") target:npsUnlock action:@selector(cancel:)];
        cancel.frame=NSMakeRect(202,24,120,32);cancel.keyEquivalent=@"\033";
        NSButton *submit=[NSButton buttonWithTitle:NPSLocalText(@"验证并退出",@"Verify and exit") target:npsUnlock action:@selector(verify:)];
        submit.frame=NSMakeRect(330,24,106,32);submit.keyEquivalent=@"\r";npsUnlock.submit=submit;
        for(NSView *view in @[title,detail,password,feedback,cancel,submit])[panel.contentView addSubview:view];
    }
    NSScreen *screen=NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if(!screen)return false;
    NSRect frame=npsUnlock.panel.frame;
    frame.origin=NSMakePoint(NSMidX(screen.frame)-frame.size.width/2,NSMidY(screen.frame)-frame.size.height/2);
    [npsUnlock.panel setFrame:frame display:YES];
    npsUnlock.feedback.stringValue=@"";
    npsUnlock.cancelled=false;
    [npsUnlock.panel makeKeyAndOrderFront:nil];
    [npsUnlock.panel makeFirstResponder:npsUnlock.password];
    return npsUnlock.panel.visible;
}
