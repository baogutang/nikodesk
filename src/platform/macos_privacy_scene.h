#pragma once
// Privacy screen scenes in NikoDesk's Nightline (夜航) style. Each scene is a
// Core Animation layer tree: the window server plays the animations at the
// display's own refresh rate, so they stay smooth while the helper process
// does almost nothing, and every shape and glyph is drawn at the screen's
// resolution instead of being an upscaled picture.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <cmath>

struct NPSSceneOptions {
    bool motion = true;        // false also under the system's Reduce Motion
    double brightness = 1;     // 0.4 ... 1
    double intensity = 1;      // 0.5 ... 2, strength of the glows
    bool hint = true;          // status pill with the exit shortcut
    bool clock = false;        // corner clock; the graphite scene always shows one
    CGFloat scale = 2;         // backing scale factor of the screen
};

// Nightline tokens.
static const uint32_t NPSPage = 0x07080A, NPSFg = 0xE6EDF2, NPSFg2 = 0x93A1AD, NPSFg3 = 0x687682,
    NPSLine2 = 0x2F3841, NPSAccent = 0x2FD8EE, NPSAccentText = 0x5CE6F7, NPSAccent2 = 0x7FA2FF, NPSOk = 0x3DDC97;

static NSColor *NPSRGB(uint32_t rgb, CGFloat alpha = 1) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
        blue:(rgb & 0xFF) / 255.0 alpha:alpha];
}
static CGColorRef NPSCG(uint32_t rgb, CGFloat alpha = 1) { return NPSRGB(rgb, alpha).CGColor; }

static bool NPSChinese() { return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"]; }

static CALayer *NPSLayer(CGRect frame, CGFloat scale) {
    CALayer *layer = [CALayer layer];
    layer.frame = frame;
    layer.contentsScale = scale;
    return layer;
}

// A soft round light: the colour fades to nothing at the edge of its frame.
static CAGradientLayer *NPSGlow(CGRect frame, uint32_t rgb, CGFloat alpha, CGFloat scale) {
    CAGradientLayer *glow = [CAGradientLayer layer];
    glow.type = kCAGradientLayerRadial;
    glow.frame = frame;
    glow.contentsScale = scale;
    glow.colors = @[(__bridge id)NPSCG(rgb, alpha), (__bridge id)NPSCG(rgb, alpha * .55),
        (__bridge id)NPSCG(rgb, alpha * .18), (__bridge id)NPSCG(rgb, 0)];
    glow.locations = @[@0, @.32, @.62, @1];
    glow.startPoint = CGPointMake(.5, .5);
    glow.endPoint = CGPointMake(1, 1);
    return glow;
}

static void NPSAnimate(CALayer *layer, CAAnimation *animation, NSString *key, double phase) {
    animation.repeatCount = HUGE_VALF;
    animation.timeOffset = phase;
    animation.removedOnCompletion = NO;
    [layer addAnimation:animation forKey:key];
}

// Slow closed path through the given points; the cubic mode keeps it free of corners.
static void NPSDrift(CALayer *layer, NSArray<NSValue *> *points, double seconds, double phase) {
    CAKeyframeAnimation *drift = [CAKeyframeAnimation animationWithKeyPath:@"position"];
    NSMutableArray *values = [points mutableCopy];
    [values addObject:points.firstObject];
    drift.values = values;
    drift.duration = seconds;
    drift.calculationMode = kCAAnimationCubic;
    NPSAnimate(layer, drift, @"drift", phase);
}

static void NPSBreathe(CALayer *layer, NSString *path, id from, id to, double seconds, double phase) {
    CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:path];
    breathe.fromValue = from;
    breathe.toValue = to;
    breathe.duration = seconds;
    breathe.autoreverses = YES;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    NPSAnimate(layer, breathe, [@"breathe-" stringByAppendingString:path], phase);
}

static NSValue *NPSPoint(CGRect bounds, CGFloat x, CGFloat y) {
    return [NSValue valueWithPoint:NSMakePoint(bounds.size.width * x, bounds.size.height * y)];
}

