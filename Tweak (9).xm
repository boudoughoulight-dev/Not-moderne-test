// NotificationCenterLite 1.2.4 - centre de notifications 2 colonnes pour iPad 2 (iOS 9.3.5, armv7)
// Une colonne : cartes de notifications (verre sombre, icones d'applications)
// L'autre     : grande horloge + date
// Fond : le fond d'ecran (net, ou floute si l'option est activee dans Reglages > Centre de notifications).
// Plus de bouton Camera, plus de bande noire en bas.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// ---------- Reglages ----------
static NSString *const kPrefDomain = @"com.ncl.notificationcenterlite";
static const BOOL kBlockOriginal = YES;  // NO = ne bloque pas le centre de notifications d'origine

// ---------- Log ----------
static void NCLLog(NSString *s) {
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
        NSString *path = @"/var/mobile/NCL-log.txt";
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([a fileSize] > 150000) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) {
            [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (...) {}
}

// ---------- Preferences (lues a chaque ouverture, donc effet immediat) ----------
static void NCLPrefsSync(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefDomain);
}

static id NCLPref(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kPrefDomain);
    if (!v) return nil;
    return CFBridgingRelease(v);
}

static BOOL NCLPrefBool(NSString *key, BOOL def) {
    id v = NCLPref(key);
    return [v isKindOfClass:[NSNumber class]] ? [(NSNumber *)v boolValue] : def;
}

static CGFloat NCLPrefFloat(NSString *key, CGFloat def) {
    id v = NCLPref(key);
    return [v isKindOfClass:[NSNumber class]] ? (CGFloat)[(NSNumber *)v floatValue] : def;
}

static NSString *NCLPrefStr(NSString *key, NSString *def) {
    id v = NCLPref(key);
    return ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) ? (NSString *)v : def;
}

static BOOL NCLBlocking(void) {
    return kBlockOriginal && NCLPrefBool(@"enabled", YES);
}

// ---------- Geometrie / orientation ----------
static CGSize NCLPortraitSize(void) {
    CGRect b = [UIScreen mainScreen].bounds;
    @try {
        NSValue *v = [[UIScreen mainScreen] valueForKey:@"_referenceBounds"];
        if (v) b = [v CGRectValue];
    } @catch (...) {}
    CGFloat w = MIN(b.size.width, b.size.height);
    CGFloat h = MAX(b.size.width, b.size.height);
    return CGSizeMake(w, h);
}

static UIInterfaceOrientation NCLOrient(void) {
    return [UIApplication sharedApplication].statusBarOrientation;
}

static CGAffineTransform NCLTransform(UIInterfaceOrientation o) {
    switch (o) {
        case UIInterfaceOrientationPortraitUpsideDown: return CGAffineTransformMakeRotation(M_PI);
        case UIInterfaceOrientationLandscapeLeft:      return CGAffineTransformMakeRotation(-M_PI_2);
        case UIInterfaceOrientationLandscapeRight:     return CGAffineTransformMakeRotation(M_PI_2);
        default: return CGAffineTransformIdentity;
    }
}

// Composante "vers le bas de l'interface" d'un deplacement ecran
static CGFloat NCLDown(CGPoint p) {
    switch (NCLOrient()) {
        case UIInterfaceOrientationPortraitUpsideDown: return -p.y;
        case UIInterfaceOrientationLandscapeLeft:      return p.x;
        case UIInterfaceOrientationLandscapeRight:     return -p.x;
        default: return p.y;
    }
}

