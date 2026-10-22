#import <AppKit/AppKit.h>

// The menu bar icon of the process that holds the NikoDesk core. Rust owns the
// state and the wording; this file only turns them into AppKit objects on the
// main thread.

typedef void (*NikoMenuBarFill)(void *menu);
typedef void (*NikoMenuBarChoose)(long tag);

@interface NikoMenuBar : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSImage *idle;
@property(nonatomic, strong) NSImage *busy;
@property(nonatomic) NikoMenuBarFill fill;
@property(nonatomic) NikoMenuBarChoose choose;
@end

@implementation NikoMenuBar
// Rebuilt on every open so the menu never shows a stale state.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    self.fill((__bridge void *)menu);
}
- (void)chosen:(NSMenuItem *)sender {
    self.choose(sender.tag);
}
@end

static NikoMenuBar *bar;

static NSString *NikoString(const char *text) {
    NSString *string = text ? [NSString stringWithUTF8String:text] : nil;
    return string ?: @"";
}

// A dot in the lower right corner, cut free of the glyph, while a peer is
// connected. Still a template, so it follows the menu bar's appearance.
static NSImage *NikoBadged(NSImage *icon) {
    NSImage *image = [NSImage imageWithSize:icon.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [icon drawInRect:rect];
        NSRect dot = NSMakeRect(NSMaxX(rect) - 7, NSMinY(rect), 7, 7);
        NSGraphicsContext *context = [NSGraphicsContext currentContext];
        context.compositingOperation = NSCompositingOperationClear;
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -1.5, -1.5)] fill];
        context.compositingOperation = NSCompositingOperationSourceOver;
        [[NSColor blackColor] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        return YES;
    }];
    [image setTemplate:YES];
    image.accessibilityDescription = icon.accessibilityDescription;
    return image;
}

extern "C" void NikoMenuBarStart(const unsigned char *png, size_t length,
                                 NikoMenuBarFill fill, NikoMenuBarChoose choose) {
    NSData *data = [NSData dataWithBytes:png length:length];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (bar) return;
        NSImage *icon = [[NSImage alloc] initWithData:data];
        if (!icon) return;
        icon.size = NSMakeSize(18, 18);
        [icon setTemplate:YES];
        icon.accessibilityDescription = @"NikoDesk";
        NikoMenuBar *created = [NikoMenuBar new];
        created.idle = icon;
        created.busy = NikoBadged(icon);
        created.fill = fill;
        created.choose = choose;
        NSMenu *menu = [NSMenu new];
        menu.autoenablesItems = NO;
        menu.delegate = created;
        created.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        // Shared by the window app and the agent, so the icon keeps its place
        // when the other one takes over the core.
        created.item.autosaveName = @"io.nikodesk.menu-bar";
        created.item.button.image = icon;
        created.item.button.toolTip = @"NikoDesk";
        created.item.menu = menu;
        bar = created;
    });
}

// Called from `fill`, on the main thread. A negative tag is a separator.
extern "C" void NikoMenuBarAppend(void *menu, const char *title, long tag, bool enabled) {
    NSMenu *target = (__bridge NSMenu *)menu;
    if (tag < 0) {
        [target addItem:[NSMenuItem separatorItem]];
        return;
    }
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NikoString(title)
                                                  action:enabled ? @selector(chosen:) : nil
                                           keyEquivalent:@""];
    item.target = bar;
    item.tag = tag;
    item.enabled = enabled;
    [target addItem:item];
}

extern "C" void NikoMenuBarSetState(bool online, bool busy, const char *tooltip) {
    NSString *tip = NikoString(tooltip);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!bar) return;
        bar.item.button.image = busy ? bar.busy : bar.idle;
        bar.item.button.appearsDisabled = !online;
        bar.item.button.toolTip = tip;
    });
}

// The functions below run from a menu action, on the main thread.
extern "C" void NikoMenuBarCopy(const char *text) {
    NSPasteboard *board = [NSPasteboard generalPasteboard];
    [board clearContents];
    [board setString:NikoString(text) forType:NSPasteboardTypeString];
}

extern "C" bool NikoMenuBarConfirm(const char *title, const char *message,
                                   const char *accept, const char *cancel) {
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = NikoString(title);
    alert.informativeText = NikoString(message);
    [alert addButtonWithTitle:NikoString(accept)];
    [alert addButtonWithTitle:NikoString(cancel)];
    return [alert runModal] == NSAlertFirstButtonReturn;
}

extern "C" void NikoMenuBarQuit(void) {
    [NSApp terminate:nil];
}