// Fine monochrome grain. Dark gradients band on large panels; noise at about
// 3% hides the steps without being visible as texture.
static CALayer *NPSGrain(CGRect bounds, CGFloat scale) {
    static CGImageRef tile = nullptr;
    if (!tile) {
        const size_t side = 128;
        uint8_t *pixels = (uint8_t *)calloc(side * side, 4);
        for (size_t i = 0; i < side * side; ++i) {
            uint8_t value = arc4random_uniform(2) ? 255 : 0;
            uint8_t alpha = (uint8_t)arc4random_uniform(9);
            pixels[i * 4] = pixels[i * 4 + 1] = pixels[i * 4 + 2] = (uint8_t)(value * alpha / 255);
            pixels[i * 4 + 3] = alpha;
        }
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space,
            kCGImageAlphaPremultipliedLast);
        tile = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        CGColorSpaceRelease(space);
        free(pixels);
    }
    CALayer *grain = NPSLayer(bounds, scale);
    NSImage *image = [[NSImage alloc] initWithCGImage:tile size:NSMakeSize(128 / scale, 128 / scale)];
    grain.backgroundColor = [NSColor colorWithPatternImage:image].CGColor;
    return grain;
}

static CAGradientLayer *NPSVignette(CGRect bounds, CGFloat strength, CGFloat scale) {
    CAGradientLayer *vignette = [CAGradientLayer layer];
    vignette.type = kCAGradientLayerRadial;
    CGFloat side = MAX(bounds.size.width, bounds.size.height) * 1.25;
    vignette.frame = CGRectMake(CGRectGetMidX(bounds) - side / 2, CGRectGetMidY(bounds) - side / 2, side, side);
    vignette.contentsScale = scale;
    vignette.colors = @[(__bridge id)NPSCG(0, 0), (__bridge id)NPSCG(0, 0),
        (__bridge id)NPSCG(0, strength * .55), (__bridge id)NPSCG(0, strength)];
    vignette.locations = @[@0, @.38, @.62, @.8];
    vignette.startPoint = CGPointMake(.5, .5);
    vignette.endPoint = CGPointMake(1, 1);
    return vignette;
}

static NSFont *NPSMono(CGFloat size, NSFontWeight weight) {
    return [NSFont monospacedSystemFontOfSize:size weight:weight];
}

static CATextLayer *NPSText(NSString *text, NSFont *font, uint32_t rgb, CGFloat alpha, CGFloat kern,
        CGFloat scale) {
    NSDictionary *attributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: NPSRGB(rgb, alpha),
        NSKernAttributeName: @(kern)};
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    NSSize size = string.size;
    CATextLayer *layer = [CATextLayer layer];
    layer.string = string;
    layer.contentsScale = scale;
    layer.bounds = CGRectMake(0, 0, ceil(size.width) + 2, ceil(size.height) + 1);
    layer.alignmentMode = kCAAlignmentCenter;
    return layer;
}

static NSString *NPSClockText() {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"HH:mm";
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *NPSDateText() {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:NPSChinese() ? @"zh_CN" : @"en_US"];
    [formatter setLocalizedDateFormatFromTemplate:@"MMMMdEEEE"];
    return [formatter stringFromDate:[NSDate date]];
}

static CALayer *NPSLed(CGFloat scale, bool motion) {
    CALayer *led = NPSLayer(CGRectMake(0, 0, 7, 7), scale);
    led.cornerRadius = 3.5;
    led.backgroundColor = NPSCG(NPSAccent);
    led.shadowColor = NPSCG(NPSAccent);
    led.shadowOpacity = .9;
    led.shadowRadius = 5;
    led.shadowOffset = CGSizeZero;
    if (motion) NPSBreathe(led, @"opacity", @1, @.35, 1.6, 0);
    return led;
}

// One key of the exit shortcut, drawn the way the controller's UI draws <kbd>.
static CALayer *NPSKeycap(NSString *key, CGFloat scale) {
    CATextLayer *text = NPSText(key, NPSMono(11, NSFontWeightMedium), NPSFg2, 1, 0, scale);
    CGFloat width = MAX(20, text.bounds.size.width + 10);
    CALayer *cap = NPSLayer(CGRectMake(0, 0, width, 20), scale);
    cap.cornerRadius = 5;
    cap.borderWidth = 1;
    cap.borderColor = NPSCG(NPSLine2);
    cap.backgroundColor = NPSCG(0xFFFFFF, .03);
    text.position = CGPointMake(width / 2, 10);
    [cap addSublayer:text];
    return cap;
}