static CGFloat NCLClamp(CGFloat v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

// ---------- Images : utilitaires ----------
static double NCLMTime(NSString *p) {
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    NSDate *d = a[NSFileModificationDate];
    return d ? [d timeIntervalSince1970] : 0;
}

// Reduit une image trop grosse (photo de 12 Mpx = memoire explosee sur iPad 2)
static UIImage *NCLShrink(UIImage *img, CGFloat maxSide) {
    if (!img) return nil;
    CGSize s = img.size;
    CGFloat m = MAX(s.width, s.height);
    if (m <= maxSide || m <= 0) return img;
    CGFloat k = maxSide / m;
    CGSize ns = CGSizeMake(floor(s.width * k), floor(s.height * k));
    UIGraphicsBeginImageContextWithOptions(ns, YES, 1.0);
    [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    UIImage *o = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return o ? o : img;
}

// YES si l'image est (presque) toute noire -> rendu rate, on ne s'en sert pas
static BOOL NCLIsBlank(UIImage *img) {
    if (!img || !img.CGImage) return YES;
    uint8_t px[8 * 8 * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 8, 8, 8, 32, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) return NO;
    CGContextDrawImage(c, CGRectMake(0, 0, 8, 8), img.CGImage);
    CGContextRelease(c);
    int sum = 0;
    for (int i = 0; i < 64; i++) sum += px[i * 4] + px[i * 4 + 1] + px[i * 4 + 2];
    return sum < 64 * 3 * 6;
}

static UIImage *NCLRenderView(UIView *v) {
    @try {
        CGSize s = v.bounds.size;
        if (s.width < 8 || s.height < 8) return nil;
        UIGraphicsBeginImageContextWithOptions(s, YES, 1.0);
        CGContextRef c = UIGraphicsGetCurrentContext();
        if (!c) { UIGraphicsEndImageContext(); return nil; }
        [v.layer renderInContext:c];
        UIImage *i = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return i;
    } @catch (...) { UIGraphicsEndImageContext(); return nil; }
}

// ---------- Fond d'ecran ----------
static UIImage *gWall = nil;       // dernier fond charge (cache)
static NSString *gWallKey = nil;

typedef CFArrayRef (*NCLCPBitmapFn)(CFDataRef, void *, int, void *);
typedef CGImageRef (*NCLScreenFn)(void);

// Methode 1 : on demande la vue du fond d'ecran a SpringBoard et on la dessine
static UIImage *NCLWallpaperFromController(BOOL lock) {
    @try {
        Class cls = objc_getClass("SBWallpaperController");
        if (!cls) return nil;
        SEL si = NSSelectorFromString(@"sharedInstance");
        if (![cls respondsToSelector:si]) return nil;
        id ctl = ((id (*)(id, SEL))objc_msgSend)(cls, si);
        if (!ctl) return nil;
        NSArray *names = lock ? @[@"lockscreenWallpaperView", @"_lockscreenWallpaperView"]
                              : @[@"homescreenWallpaperView", @"_homescreenWallpaperView", @"sharedWallpaperView"];
        for (NSString *n in names) {
            SEL s = NSSelectorFromString(n);
            if (![ctl respondsToSelector:s]) continue;
            id v = ((id (*)(id, SEL))objc_msgSend)(ctl, s);
            if (![v isKindOfClass:[UIView class]]) continue;
            UIImage *img = NCLRenderView((UIView *)v);
            if (img && !NCLIsBlank(img)) return img;
        }
    } @catch (...) {}
    return nil;
}

// Methode 2 : lecture du fichier .cpbitmap ou iOS range le fond d'ecran
static UIImage *NCLLoadCPBitmap(NSString *path) {
    @try {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (d.length < 64) return nil;
        NCLCPBitmapFn fn = (NCLCPBitmapFn)dlsym(RTLD_DEFAULT, "CPBitmapCreateImagesFromData");
        if (!fn) {
            void *h = dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY);
            if (h) fn = (NCLCPBitmapFn)dlsym(h, "CPBitmapCreateImagesFromData");
        }
        if (!fn) return nil;
        CFArrayRef arr = fn((__bridge CFDataRef)d, NULL, 1, NULL);
        if (!arr) return nil;
        UIImage *img = nil;
        if (CFArrayGetCount(arr) > 0) {
            CGImageRef cg = (CGImageRef)CFArrayGetValueAtIndex(arr, 0);
            if (cg) img = [UIImage imageWithCGImage:cg];
        }
        CFRelease(arr);
        return (img && !NCLIsBlank(img)) ? img : nil;
    } @catch (...) { return nil; }
}

// Fond d'ecran "home", "lock" ou image perso (avec cache)
static UIImage *NCLWallpaperImage(NSString *src, NSString **how) {
    NSString *custom = NCLPrefStr(@"customPath", @"/var/mobile/Library/NCL/fond.jpg");
    NSString *homeP = @"/var/mobile/Library/SpringBoard/HomeBackground.cpbitmap";
    NSString *lockP = @"/var/mobile/Library/SpringBoard/LockBackground.cpbitmap";
    BOOL isCustom = [src isEqualToString:@"custom"];
    BOOL isLock = [src isEqualToString:@"lock"];
    NSString *probe = isCustom ? custom : (isLock ? lockP : homeP);
    NSString *key = [NSString stringWithFormat:@"%@|%@|%.0f", src, probe, NCLMTime(probe)];
    if (gWall && gWallKey && [gWallKey isEqualToString:key]) {
        if (how) *how = @"cache";
        return gWall;
    }
    UIImage *img = nil;
    NSString *h = nil;
    if (isCustom) {
        img = [UIImage imageWithContentsOfFile:custom];
        if (img) h = @"image perso";
    }
    if (!img) { img = NCLWallpaperFromController(isLock); if (img) h = @"SBWallpaperController"; }
    if (!img) { img = NCLLoadCPBitmap(isLock ? lockP : homeP); if (img) h = @"cpbitmap"; }
    if (!img) {
        NSString *tp = isLock ? @"/var/mobile/Library/SpringBoard/LockBackgroundThumbnail.jpg"
                              : @"/var/mobile/Library/SpringBoard/HomeBackgroundThumbnail.jpg";
        UIImage *t = [UIImage imageWithContentsOfFile:tp];
        if (t && !NCLIsBlank(t)) { img = t; h = @"miniature"; }
    }
    if (!img) return nil;
    img = NCLShrink(img, 1280);
    gWall = img;
    gWallKey = key;
    if (how) *how = h;
    return img;
}

// Methode 3 : capture de l'ecran tel qu'il est (net, sans flou)
static UIImage *NCLSnapshotWindows(CGSize ps) {
    @try {
        UIGraphicsBeginImageContextWithOptions(ps, YES, 1.0);
        CGContextRef c = UIGraphicsGetCurrentContext();
        if (!c) { UIGraphicsEndImageContext(); return nil; }
        CGContextSetRGBFillColor(c, 0, 0, 0, 1);
        CGContextFillRect(c, CGRectMake(0, 0, ps.width, ps.height));
        NSArray *ws = [[[UIApplication sharedApplication] windows] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            CGFloat la = [(UIWindow *)a windowLevel], lb = [(UIWindow *)b windowLevel];
            return la < lb ? NSOrderedAscending : (la > lb ? NSOrderedDescending : NSOrderedSame);
        }];
        for (UIWindow *w in ws) {
            if (w.hidden || w.alpha < 0.01 || w.windowLevel >= 10001) continue; // on saute nos fenetres
            CGContextSaveGState(c);
            CGContextTranslateCTM(c, w.center.x, w.center.y);
            CGContextConcatCTM(c, w.transform);
            CGContextTranslateCTM(c, -w.bounds.size.width * w.layer.anchorPoint.x, -w.bounds.size.height * w.layer.anchorPoint.y);
            [w.layer renderInContext:c];
            CGContextRestoreGState(c);
        }
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    } @catch (...) { UIGraphicsEndImageContext(); return nil; }
}

static UIImage *NCLScreenShot(NSString **how) {
    @try {
        NCLScreenFn fn = (NCLScreenFn)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
        if (fn) {
            CGImageRef cg = fn();
            if (cg) {
                UIImage *img = [UIImage imageWithCGImage:cg];
                CGImageRelease(cg);
                if (img) { if (how) *how = @"UIGetScreenImage"; return img; }
            }
        }
        UIImage *s = NCLSnapshotWindows(NCLPortraitSize());
        if (s) { if (how) *how = @"fenetres SpringBoard"; return s; }
    } @catch (...) {}
    return nil;
}

// Methode 4 : degrade sombre (au pire on a un joli fond, jamais un ecran vide)
static UIImage *NCLFallbackGradient(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(128, 128), YES, 1.0);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8] = { 0.16, 0.24, 0.42, 1.0,   0.04, 0.06, 0.14, 1.0 };
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    if (c && g) CGContextDrawLinearGradient(c, g, CGPointMake(0, 0), CGPointMake(0, 128), (CGGradientDrawingOptions)0);
    if (g) CGGradientRelease(g);
    CGColorSpaceRelease(cs);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Renvoie l'image de fond. *isShot = YES si c'est une capture d'ecran (option "screen", avancee)
// Par defaut on n'utilise JAMAIS de capture : elle contenait l'horloge de l'ecran de verrouillage.
static UIImage *NCLBackgroundImage(NSString **how, BOOL *isShot) {
    *isShot = NO;
    NSString *src = NCLPrefStr(@"source", @"home");
    if ([src isEqualToString:@"screen"]) {
        UIImage *s = NCLScreenShot(how);
        if (s) { *isShot = YES; return s; }
        src = @"home";
    }
    NSString *alt = [src isEqualToString:@"lock"] ? @"home" : @"lock";
    NSArray *order = @[src, alt, @"custom"];
    for (NSString *k in order) {
        UIImage *w = NCLWallpaperImage(k, how);
        if (w) return w;
    }
    if (how) *how = @"degrade de secours";
    return NCLFallbackGradient();
}

// ---------- Icones ----------
static void NCLFillGradient(CGContextRef c, CGRect r, CGFloat r1, CGFloat g1, CGFloat b1, CGFloat r2, CGFloat g2, CGFloat b2) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8] = { r1, g1, b1, 1.0,   r2, g2, b2, 1.0 };
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    if (g) {
        CGContextDrawLinearGradient(c, g, CGPointMake(0, r.origin.y), CGPointMake(0, r.origin.y + r.size.height), (CGGradientDrawingOptions)0);
        CGGradientRelease(g);
    }
    CGColorSpaceRelease(cs);
}

static void NCLDrawText(NSString *t, CGRect r, CGFloat size, UIColor *col, BOOL bold) {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *at = @{ NSFontAttributeName: (bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size]),
                          NSForegroundColorAttributeName: col,
                          NSParagraphStyleAttributeName: ps };
    [t drawInRect:r withAttributes:at];
}

static UIColor *NCLColorFor(NSString *s) {
    NSArray *cols = @[
        [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1],
        [UIColor colorWithRed:0.04 green:0.52 blue:1.00 alpha:1],
        [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1],
        [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1],
        [UIColor colorWithRed:0.69 green:0.32 blue:0.87 alpha:1],
        [UIColor colorWithRed:0.35 green:0.78 blue:0.98 alpha:1]
    ];
    return cols[[s hash] % cols.count];
}

// Icone dessinee a la main (plan B si l'icone reelle de l'app n'est pas trouvee)
static UIImage *NCLFallbackIcon(NSString *sid, NSString *name, CGFloat s) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, 1.0);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(0, 0, s, s);
    [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:s * 0.225] addClip];
    UIColor *white = [UIColor whiteColor];

    if ([sid isEqualToString:@"com.apple.MobileSMS"]) {
        NCLFillGradient(c, r, 0.36, 0.92, 0.42, 0.10, 0.74, 0.25);
        [white setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(s * 0.17, s * 0.22, s * 0.66, s * 0.50)] fill];
        UIBezierPath *tail = [UIBezierPath bezierPath];
        [tail moveToPoint:CGPointMake(s * 0.28, s * 0.62)];
        [tail addLineToPoint:CGPointMake(s * 0.20, s * 0.80)];
        [tail addLineToPoint:CGPointMake(s * 0.42, s * 0.68)];
        [tail closePath];
        [tail fill];
    } else if ([sid isEqualToString:@"com.apple.mobilemail"]) {
        NCLFillGradient(c, r, 0.36, 0.78, 1.00, 0.04, 0.45, 0.95);
        [white setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(s * 0.17, s * 0.28, s * 0.66, s * 0.44) cornerRadius:s * 0.06] fill];
        UIBezierPath *v = [UIBezierPath bezierPath];
        [v moveToPoint:CGPointMake(s * 0.19, s * 0.33)];
        [v addLineToPoint:CGPointMake(s * 0.50, s * 0.56)];
        [v addLineToPoint:CGPointMake(s * 0.81, s * 0.33)];
        v.lineWidth = s * 0.035;
        v.lineJoinStyle = kCGLineJoinRound;
        [[UIColor colorWithRed:0.10 green:0.50 blue:0.95 alpha:1] setStroke];
        [v stroke];
    } else if ([sid isEqualToString:@"com.apple.mobilecal"]) {
        [white setFill];
        UIRectFill(r);
        NSDateFormatter *f1 = [[NSDateFormatter alloc] init];
        f1.locale = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
        f1.dateFormat = @"EEE";
        NSDateFormatter *f2 = [[NSDateFormatter alloc] init];
        f2.dateFormat = @"d";
        NCLDrawText([[f1 stringFromDate:[NSDate date]] capitalizedString], CGRectMake(0, s * 0.08, s, s * 0.2), s * 0.15,
                    [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1], YES);
        NCLDrawText([f2 stringFromDate:[NSDate date]], CGRectMake(0, s * 0.22, s, s * 0.7), s * 0.52,
                    [UIColor blackColor], NO);
    } else if ([sid isEqualToString:@"com.apple.AppStore"]) {
        NCLFillGradient(c, r, 0.30, 0.80, 1.00, 0.05, 0.40, 0.95);
        NCLDrawText(@"A", CGRectMake(0, s * 0.14, s, s * 0.8), s * 0.62, white, YES);
    } else if ([sid isEqualToString:@"com.apple.mobilesafari"]) {
        NCLFillGradient(c, r, 1.0, 1.0, 1.0, 0.86, 0.90, 0.97);
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(s * 0.14, s * 0.14, s * 0.72, s * 0.72)];
        ring.lineWidth = s * 0.055;
        [[UIColor colorWithRed:0.05 green:0.50 blue:0.98 alpha:1] setStroke];
        [ring stroke];
        UIBezierPath *red = [UIBezierPath bezierPath];
        [red moveToPoint:CGPointMake(s * 0.68, s * 0.32)];
        [red addLineToPoint:CGPointMake(s * 0.43, s * 0.43)];
        [red addLineToPoint:CGPointMake(s * 0.57, s * 0.57)];
        [red closePath];
        [[UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1] setFill];
        [red fill];
        UIBezierPath *gray = [UIBezierPath bezierPath];
        [gray moveToPoint:CGPointMake(s * 0.32, s * 0.68)];
        [gray addLineToPoint:CGPointMake(s * 0.43, s * 0.43)];
        [gray addLineToPoint:CGPointMake(s * 0.57, s * 0.57)];
        [gray closePath];
        [[UIColor colorWithWhite:0.55 alpha:1] setFill];
        [gray fill];
    } else {
        [NCLColorFor(name) setFill];
        UIRectFill(r);
        NSString *l = name.length ? [[name substringToIndex:1] uppercaseString] : @"?";
        NCLDrawText(l, CGRectMake(0, s * 0.16, s, s * 0.8), s * 0.55, white, YES);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// Vraie icone de l'application (via UIKit prive) sinon icone dessinee
static UIImage *NCLAppIcon(NSString *sid, NSString *name) {
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *k = sid.length ? sid : (name.length ? name : @"?");
    UIImage *c = cache[k];
    if (c) return c;
    UIImage *img = nil;
    @try {
        SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if (sid.length && [UIImage respondsToSelector:s]) {
            CGFloat sc = [UIScreen mainScreen].scale;
            int fmts[3] = { 2, 0, 1 };
            for (int i = 0; i < 3 && !img; i++) {
                id r = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], s, sid, fmts[i], sc);
                if ([r isKindOfClass:[UIImage class]]) img = (UIImage *)r;
            }
        }
    } @catch (...) { img = nil; }
    if (!img) img = NCLFallbackIcon(sid, name, 96);
    if (img) cache[k] = img;
    return img;
}