// The status pill: "privacy screen on", then the local way out. With
// `status` false only the way out is shown (the scene states the status).
static CALayer *NPSPill(CGRect bounds, bool status, CGFloat scale, bool motion) {
    NSMutableArray<CALayer *> *items = [NSMutableArray array];
    NSMutableArray<NSNumber *> *gaps = [NSMutableArray array];
    if (status) {
        [items addObject:NPSLed(scale, motion)];
        [gaps addObject:@10];
        [items addObject:NPSText(NPSChinese() ? @"隐私屏已开启" : @"Privacy screen is on",
            [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NPSFg, 1, 0, scale)];
        [gaps addObject:@14];
        CALayer *divider = NPSLayer(CGRectMake(0, 0, 1, 14), scale);
        divider.backgroundColor = NPSCG(0xFFFFFF, .1);
        [items addObject:divider];
        [gaps addObject:@14];
    }
    for (NSString *key in @[@"⌃", @"⌥", @"⇧", @"esc"]) {
        [items addObject:NPSKeycap(key, scale)];
        [gaps addObject:@4];
    }
    gaps[gaps.count - 1] = @10;
    [items addObject:NPSText(NPSChinese() ? @"退出 · 需本机登录密码" : @"to exit · local login password",
        [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular], NPSFg2, 1, 0, scale)];
    [gaps addObject:@0];
    CGFloat width = 36;
    for (NSUInteger i = 0; i < items.count; ++i) width += items[i].bounds.size.width + gaps[i].doubleValue;
    const CGFloat height = 44;
    CALayer *pill = NPSLayer(CGRectMake(CGRectGetMidX(bounds) - width / 2, bounds.size.height - height - 48,
        width, height), scale);
    pill.cornerRadius = height / 2;
    pill.backgroundColor = NPSCG(0x0B0D10, .72);
    pill.borderWidth = 1;
    pill.borderColor = NPSCG(0xFFFFFF, .08);
    pill.shadowColor = NPSCG(0);
    pill.shadowOpacity = .6;
    pill.shadowRadius = 24;
    pill.shadowOffset = CGSizeMake(0, 10);
    CGFloat x = 18;
    for (NSUInteger i = 0; i < items.count; ++i) {
        CALayer *item = items[i];
        item.position = CGPointMake(x + item.bounds.size.width / 2, height / 2);
        [pill addSublayer:item];
        x += item.bounds.size.width + gaps[i].doubleValue;
    }
    return pill;
}

// Lock in a ring with a slowly circling signal arc and a sonar ping.
static CALayer *NPSEmblem(CGPoint center, CGFloat scale, bool motion) {
    const CGFloat side = 112, radius = 40;
    CALayer *emblem = NPSLayer(CGRectMake(center.x - side / 2, center.y - side / 2, side, side), scale);
    CGRect box = CGRectMake(side / 2 - radius, side / 2 - radius, radius * 2, radius * 2);
    CGPathRef circle = CGPathCreateWithEllipseInRect(box, nullptr);

    CAShapeLayer *ping = [CAShapeLayer layer];
    ping.frame = emblem.bounds;
    ping.contentsScale = scale;
    ping.path = circle;
    ping.fillColor = nil;
    ping.strokeColor = NPSCG(NPSAccent, .5);
    ping.lineWidth = 1;
    ping.opacity = 0;
    if (motion) {
        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        grow.fromValue = @1;
        grow.toValue = @1.55;
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @.7;
        fade.toValue = @0;
        CAAnimationGroup *pulse = [CAAnimationGroup animation];
        pulse.animations = @[grow, fade];
        pulse.duration = 3.6;
        pulse.timingFunction = [CAMediaTimingFunction functionWithControlPoints:.16 :1 :.3 :1];
        NPSAnimate(ping, pulse, @"ping", 0);
    }
    [emblem addSublayer:ping];

    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = emblem.bounds;
    ring.contentsScale = scale;
    ring.path = circle;
    ring.fillColor = NPSCG(0x0B0D10, .55);
    ring.strokeColor = NPSCG(0xFFFFFF, .1);
    ring.lineWidth = 1;
    [emblem addSublayer:ring];

    CAShapeLayer *arc = [CAShapeLayer layer];
    arc.frame = emblem.bounds;
    arc.contentsScale = scale;
    arc.path = circle;
    arc.fillColor = nil;
    arc.strokeColor = NPSCG(NPSAccent);
    arc.lineWidth = 1.6;
    arc.lineCap = kCALineCapRound;
    arc.strokeStart = 0;
    arc.strokeEnd = .16;
    arc.shadowColor = NPSCG(NPSAccent);
    arc.shadowOpacity = .8;
    arc.shadowRadius = 4;
    arc.shadowOffset = CGSizeZero;
    if (motion) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0;
        spin.toValue = @(-2 * M_PI);
        spin.duration = 4.2;
        NPSAnimate(arc, spin, @"spin", 0);
    }
    [emblem addSublayer:arc];
    CGPathRelease(circle);

    // A padlock in a 24 x 28 box, drawn with the UI's 1.6 point stroke.
    CGMutablePathRef lock = CGPathCreateMutable();
    const CGFloat lx = side / 2 - 11, ly = side / 2 - 13;
    CGPathAddRoundedRect(lock, nullptr, CGRectMake(lx, ly + 11, 22, 16), 4, 4);
    CGPathMoveToPoint(lock, nullptr, lx + 5, ly + 11);
    CGPathAddLineToPoint(lock, nullptr, lx + 5, ly + 7);
    CGPathAddArc(lock, nullptr, lx + 11, ly + 7, 6, M_PI, 0, false);
    CGPathAddLineToPoint(lock, nullptr, lx + 17, ly + 11);
    CGPathMoveToPoint(lock, nullptr, lx + 11, ly + 17);
    CGPathAddLineToPoint(lock, nullptr, lx + 11, ly + 21);
    CAShapeLayer *padlock = [CAShapeLayer layer];
    padlock.frame = emblem.bounds;
    padlock.contentsScale = scale;
    padlock.path = lock;
    padlock.fillColor = nil;
    padlock.strokeColor = NPSCG(NPSFg);
    padlock.lineWidth = 1.6;
    padlock.lineCap = kCALineCapRound;
    padlock.lineJoin = kCALineJoinRound;
    [emblem addSublayer:padlock];
    CGPathRelease(lock);
    return emblem;
}