// ---------- Flou du fond d'ecran (reduction puis agrandissement progressifs, sans API privee) ----------
static UIImage *NCLStepDraw(UIImage *img, CGSize n) {
    UIGraphicsBeginImageContextWithOptions(n, YES, 1.0);
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (c) CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    [img drawInRect:CGRectMake(0, 0, n.width, n.height)];
    UIImage *o = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return o;
}

// amount : 0 (aucun flou) a 1 (tres flou)
static UIImage *NCLBlurImage(UIImage *img, CGFloat amount) {
    if (!img || amount < 0.02) return img;
    static UIImage *srcC = nil;
    static UIImage *outC = nil;
    static CGFloat amtC = -1;
    if (srcC == img && outC && fabs(amtC - amount) < 0.001) return outC;
    @try {
        CGSize full = img.size;
        CGFloat f = 1.0 / (2.0 + amount * 22.0);
        CGSize target = CGSizeMake(MAX(6, floor(full.width * f)), MAX(6, floor(full.height * f)));
        UIImage *cur = img;
        CGSize cs = full;
        while (cs.width > target.width * 1.01) {
            CGSize n = CGSizeMake(MAX(target.width, floor(cs.width / 2)), MAX(target.height, floor(cs.height / 2)));
            UIImage *o = NCLStepDraw(cur, n);
            if (!o) return img;
            cur = o; cs = n;
        }
        while (cs.width < full.width * 0.99) {
            CGSize n = CGSizeMake(MIN(full.width, floor(cs.width * 2)), MIN(full.height, floor(cs.height * 2)));
            UIImage *o = NCLStepDraw(cur, n);
            if (!o) return img;
            cur = o; cs = n;
        }
        srcC = img; outC = cur; amtC = amount;
        return cur;
    } @catch (...) { return img; }
}

// ---------- Donnees ----------
static NSMutableArray *gItems = nil;   // NSDictionary: title, message, app, sid, date
@class NCLPanel;
static NCLPanel *gPanel = nil;
static BOOL gPanActive = NO;   // un glissement sur notre zone declencheur est en cours

// Historique garde sur disque : il survit au respring (avant, le centre etait vide apres chaque respring)
static NSString *const kItemsDir = @"/var/mobile/Library/NCL";
static NSString *const kItemsPath = @"/var/mobile/Library/NCL/items.plist";

static void NCLSaveItems(void) {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:kItemsDir withIntermediateDirectories:YES attributes:nil error:nil];
        [(gItems ? gItems : [NSMutableArray array]) writeToFile:kItemsPath atomically:YES];
    } @catch (...) {}
}

static void NCLLoadItems(void) {
    @try {
        NSArray *saved = [NSArray arrayWithContentsOfFile:kItemsPath];
        NSMutableArray *merged = [NSMutableArray arrayWithArray:(gItems ? gItems : @[])];
        if ([saved isKindOfClass:[NSArray class]]) {
            for (id d in saved) {
                if ([d isKindOfClass:[NSDictionary class]] && [d[@"date"] isKindOfClass:[NSDate class]]) [merged addObject:d];
            }
        }
        while (merged.count > 40) [merged removeLastObject];
        gItems = merged;
    } @catch (...) {}
}

static NSString *NCLStr(id o, NSString *key) {
    @try {
        id v = [o valueForKey:key];
        if ([v isKindOfClass:[NSString class]]) return v;
    } @catch (...) {}
    return nil;
}

static NSString *NCLAppName(NSString *sid) {
    if (!sid.length) return @"Notification";
    NSDictionary *map = @{
        @"com.apple.MobileSMS": @"Messages",
        @"com.apple.mobilemail": @"Mail",
        @"com.apple.mobilecal": @"Calendrier",
        @"com.apple.AppStore": @"App Store",
        @"com.apple.mobilesafari": @"Safari",
        @"com.apple.facetime": @"FaceTime",
        @"com.apple.reminders": @"Rappels",
        @"com.apple.Preferences": @"Réglages",
        @"com.apple.mobilephone": @"Téléphone",
        @"com.apple.mobileslideshow": @"Photos",
        @"com.apple.camera": @"Caméra",
        @"com.apple.Music": @"Musique",
        @"com.apple.mobilenotes": @"Notes",
        @"com.apple.Maps": @"Plans",
        @"com.apple.weather": @"Météo",
        @"com.apple.gamecenter": @"Game Center",
        @"com.apple.MobileStore": @"iTunes Store"
    };
    NSString *n = map[sid];
    if (n) return n;
    NSString *last = [[sid componentsSeparatedByString:@"."] lastObject];
    return last.length ? [last capitalizedString] : sid;
}

static NSString *NCLAgo(NSDate *d) {
    NSTimeInterval t = -[d timeIntervalSinceNow];
    if (t < 60) return @"à l'instant";
    if (t < 3600) return [NSString stringWithFormat:@"il y a %d min", (int)(t / 60)];
    if (t < 86400) return [NSString stringWithFormat:@"il y a %d h", (int)(t / 3600)];
    return [NSString stringWithFormat:@"il y a %d j", (int)(t / 86400)];
}

static void NCLReloadPanel(void);

static void NCLAddBulletin(id b) {
    @try {
        if (!b) return;
        NSString *title = NCLStr(b, @"title");
        NSString *msg = NCLStr(b, @"message");
        NSString *sid = NCLStr(b, @"sectionID");
        NSDate *date = nil;
        @try { id d = [b valueForKey:@"date"]; if ([d isKindOfClass:[NSDate class]]) date = d; } @catch (...) {}
        if (!date) date = [NSDate date];
        if (!title.length && !msg.length) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (!gItems) gItems = [NSMutableArray array];
                NSDictionary *first = gItems.firstObject;
                if (first && [first[@"title"] isEqual:(title ?: @"")] && [first[@"message"] isEqual:(msg ?: @"")]
                    && fabs([first[@"date"] timeIntervalSinceDate:date]) < 2.0) {
                    return; // doublon (les deux methodes hookees peuvent se declencher)
                }
                NSDictionary *it = @{ @"title": title ?: @"", @"message": msg ?: @"",
                                      @"app": NCLAppName(sid), @"sid": sid ?: @"", @"date": date };
                [gItems insertObject:it atIndex:0];
                while (gItems.count > 40) [gItems removeLastObject];
                NCLLog([NSString stringWithFormat:@"notif: %@ / %@", it[@"app"], it[@"title"]]);
                NCLSaveItems();
                NCLReloadPanel();
            } @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"add exc %@", e]); }
        });
    } @catch (...) {}
}

// ---------- Carte de notification (verre sombre + vraie icone) ----------
static UIView *NCLMakeCard(NSDictionary *it, CGFloat w) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 80)];
    card.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.46];
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    card.clipsToBounds = YES;

    NSString *app = it[@"app"];
    NSString *sid = it[@"sid"];
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(14, 16, 48, 48)];
    icon.image = NCLAppIcon(sid, app);
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:icon];

    CGFloat tx = 76;
    UILabel *appL = [[UILabel alloc] initWithFrame:CGRectMake(tx, 11, w - tx - 112, 22)];
    appL.text = app;
    appL.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    appL.textColor = [UIColor whiteColor];
    [card addSubview:appL];

    UILabel *timeL = [[UILabel alloc] initWithFrame:CGRectMake(w - 112, 13, 100, 18)];
    timeL.text = NCLAgo(it[@"date"]);
    timeL.font = [UIFont systemFontOfSize:13];
    timeL.textColor = [UIColor colorWithWhite:1 alpha:0.62];
    timeL.textAlignment = NSTextAlignmentRight;
    [card addSubview:timeL];

    NSString *title = it[@"title"];
    NSString *msg = it[@"message"];
    NSString *body = msg;
    if (title.length && ![title isEqualToString:app]) {
        body = msg.length ? [NSString stringWithFormat:@"%@ : %@", title, msg] : title;
    }
    UILabel *ml = [[UILabel alloc] initWithFrame:CGRectMake(tx, 35, w - tx - 14, 38)];
    ml.text = body;
    ml.numberOfLines = 2;
    ml.lineBreakMode = NSLineBreakByTruncatingTail;
    ml.font = [UIFont systemFontOfSize:15];
    ml.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    [card addSubview:ml];
    return card;
}

// ---------- Panneau ----------
@interface NCLPanel : UIWindow
@property (nonatomic, strong) UIView *rotator;
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIView *wall;
@property (nonatomic, strong) UIImageView *bgImg;
@property (nonatomic, strong) UIView *tint;
@property (nonatomic, strong) UIView *closeZone;
@property (nonatomic, strong) UIView *grab;
@property (nonatomic, strong) UIButton *clearBtn;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) NSDateFormatter *timeFmt;
@property (nonatomic, strong) NSDateFormatter *dateFmt;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) CGFloat panelH;
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) CGFloat startP;
@property (nonatomic, assign) BOOL isOpen;
@property (nonatomic, assign) BOOL shotMode;
- (void)prepareLayout;
- (void)setProgress:(CGFloat)p;
- (void)beginShow;
- (void)applyBackdrop:(UIImage *)img screenshot:(BOOL)isShot;
- (void)openAnimated;
- (void)closeAnimated;
- (void)reload;
@end

@implementation NCLPanel

- (UIButton *)glassButton:(NSString *)title size:(CGFloat)fs radius:(CGFloat)rad {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:fs weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.46];
    b.layer.cornerRadius = rad;
    b.layer.borderWidth = 0.5;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    b.clipsToBounds = YES;
    return b;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.windowLevel = 10002;
    self.backgroundColor = [UIColor clearColor];
    self.hidden = YES;

    NSLocale *fr = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
    self.timeFmt = [[NSDateFormatter alloc] init];
    self.timeFmt.locale = fr;
    self.timeFmt.dateFormat = @"HH:mm";
    self.dateFmt = [[NSDateFormatter alloc] init];
    self.dateFmt.locale = fr;
    self.dateFmt.dateFormat = @"EEEE d MMMM";

    self.rotator = [[UIView alloc] initWithFrame:frame];
    self.rotator.backgroundColor = [UIColor clearColor];
    [self addSubview:self.rotator];

    self.dim = [[UIView alloc] init];
    self.dim.backgroundColor = [UIColor blackColor];
    self.dim.alpha = 0;
    [self.rotator addSubview:self.dim];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapClose)];
    [self.dim addGestureRecognizer:tap];

    self.content = [[UIView alloc] init];
    self.content.backgroundColor = [UIColor clearColor];
    self.content.clipsToBounds = YES;
    [self.rotator addSubview:self.content];

    // Fond : le fond d'ecran, net (aucun flou)
    self.wall = [[UIView alloc] init];
    self.wall.backgroundColor = [UIColor blackColor];
    self.wall.clipsToBounds = YES;
    [self.content addSubview:self.wall];
    self.bgImg = [[UIImageView alloc] init];
    self.bgImg.contentMode = UIViewContentModeScaleAspectFill;
    self.bgImg.clipsToBounds = YES;
    [self.wall addSubview:self.bgImg];
    self.tint = [[UIView alloc] init];
    self.tint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.15];
    self.tint.userInteractionEnabled = NO;
    [self.content addSubview:self.tint];

    // Zone "glisser vers le haut pour fermer" au-dessus de l'horloge
    self.closeZone = [[UIView alloc] init];
    self.closeZone.backgroundColor = [UIColor clearColor];
    UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(tapClose)];
    sw.direction = UISwipeGestureRecognizerDirectionUp;
    [self.closeZone addGestureRecognizer:sw];
    [self.content addSubview:self.closeZone];

    // Colonne notifications
    self.scroll = [[UIScrollView alloc] init];
    self.scroll.showsVerticalScrollIndicator = NO;
    self.scroll.alwaysBounceVertical = YES;
    [self.content addSubview:self.scroll];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = @"Aucune notification";
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    self.emptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    [self.content addSubview:self.emptyLabel];

    self.clearBtn = [self glassButton:@"Tout effacer" size:16 radius:20];
    [self.clearBtn addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
    [self.content addSubview:self.clearBtn];

    // Colonne horloge
    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.font = [UIFont systemFontOfSize:100 weight:UIFontWeightUltraLight];
    self.timeLabel.textColor = [UIColor whiteColor];
    self.timeLabel.adjustsFontSizeToFitWidth = YES;
    self.timeLabel.minimumScaleFactor = 0.5;
    self.timeLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.timeLabel.shadowOffset = CGSizeMake(0, 1);
    [self.content addSubview:self.timeLabel];

    self.dateLabel = [[UILabel alloc] init];
    self.dateLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightLight];
    self.dateLabel.textColor = [UIColor colorWithWhite:1 alpha:0.95];
    self.dateLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.dateLabel.shadowOffset = CGSizeMake(0, 1);
    [self.content addSubview:self.dateLabel];

    // Zone invisible tout en bas : glisser vers le haut (ou toucher) pour fermer. Rien de visible.
    self.grab = [[UIView alloc] init];
    self.grab.backgroundColor = [UIColor clearColor];
    [self.content addSubview:self.grab];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(barPan:)];
    [self.grab addGestureRecognizer:pan];
    UITapGestureRecognizer *barTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapClose)];
    [self.grab addGestureRecognizer:barTap];
    return self;
}