static void NPSAddTitle(CALayer *root, CGPoint center, CGFloat scale) {
    CATextLayer *title = NPSText(NPSChinese() ? @"隐私屏已开启" : @"Privacy screen is on",
        [NSFont systemFontOfSize:28 weight:NSFontWeightSemibold], NPSFg, 1, NPSChinese() ? 1.5 : 0, scale);
    title.position = center;
    [root addSublayer:title];
    CATextLayer *label = NPSText(@"REMOTE SESSION · SCREEN PROTECTED", NPSMono(11, NSFontWeightMedium),
        NPSFg3, 1, 1.6, scale);
    label.position = CGPointMake(center.x, center.y + 34);
    [root addSublayer:label];
}

// 夜航: two vast lights drifting in the dark, a horizon with a passing glint,
// and the lock emblem at the centre.
static void NPSSceneNightline(CALayer *root, const NPSSceneOptions &o) {
    CGRect b = root.bounds;
    CGFloat w = b.size.width, h = b.size.height, s = o.scale, k = o.intensity;
    root.backgroundColor = NPSCG(NPSPage);
    CGFloat big = MAX(w, h) * 1.15;
    CAGradientLayer *cyan = NPSGlow(CGRectMake(0, 0, big, big), NPSAccent, .15 * k, s);
    cyan.position = CGPointMake(w * .22, h * .74);
    CAGradientLayer *blue = NPSGlow(CGRectMake(0, 0, big * .9, big * .9), NPSAccent2, .13 * k, s);
    blue.position = CGPointMake(w * .8, h * .2);
    CAGradientLayer *teal = NPSGlow(CGRectMake(0, 0, big * .55, big * .55), NPSOk, .05 * k, s);
    teal.position = CGPointMake(w * .55, h * .9);
    for (CALayer *glow in @[cyan, blue, teal]) [root addSublayer:glow];
    if (o.motion) {
        NPSDrift(cyan, @[NPSPoint(b, .22, .74), NPSPoint(b, .4, .56), NPSPoint(b, .3, .9), NPSPoint(b, .08, .66)], 28, 0);
        NPSDrift(blue, @[NPSPoint(b, .8, .2), NPSPoint(b, .62, .36), NPSPoint(b, .88, .4), NPSPoint(b, .94, .1)], 34, 9);
        NPSDrift(teal, @[NPSPoint(b, .55, .9), NPSPoint(b, .4, .74), NPSPoint(b, .7, .78)], 24, 11);
        NPSBreathe(cyan, @"opacity", @1, @.6, 6, 0);
        NPSBreathe(blue, @"opacity", @.7, @1, 7.5, 3);
    }

    // Horizon: a hairline fading out at both ends, and a glint travelling along it.
    CGFloat horizonY = h * .66;
    CAGradientLayer *horizon = [CAGradientLayer layer];
    horizon.frame = CGRectMake(0, horizonY, w, 1);
    horizon.contentsScale = s;
    horizon.startPoint = CGPointMake(0, .5);
    horizon.endPoint = CGPointMake(1, .5);
    horizon.colors = @[(__bridge id)NPSCG(NPSAccent, 0), (__bridge id)NPSCG(NPSAccent, .22 * MIN(k, 1.4)),
        (__bridge id)NPSCG(NPSAccent2, .16 * MIN(k, 1.4)), (__bridge id)NPSCG(NPSAccent2, 0)];
    horizon.locations = @[@.04, @.38, @.66, @.96];
    [root addSublayer:horizon];
    CAGradientLayer *glint = [CAGradientLayer layer];
    glint.frame = CGRectMake(-w * .18, horizonY - 1, w * .18, 3);
    glint.contentsScale = s;
    glint.startPoint = CGPointMake(0, .5);
    glint.endPoint = CGPointMake(1, .5);
    glint.colors = @[(__bridge id)NPSCG(NPSAccentText, 0), (__bridge id)NPSCG(NPSAccentText, .9),
        (__bridge id)NPSCG(0xFFFFFF, 0)];
    glint.locations = @[@0, @.92, @1];
    glint.shadowColor = NPSCG(NPSAccent);
    glint.shadowOpacity = 1;
    glint.shadowRadius = 6;
    glint.shadowOffset = CGSizeZero;
    if (o.motion) {
        CAKeyframeAnimation *pass = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
        pass.values = @[@(-w * .1), @(w * 1.1), @(w * 1.1)];
        pass.keyTimes = @[@0, @.62, @1];
        pass.duration = 7;
        pass.timingFunctions = @[[CAMediaTimingFunction functionWithControlPoints:.45 :0 :.25 :1],
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
        NPSAnimate(glint, pass, @"pass", 2);
        [root addSublayer:glint];
    }

    [root addSublayer:NPSVignette(b, .55, s)];
    [root addSublayer:NPSGrain(b, s)];
    CGPoint center = CGPointMake(w / 2, h * .42);
    [root addSublayer:NPSEmblem(center, s, o.motion)];
    NPSAddTitle(root, CGPointMake(w / 2, center.y + 88), s);
}

static CGImageRef NPSDot() {
    static CGImageRef dot = nullptr;
    if (!dot) {
        const size_t side = 16;
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(nullptr, side, side, 8, side * 4, space,
            kCGImageAlphaPremultipliedLast);
        CGFloat colors[] = {1, 1, 1, 1, 1, 1, 1, .35, 1, 1, 1, 0};
        CGFloat locations[] = {0, .35, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, locations, 3);
        CGContextDrawRadialGradient(context, gradient, CGPointMake(side / 2., side / 2.), 0,
            CGPointMake(side / 2., side / 2.), side / 2., 0);
        dot = CGBitmapContextCreateImage(context);
        CGGradientRelease(gradient);
        CGContextRelease(context);
        CGColorSpaceRelease(space);
    }
    return dot;
}

// 深空: three depths of stars drifting past, as if flying through them.
static void NPSSceneDeepfield(CALayer *root, const NPSSceneOptions &o) {
    CGRect b = root.bounds;
    CGFloat w = b.size.width, h = b.size.height, s = o.scale, k = o.intensity;
    root.backgroundColor = NPSCG(0x040507);
    CGFloat big = MAX(w, h);
    CAGradientLayer *nebula = NPSGlow(CGRectMake(0, 0, big * 1.1, big * .8), NPSAccent2, .16 * k, s);
    nebula.position = CGPointMake(w * .3, h * .3);
    CAGradientLayer *dust = NPSGlow(CGRectMake(0, 0, big * .9, big * .7), NPSAccent, .11 * k, s);
    dust.position = CGPointMake(w * .78, h * .78);
    [root addSublayer:nebula];
    [root addSublayer:dust];
    if (o.motion) {
        NPSDrift(nebula, @[NPSPoint(b, .3, .3), NPSPoint(b, .42, .38), NPSPoint(b, .24, .44)], 40, 0);
        NPSDrift(dust, @[NPSPoint(b, .78, .78), NPSPoint(b, .66, .68), NPSPoint(b, .86, .62)], 36, 13);
    }
    if (o.motion) {
        CAEmitterLayer *stars = [CAEmitterLayer layer];
        stars.frame = b;
        stars.contentsScale = s;
        stars.emitterShape = kCAEmitterLayerRectangle;
        stars.emitterPosition = CGPointMake(w + 8, h / 2);
        stars.emitterSize = CGSizeMake(1, h);
        NSMutableArray *cells = [NSMutableArray array];
        struct { CGFloat birth, velocity, spread, scale, alpha; uint32_t tint; } depths[] = {
            {9, 7, 2, .12, .6, 0xFFFFFF}, {3.2, 20, 6, .19, .8, 0xDDE8F5}, {.9, 58, 16, .32, .95, NPSAccentText}};
        for (auto depth : depths) {
            CAEmitterCell *cell = [CAEmitterCell emitterCell];
            cell.contents = (__bridge id)NPSDot();
            cell.birthRate = depth.birth;
            cell.lifetime = (w + 40) / (depth.velocity - depth.spread);
            cell.velocity = depth.velocity;
            cell.velocityRange = depth.spread;
            cell.emissionLongitude = M_PI;
            cell.scale = depth.scale;
            cell.scaleRange = depth.scale * .4;
            cell.color = NPSCG(depth.tint, depth.alpha);
            cell.alphaRange = .35;
            [cells addObject:cell];
        }
        stars.emitterCells = cells;
        // Start full of stars rather than with an empty sky filling from one edge.
        stars.beginTime = CACurrentMediaTime() - (w + 40) / 5.0;
        [root addSublayer:stars];
    } else {
        for (int i = 0; i < 420; ++i) {
            CGFloat size = (arc4random_uniform(100) < 85 ? 1.2 : 2.2);
            CALayer *star = NPSLayer(CGRectMake(arc4random_uniform((uint32_t)w), arc4random_uniform((uint32_t)h),
                size, size), s);
            star.cornerRadius = size / 2;
            star.backgroundColor = NPSCG(0xFFFFFF, .25 + arc4random_uniform(50) / 100.0);
            [root addSublayer:star];
        }
    }
    [root addSublayer:NPSVignette(b, .6, s)];
    [root addSublayer:NPSGrain(b, s)];
}

// 极光: curtains of light, brightest at their lower edge and fading upwards,
// swaying slowly above a dark horizon.
static void NPSSceneAurora(CALayer *root, const NPSSceneOptions &o) {
    CGRect b = root.bounds;
    CGFloat w = b.size.width, h = b.size.height, s = o.scale, k = MIN(o.intensity, 1.6);
    root.backgroundColor = NPSCG(0x04070A);
    for (int i = 0; i < 90; ++i) {
        CGFloat size = arc4random_uniform(100) < 80 ? 1 : 1.8;
        CALayer *star = NPSLayer(CGRectMake(arc4random_uniform((uint32_t)w), arc4random_uniform((uint32_t)(h * .5)),
            size, size), s);
        star.cornerRadius = size / 2;
        star.backgroundColor = NPSCG(0xFFFFFF, .15 + arc4random_uniform(35) / 100.0);
        [root addSublayer:star];
    }
    CAGradientLayer *sky = NPSGlow(CGRectMake(0, 0, w * 1.4, h * .9), NPSAccent2, .08 * k, s);
    sky.position = CGPointMake(w * .5, h * .6);
    [root addSublayer:sky];
    struct { CGFloat x, width, height, base, alpha, angle, sway, period; uint32_t rgb; } curtains[] = {
        {.18, .30, .62, .64, .34, -.10, .05, 13, NPSOk},
        {.36, .24, .7, .6, .30, -.05, .06, 17, NPSAccent},
        {.52, .34, .58, .66, .36, .03, .05, 11, NPSOk},
        {.7, .26, .66, .62, .26, .08, .06, 19, NPSAccent2},
        {.86, .22, .5, .63, .22, .12, .07, 23, NPSAccent},
    };
    int index = 0;
    for (auto c : curtains) {
        CAGradientLayer *curtain = [CAGradientLayer layer];
        curtain.contentsScale = s;
        curtain.anchorPoint = CGPointMake(.5, 1);
        curtain.bounds = CGRectMake(0, 0, w * c.width, h * c.height);
        curtain.position = CGPointMake(w * c.x, h * c.base);
        CGFloat a = c.alpha * k;
        curtain.colors = @[(__bridge id)NPSCG(c.rgb, 0), (__bridge id)NPSCG(c.rgb, a * .22),
            (__bridge id)NPSCG(c.rgb, a * .6), (__bridge id)NPSCG(c.rgb, a), (__bridge id)NPSCG(c.rgb, 0)];
        curtain.locations = @[@0, @.42, @.78, @.93, @1];
        CAGradientLayer *sides = [CAGradientLayer layer];
        sides.frame = curtain.bounds;
        sides.startPoint = CGPointMake(0, .5);
        sides.endPoint = CGPointMake(1, .5);
        sides.colors = @[(__bridge id)NPSCG(0, 0), (__bridge id)NPSCG(0, 1), (__bridge id)NPSCG(0, 1),
            (__bridge id)NPSCG(0, 0)];
        sides.locations = @[@0, @.35, @.65, @1];
        curtain.mask = sides;
        curtain.transform = CATransform3DMakeRotation(c.angle, 0, 0, 1);
        curtain.compositingFilter = @"screenBlendMode";
        [root addSublayer:curtain];
        if (o.motion) {
            NPSDrift(curtain, @[NPSPoint(b, c.x, c.base), NPSPoint(b, c.x + c.sway, c.base - .015),
                NPSPoint(b, c.x - c.sway * .7, c.base + .01)], c.period, index * 5);
            NPSBreathe(curtain, @"transform.scale.y", @.78, @1.16, c.period * .42, index * 3);
            NPSBreathe(curtain, @"opacity", @1, @.5, c.period * .27, index * 2);
        }
        ++index;
    }
    // The ground: dark land under the sky, with the light's reflection at its edge.
    CAGradientLayer *ground = [CAGradientLayer layer];
    ground.frame = CGRectMake(0, h * .58, w, h * .42);
    ground.contentsScale = s;
    ground.colors = @[(__bridge id)NPSCG(0x020304, 0), (__bridge id)NPSCG(0x020304, .82),
        (__bridge id)NPSCG(0x020304, .97), (__bridge id)NPSCG(0x020304, 1)];
    ground.locations = @[@0, @.2, @.42, @1];
    [root addSublayer:ground];
    [root addSublayer:NPSVignette(b, .5, s)];
    [root addSublayer:NPSGrain(b, s)];
}

// 石墨: the time, large and quiet, with a hairline that fills once a minute.
static void NPSSceneGraphite(CALayer *root, const NPSSceneOptions &o) {
    CGRect b = root.bounds;
    CGFloat w = b.size.width, h = b.size.height, s = o.scale, k = o.intensity;
    CAGradientLayer *background = [CAGradientLayer layer];
    background.frame = b;
    background.contentsScale = s;
    background.colors = @[(__bridge id)NPSCG(0x0E1114), (__bridge id)NPSCG(0x07080A)];
    [root addSublayer:background];
    CGPoint center = CGPointMake(w / 2, h * .44);
    CAGradientLayer *halo = NPSGlow(CGRectMake(0, 0, w * .7, w * .42), NPSAccent, .06 * k, s);
    halo.position = center;
    [root addSublayer:halo];
    if (o.motion) {
        NPSBreathe(halo, @"opacity", @1, @.45, 5, 0);
        NPSBreathe(halo, @"transform.scale", @1, @1.12, 5, 0);
    }

    CGFloat size = MIN(168, MAX(96, w * .085));
    CATextLayer *clock = NPSText(@"00:00", NPSMono(size, NSFontWeightUltraLight), NPSFg, .94, -size * .02, s);
    clock.string = [[NSAttributedString alloc] initWithString:NPSClockText()
        attributes:[(NSAttributedString *)clock.string attributesAtIndex:0 effectiveRange:nullptr]];
    clock.position = center;
    clock.name = @"big-clock";
    [root addSublayer:clock];
    CATextLayer *date = NPSText(NPSDateText(), [NSFont systemFontOfSize:15 weight:NSFontWeightRegular],
        NPSFg2, 1, NPSChinese() ? 1 : 0, s);
    date.bounds = CGRectMake(0, 0, 420, date.bounds.size.height);
    date.position = CGPointMake(center.x, center.y + size * .5 + 26);
    date.name = @"big-date";
    [root addSublayer:date];

    const CGFloat track = 240;
    CGFloat lineY = center.y + size * .5 + 58;
    CALayer *base = NPSLayer(CGRectMake(center.x - track / 2, lineY, track, 1), s);
    base.backgroundColor = NPSCG(0xFFFFFF, .08);
    [root addSublayer:base];
    CAShapeLayer *seconds = [CAShapeLayer layer];
    seconds.frame = base.frame;
    seconds.contentsScale = s;
    CGMutablePathRef line = CGPathCreateMutable();
    CGPathMoveToPoint(line, nullptr, 0, .5);
    CGPathAddLineToPoint(line, nullptr, track, .5);
    seconds.path = line;
    CGPathRelease(line);
    seconds.strokeColor = NPSCG(NPSAccent);
    seconds.lineWidth = 1;
    seconds.shadowColor = NPSCG(NPSAccent);
    seconds.shadowOpacity = .9;
    seconds.shadowRadius = 3;
    seconds.shadowOffset = CGSizeZero;
    double now = [NSDate date].timeIntervalSince1970;
    double second = fmod(now, 60);
    seconds.strokeEnd = second / 60;
    if (o.motion) {
        CABasicAnimation *fill = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
        fill.fromValue = @0;
        fill.toValue = @1;
        fill.duration = 60;
        NPSAnimate(seconds, fill, @"fill", second);
    }
    [root addSublayer:seconds];
    CATextLayer *label = NPSText(@"PRIVACY ON", NPSMono(11, NSFontWeightMedium), NPSAccentText, .85, 1.6, s);
    label.position = CGPointMake(center.x + 8, lineY + 30);
    CALayer *led = NPSLed(s, o.motion);
    led.position = CGPointMake(center.x - label.bounds.size.width / 2 - 4, lineY + 30);
    [root addSublayer:led];
    [root addSublayer:label];
    [root addSublayer:NPSVignette(b, .45, s)];
    [root addSublayer:NPSGrain(b, s)];
}

static CATextLayer *NPSCornerClock(CGRect bounds, CGFloat scale) {
    CATextLayer *clock = NPSText(@"00:00", NPSMono(15, NSFontWeightRegular), NPSFg2, 1, .5, scale);
    clock.string = [[NSAttributedString alloc] initWithString:NPSClockText()
        attributes:[(NSAttributedString *)clock.string attributesAtIndex:0 effectiveRange:nullptr]];
    clock.position = CGPointMake(bounds.size.width - 32 - clock.bounds.size.width / 2, 32 + clock.bounds.size.height / 2);
    clock.name = @"corner-clock";
    return clock;
}

static bool NPSSceneKnown(NSString *scene) {
    return [@[@"nightline", @"deepfield", @"aurora", @"graphite", @"black"] containsObject:scene];
}

// Builds a scene, or with `scene` nil only the overlay (pill, clock, vignette)
// for a picture drawn underneath. The returned layer fills `bounds` and lays
// out from the top left: it is flipped for an unflipped host layer, and a
// flipped host (an NSView with isFlipped) must clear geometryFlipped.
static CALayer *NPSSceneBuild(NSString *scene, CGRect bounds, const NPSSceneOptions &options) {
    CALayer *root = NPSLayer(bounds, options.scale);
    root.geometryFlipped = YES;
    root.masksToBounds = YES;
    bool centred = false;
    if ([scene isEqualToString:@"nightline"]) { NPSSceneNightline(root, options); centred = true; }
    else if ([scene isEqualToString:@"deepfield"]) NPSSceneDeepfield(root, options);
    else if ([scene isEqualToString:@"aurora"]) NPSSceneAurora(root, options);
    else if ([scene isEqualToString:@"graphite"]) { NPSSceneGraphite(root, options); centred = true; }
    else if ([scene isEqualToString:@"black"]) root.backgroundColor = NPSCG(0);
    else [root addSublayer:NPSVignette(bounds, .5, options.scale)];
    if (options.brightness < .999) {
        CALayer *dim = NPSLayer(bounds, options.scale);
        dim.backgroundColor = NPSCG(0, 1 - MAX(.4, options.brightness));
        [root addSublayer:dim];
    }
    if (options.hint) [root addSublayer:NPSPill(bounds, !centred, options.scale, options.motion)];
    if (options.clock && ![scene isEqualToString:@"graphite"]) [root addSublayer:NPSCornerClock(bounds, options.scale)];
    return root;
}

static void NPSReplaceText(CATextLayer *layer, NSString *text) {
    NSAttributedString *string = layer.string;
    if ([string.string isEqualToString:text]) return;
    layer.string = [[NSAttributedString alloc] initWithString:text
        attributes:[string attributesAtIndex:0 effectiveRange:nullptr]];
}

// Updates the clocks of a built scene; cheap enough to call on every tick.
static void NPSSceneTick(CALayer *root) {
    NSString *now = NPSClockText();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *layer in root.sublayers) {
        if (![layer isKindOfClass:CATextLayer.class]) continue;
        if ([layer.name isEqualToString:@"big-clock"] || [layer.name isEqualToString:@"corner-clock"])
            NPSReplaceText((CATextLayer *)layer, now);
        else if ([layer.name isEqualToString:@"big-date"])
            NPSReplaceText((CATextLayer *)layer, NPSDateText());
    }
    [CATransaction commit];
}