- (void)prepareLayout {
    CGSize ps = NCLPortraitSize();
    UIInterfaceOrientation o = NCLOrient();
    BOOL land = UIInterfaceOrientationIsLandscape(o);
    CGFloat rw = land ? ps.height : ps.width;
    CGFloat rh = land ? ps.width : ps.height;

    self.frame = CGRectMake(0, 0, ps.width, ps.height);
    self.rotator.transform = CGAffineTransformIdentity;
    self.rotator.bounds = CGRectMake(0, 0, rw, rh);
    self.rotator.center = CGPointMake(ps.width / 2, ps.height / 2);
    self.rotator.transform = NCLTransform(o);

    self.dim.frame = self.rotator.bounds;
    CGFloat H = rh;                  // plein ecran : le panneau descend jusqu'en bas
    self.panelH = H;
    CGFloat bodyH = H;               // plus de bande en bas

    BOOL notifsLeft = NCLPrefBool(@"notifsLeft", YES);
    CGFloat dimA = NCLPrefFloat(@"dim", 0.15);
    if (dimA < 0) dimA = 0;
    if (dimA > 0.7) dimA = 0.7;

    self.wall.frame = CGRectMake(0, 0, rw, H);
    self.tint.frame = self.wall.frame;
    self.tint.backgroundColor = [UIColor colorWithWhite:0 alpha:dimA];
    self.grab.frame = CGRectMake(0, H - 30, rw, 30);

    CGFloat m = 24;
    CGFloat colW = floor(rw / 2 - m * 1.5);
    CGFloat xN = notifsLeft ? m : rw / 2 + m / 2;
    CGFloat xC = notifsLeft ? rw / 2 + m / 2 : m;
    CGFloat top = 40;
    CGFloat clearH = 40;

    self.scroll.frame = CGRectMake(xN, top, colW, bodyH - top - clearH - 36 - 12);
    self.clearBtn.frame = CGRectMake(xN + (colW - 170) / 2, bodyH - 36 - clearH, 170, clearH);
    self.emptyLabel.frame = CGRectMake(xN, top + 20, colW, 30);

    self.timeLabel.font = [UIFont systemFontOfSize:(land ? 112 : 96) weight:UIFontWeightUltraLight];
    self.timeLabel.frame = CGRectMake(xC, top - 10, colW, 124);
    self.dateLabel.frame = CGRectMake(xC, top + 112, colW, 32);
    self.timeLabel.textAlignment = notifsLeft ? NSTextAlignmentRight : NSTextAlignmentLeft;
    self.dateLabel.textAlignment = notifsLeft ? NSTextAlignmentRight : NSTextAlignmentLeft;
    self.closeZone.frame = CGRectMake(xC, 0, colW, bodyH - 30);

    [self reload];
    [self setProgress:self.progress];
}

- (void)setProgress:(CGFloat)p {
    _progress = NCLClamp(p);
    self.content.frame = CGRectMake(0, -self.panelH * (1 - _progress), self.rotator.bounds.size.width, self.panelH);
    self.dim.alpha = 0.35 * _progress;
    // le fond reste fixe par rapport a l'ecran pendant que le panneau glisse
    self.bgImg.center = CGPointMake(self.rotator.bounds.size.width / 2,
                                    self.rotator.bounds.size.height / 2 - self.content.frame.origin.y);
}

// Place l'image de fond : fond d'ecran = remplit l'ecran ; capture = remise dans le bon sens
- (void)applyBackdrop:(UIImage *)img screenshot:(BOOL)isShot {
    self.bgImg.image = img;
    self.shotMode = isShot;
    self.bgImg.transform = CGAffineTransformIdentity;
    CGSize rb = self.rotator.bounds.size;
    if (!img) { self.bgImg.bounds = CGRectMake(0, 0, rb.width, rb.height); return; }
    if (!isShot) {
        self.bgImg.contentMode = UIViewContentModeScaleAspectFill;
        self.bgImg.bounds = CGRectMake(0, 0, rb.width, rb.height);
        return;
    }
    UIInterfaceOrientation o = NCLOrient();
    BOOL land = UIInterfaceOrientationIsLandscape(o);
    BOOL shotLand = img.size.width > img.size.height;
    BOOL rot = !shotLand;   // capture en portrait natif -> on la remet droite
    self.bgImg.contentMode = UIViewContentModeScaleToFill;
    self.bgImg.bounds = CGRectMake(0, 0, (rot && land) ? rb.height : rb.width, (rot && land) ? rb.width : rb.height);
    if (rot) self.bgImg.transform = CGAffineTransformInvert(NCLTransform(o));
}

- (void)updateClock {
    NSDate *now = [NSDate date];
    self.timeLabel.text = [self.timeFmt stringFromDate:now];
    self.dateLabel.text = [[self.dateFmt stringFromDate:now] capitalizedString];
}

- (void)reload {
    @try {
        for (UIView *v in [self.scroll.subviews copy]) [v removeFromSuperview];
        CGFloat w = self.scroll.bounds.size.width;
        CGFloat y = 0;
        for (NSDictionary *it in gItems) {
            UIView *c = NCLMakeCard(it, w);
            CGRect f = c.frame; f.origin.y = y; c.frame = f;
            [self.scroll addSubview:c];
            y += f.size.height + 10;
        }
        self.scroll.contentSize = CGSizeMake(w, y);
        self.emptyLabel.hidden = (gItems.count > 0);
        self.clearBtn.hidden = (gItems.count == 0);
    } @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"reload exc %@", e]); }
}

- (void)beginShow {
    self.progress = 0;
    NCLPrefsSync();
    UIImage *img = nil;
    BOOL isShot = NO;
    if (self.hidden) {
        NSString *how = nil;
        img = NCLBackgroundImage(&how, &isShot);
        NCLLog([NSString stringWithFormat:@"fond: %@ (%.0fx%.0f)", how ? how : @"?", img.size.width, img.size.height]);
        if (img && NCLPrefBool(@"blur", NO)) {
            CGFloat amt = NCLPrefFloat(@"blurAmount", 0.5);
            img = NCLBlurImage(img, amt);
            NCLLog([NSString stringWithFormat:@"flou: %.2f", amt]);
        }
    } else {
        img = self.bgImg.image;
        isShot = self.shotMode;
    }
    [self prepareLayout];
    [self applyBackdrop:img screenshot:isShot];
    [self setProgress:0];
    [self updateClock];
    self.hidden = NO;
    if (!self.timer) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateClock) userInfo:nil repeats:YES];
    }
}

- (void)openAnimated {
    [UIView animateWithDuration:0.25 delay:0 options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{ [self setProgress:1]; }
                     completion:^(BOOL f) { self.isOpen = YES; }];
}

- (void)closeAnimated {
    [UIView animateWithDuration:0.22 delay:0 options:(UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState)
                     animations:^{ [self setProgress:0]; }
                     completion:^(BOOL f) {
        if (self.progress <= 0.01) {
            self.isOpen = NO;
            self.hidden = YES;
            [self.timer invalidate];
            self.timer = nil;
        }
    }];
}

- (void)tapClose { [self closeAnimated]; }

- (void)clearAll {
    [gItems removeAllObjects];
    NCLSaveItems();
    [self reload];
}

- (void)barPan:(UIPanGestureRecognizer *)g {
    CGFloat ty = [g translationInView:self.rotator].y;
    CGFloat vy = [g velocityInView:self.rotator].y;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.startP = self.progress;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        [self setProgress:self.startP + ty / self.panelH];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.progress < 0.8 || vy < -300) [self closeAnimated]; else [self openAnimated];
    }
}
@end

static void NCLReloadPanel(void) {
    if (gPanel && !gPanel.hidden) [gPanel reload];
}

// Ouverture complete (utilisee quand iOS essaie d'ouvrir SON centre de notifications)
static void NCLPresentFromSystem(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gPanel || !gPanel.hidden || gPanel.isOpen || gPanActive) return;
            NCLLog(@"ouverture via le geste systeme");
            [gPanel beginShow];
            [gPanel openAnimated];
        } @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"present exc %@", e]); }
    });
}

// ---------- Fenetre declencheur (bord haut de l'ecran) ----------
@interface NCLTrigger : UIWindow
- (void)updateFrame;
@end

@implementation NCLTrigger
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.windowLevel = 10001;
    self.backgroundColor = [UIColor clearColor];
    UIView *v = [[UIView alloc] initWithFrame:self.bounds];
    v.backgroundColor = [UIColor clearColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:v];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [v addGestureRecognizer:pan];
    self.hidden = NO;
    return self;
}

- (void)updateFrame {
    CGSize ps = NCLPortraitSize();
    CGFloat t = 28;
    CGRect f;
    switch (NCLOrient()) {
        case UIInterfaceOrientationPortraitUpsideDown: f = CGRectMake(0, ps.height - t, ps.width, t); break;
        case UIInterfaceOrientationLandscapeLeft:      f = CGRectMake(0, 0, t, ps.height); break;
        case UIInterfaceOrientationLandscapeRight:     f = CGRectMake(ps.width - t, 0, t, ps.height); break;
        default:                                       f = CGRectMake(0, 0, ps.width, t); break;
    }
    self.windowLevel = 10001;
    self.frame = f;
    self.hidden = NO;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!gPanel) return;
    @try {
        CGFloat d = NCLDown([g translationInView:g.view]);
        CGFloat vd = NCLDown([g velocityInView:g.view]);
        if (g.state == UIGestureRecognizerStateBegan) {
            NCLPrefsSync();
            // Le panneau est deja ouvert (ou en train de s'ouvrir via le geste systeme) : on ne le remet pas a zero
            if (!gPanel.hidden || gPanel.isOpen) { gPanActive = NO; return; }
            gPanActive = NCLPrefBool(@"enabled", YES);
            if (!gPanActive) return;
            NCLLog(@"geste: debut");
            [gPanel beginShow];
        } else if (!gPanActive) {
            return;
        } else if (g.state == UIGestureRecognizerStateChanged) {
            [gPanel setProgress:d / gPanel.panelH];
        } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
            gPanActive = NO;
            NCLLog([NSString stringWithFormat:@"geste: fin (progression %.2f)", gPanel.progress]);
            if (gPanel.progress > 0.25 || vd > 450) [gPanel openAnimated]; else [gPanel closeAnimated];
        }
    } @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"pan exc %@", e]); }
}
@end

static NCLTrigger *gTrigger = nil;

// Diagnostic : ecrit dans NCL-log.txt les noms de methodes interessants d'une classe iOS
static void NCLDumpMethods(const char *cls, NSArray *keywords) {
    @try {
        Class c = objc_getClass(cls);
        if (!c) { NCLLog([NSString stringWithFormat:@"classe %s absente", cls]); return; }
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned int i = 0; i < n && names.count < 40; i++) {
            NSString *nm = NSStringFromSelector(method_getName(ms[i]));
            NSString *l = [nm lowercaseString];
            for (NSString *k in keywords) {
                if ([l rangeOfString:k].location != NSNotFound) { [names addObject:nm]; break; }
            }
        }
        if (ms) free(ms);
        NCLLog([NSString stringWithFormat:@"%s: %@", cls, [names componentsJoinedByString:@", "]]);
    } @catch (...) {}
}

// Le centre d'origine peut s'ouvrir par d'autres methodes que celles hookees ci-dessus (ecran d'accueil :
// la 1re glissade ouvrait le centre normal). On detourne donc, au demarrage, toutes les methodes
// "geste d'ouverture" / "present..." de la classe qui ne renvoient rien et ont peu d'arguments.
static NSMutableDictionary *gOrigIMPs = nil;

static void NCLGenericShow(id self, SEL _cmd, id a, id b) {
    if (NCLBlocking()) { NCLPresentFromSystem(); return; }
    NSValue *v = gOrigIMPs[NSStringFromSelector(_cmd)];
    if (v) ((void (*)(id, SEL, id, id))[v pointerValue])(self, _cmd, a, b);
}

static void NCLHookExtraMethods(void) {
    @try {
        Class c = objc_getClass("SBNotificationCenterController");
        if (!c) return;
        if (!gOrigIMPs) gOrigIMPs = [NSMutableDictionary dictionary];
        NSSet *skip = [NSSet setWithObjects:@"handleShowNotificationCenterSystemGesture:", @"presentAnimated:", @"presentAnimated:completion:", nil];
        NSArray *avoid = @[@"dismiss", @"hide", @"did", @"will", @"finish", @"complet", @"cancel"];
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        NSMutableArray *hooked = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++) {
            Method m = ms[i];
            NSString *nm = NSStringFromSelector(method_getName(m));
            NSString *l = [nm lowercaseString];
            if ([skip containsObject:nm]) continue;
            BOOL showGesture = ([l rangeOfString:@"show"].location != NSNotFound && [l rangeOfString:@"gesture"].location != NSNotFound);
            BOOL present = [l hasPrefix:@"present"];
            if (!showGesture && !present) continue;
            BOOL bad = NO;
            for (NSString *w in avoid) { if ([l rangeOfString:w].location != NSNotFound) { bad = YES; break; } }
            if (bad) continue;
            unsigned int na = method_getNumberOfArguments(m);
            if (na > 4) continue;
            char *rt = method_copyReturnType(m);
            BOOL isVoid = (rt && rt[0] == 'v');
            if (rt) free(rt);
            if (!isVoid) continue;
            BOOL okArgs = YES;
            for (unsigned int k = 2; k < na; k++) {
                char *at = method_copyArgumentType(m, k);
                char t = at ? at[0] : 0;
                if (at) free(at);
                if (!(t == '@' || t == 'c' || t == 'C' || t == 'B' || t == 'i' || t == 'I' || t == 's' || t == 'S' || t == 'l' || t == 'L')) okArgs = NO;
            }
            if (!okArgs) continue;
            IMP orig = method_setImplementation(m, (IMP)NCLGenericShow);
            gOrigIMPs[nm] = [NSValue valueWithPointer:(const void *)orig];
            [hooked addObject:nm];
        }
        if (ms) free(ms);
        NCLLog([NSString stringWithFormat:@"methodes detournees: %@", [hooked componentsJoinedByString:@", "]]);
    } @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"hook extra exc %@", e]); }
}

static void NCLSetup(void) {
    @try {
        if (gPanel) return;
        CGSize ps = NCLPortraitSize();
        gItems = gItems ?: [NSMutableArray array];
        NCLLoadItems();
        gPanel = [[NCLPanel alloc] initWithFrame:CGRectMake(0, 0, ps.width, ps.height)];
        gTrigger = [[NCLTrigger alloc] initWithFrame:CGRectMake(0, 0, ps.width, 28)];
        [gTrigger updateFrame];
        // On re-verifie le declencheur quand l'orientation change ou que SpringBoard redevient actif
        void (^refresh)(NSNotification *) = ^(NSNotification *n) { [gTrigger updateFrame]; };
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                                                          object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue] usingBlock:refresh];
        NCLLog(@"setup OK (v1.2.4)");
        NCLDumpMethods("SBNotificationCenterController", @[@"present", @"gesture", @"show", @"dismiss", @"hide"]);
        NCLDumpMethods("SBWallpaperController", @[@"wallpaperview", @"sharedinstance"]);
        NCLHookExtraMethods();
    } @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"setup exc %@", e]); }
}

// ---------- Hooks ----------
@interface SpringBoard : UIApplication @end
@interface BBServer : NSObject @end
@interface SBNotificationCenterController : NSObject @end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ NCLSetup(); });
}
%end

%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)dest alwaysToLockScreen:(BOOL)lock {
    NCLAddBulletin(bulletin);
    %orig;
}
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)dest {
    NCLAddBulletin(bulletin);
    %orig;
}
%end

// On neutralise le centre de notifications d'origine ; si iOS essaie quand meme de l'ouvrir
// (son geste a gagne la course), on ouvre le NOTRE a la place.
%hook SBNotificationCenterController
- (void)handleShowNotificationCenterSystemGesture:(id)g {
    if (!NCLBlocking()) { %orig; return; }
    // Avant : le geste etait simplement ignore -> sur l'ecran d'accueil, ou le geste du systeme gagne
    // presque toujours la course, rien ne s'ouvrait. Maintenant on ouvre notre panneau a la place.
    if (!gPanActive) NCLPresentFromSystem();
}
- (void)presentAnimated:(BOOL)animated {
    if (NCLBlocking()) { NCLPresentFromSystem(); return; }
    %orig;
}
- (void)presentAnimated:(BOOL)animated completion:(id)completion {
    if (NCLBlocking()) { NCLPresentFromSystem(); return; }
    %orig;
}
%end

%ctor {
    NCLLog(@"NotificationCenterLite charge");
}
