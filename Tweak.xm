// NotificationCenterLite — centre de notifications style iOS 18
// Cible : armv7, iOS 9.x, SpringBoard. Compilé avec -fobjc-arc.
// Geste : glisser vers le bas depuis le bord haut de l'écran (selon l'orientation).
// Portrait : horloge en haut, notifications dessous.
// Paysage : horloge à gauche, notifications à droite.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define NCL_LOG_PATH @"/var/mobile/NCL-log.txt"
#define NCL_TAG_BASE 1000

static void NCLLog(NSString *s) {
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:NCL_LOG_PATH];
        if (!h) {
            [line writeToFile:NCL_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (NSException *e) {}
}

@interface UIApplication (NCLPrivate)
- (BOOL)launchApplicationWithIdentifier:(id)identifier suspended:(BOOL)suspended;
@end

static id NCLSafeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static NSString *NCLString(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

// 1 = portrait, 2 = portrait inversé, 3 = paysage (bouton à droite), 4 = paysage (bouton à gauche)
static CGFloat NCLAngle(NSInteger o) {
    switch (o) {
        case 2: return M_PI;
        case 3: return M_PI_2;
        case 4: return -M_PI_2;
        default: return 0;
    }
}

// Direction physique correspondant à « haut » (kind 0) ou « gauche » (kind 1) de l'interface
static UISwipeGestureRecognizerDirection NCLPhys(NSInteger o, int kind) {
    if (kind == 0) {
        switch (o) {
            case 2: return UISwipeGestureRecognizerDirectionDown;
            case 3: return UISwipeGestureRecognizerDirectionRight;
            case 4: return UISwipeGestureRecognizerDirectionLeft;
            default: return UISwipeGestureRecognizerDirectionUp;
        }
    }
    switch (o) {
        case 2: return UISwipeGestureRecognizerDirectionRight;
        case 3: return UISwipeGestureRecognizerDirectionUp;
        case 4: return UISwipeGestureRecognizerDirectionDown;
        default: return UISwipeGestureRecognizerDirectionLeft;
    }
}

// Déplacement « vers le bas de l'interface » à partir d'un déplacement physique
static CGFloat NCLDown(NSInteger o, CGPoint p) {
    switch (o) {
        case 2: return -p.y;
        case 3: return -p.x;
        case 4: return p.x;
        default: return p.y;
    }
}

#pragma mark - Modèle

@interface NCLItem : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, strong) NSDate *date;
@end
@implementation NCLItem
@end

#pragma mark - Contrôleur

@interface NCLController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *stripWindow;
@property (nonatomic, strong) UIWindow *panelWindow;
@property (nonatomic, strong) UIView *content;   // plein écran : voile + alpha
@property (nonatomic, strong) UIView *inner;     // tourné selon l'orientation
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, strong) NSMutableSet *seen;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL isOpen;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) NSInteger curOrient;
+ (instancetype)shared;
- (void)setup;
- (void)addBulletin:(id)bulletin;
@end

@implementation NCLController

+ (instancetype)shared {
    static NCLController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [NCLController new];
        c.items = [NSMutableArray array];
        c.seen = [NSMutableSet set];
        c.curOrient = 1;
    });
    return c;
}

// Taille de l'écran en portrait (fixe)
- (CGSize)portraitSize {
    CGSize b = [UIScreen mainScreen].bounds.size;
    return CGSizeMake(MIN(b.width, b.height), MAX(b.width, b.height));
}

- (NSInteger)orientation {
    @try {
        UIApplication *a = [UIApplication sharedApplication];
        SEL s = NSSelectorFromString(@"activeInterfaceOrientation");
        if ([a respondsToSelector:s]) {
            NSInteger (*f)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
            NSInteger o = f(a, s);
            if (o >= 1 && o <= 4) return o;
        }
        NSInteger o = (NSInteger)a.statusBarOrientation;
        if (o >= 1 && o <= 4) return o;
    } @catch (NSException *e) {}
    return 1;
}

- (BOOL)isLandscape { return self.curOrient == 3 || self.curOrient == 4; }

#pragma mark Mise en place

- (void)updateStrip {
    CGSize p = [self portraitSize];
    CGFloat W = p.width, H = p.height, t = 14;
    CGRect r;
    switch (self.curOrient) {
        case 2: r = CGRectMake(0, H - t, W, t); break;
        case 3: r = CGRectMake(W - t, 0, t, H); break;
        case 4: r = CGRectMake(0, 0, t, H); break;
        default: r = CGRectMake(0, 0, W, t); break;
    }
    self.stripWindow.frame = r;
    self.stripWindow.rootViewController.view.frame = self.stripWindow.bounds;
}

- (void)checkOrientation {
    @try {
        NSInteger o = [self orientation];
        if (o == self.curOrient) return;
        self.curOrient = o;
        [self updateStrip];
        if (self.panelWindow && !self.panelWindow.hidden) [self rebuild];
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"orientation exception: %@", e]);
    }
}

- (void)setup {
    if (self.ready) return;
    @try {
        CGSize sz = [self portraitSize];
        self.curOrient = [self orientation];

        UIWindow *pw = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, sz.width, sz.height)];
        pw.windowLevel = UIWindowLevelAlert + 100;
        pw.backgroundColor = [UIColor clearColor];
        UIViewController *pvc = [UIViewController new];
        pvc.view.backgroundColor = [UIColor clearColor];
        pw.rootViewController = pvc;
        pw.hidden = YES;
        self.panelWindow = pw;

        UIWindow *sw = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, sz.width, 14)];
        sw.windowLevel = UIWindowLevelAlert + 200;
        sw.backgroundColor = [UIColor colorWithWhite:0 alpha:0.02];
        UIViewController *svc = [UIViewController new];
        svc.view.backgroundColor = [UIColor clearColor];
        sw.rootViewController = svc;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [svc.view addGestureRecognizer:pan];
        sw.hidden = NO;
        self.stripWindow = sw;
        [self updateStrip];

        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(checkOrientation) userInfo:nil repeats:YES];

        self.ready = YES;
        NCLLog(@"setup OK");
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"setup exception: %@", e]);
    }
}

#pragma mark Notifications entrantes

- (void)addBulletin:(id)b {
    if (!b) return;
    @try {
        NSString *bid = NCLString(NCLSafeValue(b, @"sectionID")) ?: @"";
        NSString *title = NCLString(NCLSafeValue(b, @"title")) ?: @"";
        NSString *subtitle = NCLString(NCLSafeValue(b, @"subtitle")) ?: @"";
        NSString *msg = NCLString(NCLSafeValue(b, @"message")) ?: @"";
        NSDate *date = NCLSafeValue(b, @"date");
        if (![date isKindOfClass:[NSDate class]]) date = [NSDate date];
        NSString *uid = NCLString(NCLSafeValue(b, @"bulletinID"));
        if (!uid) uid = [NSString stringWithFormat:@"%@|%@|%@", bid, title, msg];

        if (subtitle.length) msg = msg.length ? [subtitle stringByAppendingFormat:@"\n%@", msg] : subtitle;
        if (!title.length && !msg.length) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if ([self.seen containsObject:uid]) return;
                [self.seen addObject:uid];
                NCLItem *it = [NCLItem new];
                it.bundleID = bid;
                it.appName = [self appNameForBundle:bid];
                it.title = title;
                it.message = msg;
                it.date = date;
                [self.items insertObject:it atIndex:0];
                while (self.items.count > 30) [self.items removeLastObject];
                if (self.isOpen) [self rebuild];
            } @catch (NSException *e) {
                NCLLog([NSString stringWithFormat:@"add exception: %@", e]);
            }
        });
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"addBulletin exception: %@", e]);
    }
}

- (NSString *)appNameForBundle:(NSString *)bid {
    NSString *fallback = [[bid componentsSeparatedByString:@"."] lastObject] ?: @"";
    @try {
        Class cls = objc_getClass("SBApplicationController");
        id ctrl = cls ? [cls performSelector:@selector(sharedInstance)] : nil;
        id app = nil;
        SEL s1 = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        SEL s2 = NSSelectorFromString(@"applicationWithDisplayIdentifier:");
        if (ctrl && [ctrl respondsToSelector:s1]) app = [ctrl performSelector:s1 withObject:bid];
        else if (ctrl && [ctrl respondsToSelector:s2]) app = [ctrl performSelector:s2 withObject:bid];
        NSString *n = NCLString(NCLSafeValue(app, @"displayName"));
        if (n.length) return n;
    } @catch (NSException *e) {}
    return fallback;
}

#pragma mark Geste

- (void)handlePan:(UIPanGestureRecognizer *)g {
    @try {
        CGFloat d = NCLDown(self.curOrient, [g translationInView:g.view]);
        CGFloat p = MAX(0, MIN(1, d / 220.0));
        if (g.state == UIGestureRecognizerStateBegan) {
            if (!self.isOpen) [self prepareOpen];
        } else if (g.state == UIGestureRecognizerStateChanged) {
            [self applyProgress:p];
        } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
            CGFloat vy = NCLDown(self.curOrient, [g velocityInView:g.view]);
            if (p > 0.35 || vy > 500) [self finishOpen];
            else [self closeAnimated:YES];
        }
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"pan exception: %@", e]);
    }
}

- (void)applyProgress:(CGFloat)p {
    self.progress = p;
    self.content.alpha = p;
    CGAffineTransform r = CGAffineTransformMakeRotation(NCLAngle(self.curOrient));
    self.inner.transform = CGAffineTransformTranslate(r, 0, -(1 - p) * 60);
}

- (void)prepareOpen {
    self.progress = 0;
    [self rebuild];
    self.panelWindow.hidden = NO;
}

- (void)finishOpen {
    self.isOpen = YES;
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        [self applyProgress:1];
    } completion:nil];
}

- (void)closeAnimated:(BOOL)anim {
    self.isOpen = NO;
    void (^done)(void) = ^{
        self.panelWindow.hidden = YES;
        for (UIView *v in [self.panelWindow.rootViewController.view.subviews copy]) [v removeFromSuperview];
        self.content = nil;
        self.inner = nil;
        self.scroll = nil;
        self.progress = 0;
    };
    if (!anim) { done(); return; }
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        [self applyProgress:0];
    } completion:^(BOOL f) { done(); }];
}

- (void)swipeUp:(UISwipeGestureRecognizer *)g { [self closeAnimated:YES]; }
- (void)tapBackground:(UITapGestureRecognizer *)g { [self closeAnimated:YES]; }

- (void)clearAll {
    [self.items removeAllObjects];
    [self rebuild];
}

- (void)openApp:(UITapGestureRecognizer *)g {
    @try {
        NSInteger idx = g.view.tag - NCL_TAG_BASE;
        if (idx < 0 || idx >= (NSInteger)self.items.count) return;
        NCLItem *it = self.items[idx];
        [self closeAnimated:YES];
        if (it.bundleID.length) {
            UIApplication *app = [UIApplication sharedApplication];
            if ([app respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
                [app launchApplicationWithIdentifier:it.bundleID suspended:NO];
            }
        }
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"openApp exception: %@", e]);
    }
}

- (void)deleteItem:(UISwipeGestureRecognizer *)g {
    @try {
        NSInteger idx = g.view.tag - NCL_TAG_BASE;
        if (idx < 0 || idx >= (NSInteger)self.items.count) return;
        [UIView animateWithDuration:0.2 animations:^{
            g.view.alpha = 0;
            g.view.transform = CGAffineTransformMakeTranslation(-120, 0);
        } completion:^(BOOL f) {
            if (idx < (NSInteger)self.items.count) [self.items removeObjectAtIndex:idx];
            [self rebuild];
        }];
    } @catch (NSException *e) {}
}

#pragma mark Construction de l'interface

- (UIImage *)iconForBundle:(NSString *)bid {
    if (!bid.length) return nil;
    @try {
        Class c = [UIImage class];
        SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([c respondsToSelector:s]) {
            UIImage *(*f)(id, SEL, id, int, CGFloat) = (UIImage *(*)(id, SEL, id, int, CGFloat))objc_msgSend;
            return f(c, s, bid, 0, [UIScreen mainScreen].scale);
        }
    } @catch (NSException *e) {}
    return nil;
}

- (NSString *)relativeTime:(NSDate *)d {
    NSTimeInterval t = -[d timeIntervalSinceNow];
    if (t < 60) return @"maintenant";
    if (t < 3600) return [NSString stringWithFormat:@"%d min", (int)(t / 60)];
    if (t < 86400) return [NSString stringWithFormat:@"%d h", (int)(t / 3600)];
    return [NSString stringWithFormat:@"%d j", (int)(t / 86400)];
}

- (UIView *)cardForItem:(NCLItem *)it index:(NSInteger)idx width:(CGFloat)w y:(CGFloat)y {
    CGFloat pad = 14, iconS = 36, textX = pad + iconS + 12;
    CGFloat textW = w - textX - pad;

    UIFont *tf = [UIFont boldSystemFontOfSize:16];
    UIFont *mf = [UIFont systemFontOfSize:15];
    UIFont *af = [UIFont systemFontOfSize:12];

    CGFloat titleH = it.title.length ? ceil([it.title boundingRectWithSize:CGSizeMake(textW - 60, 22)
        options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: tf} context:nil].size.height) : 0;
    CGFloat msgH = 0;
    if (it.message.length) {
        CGFloat full = ceil([it.message boundingRectWithSize:CGSizeMake(textW, 1000)
            options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName: mf} context:nil].size.height);
        msgH = MIN(full, ceil(mf.lineHeight * 3));
    }
    CGFloat h = MAX(70, pad + 16 + 2 + titleH + 2 + msgH + pad);

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, y, w, h)];
    card.tag = NCL_TAG_BASE + idx;
    card.layer.cornerRadius = 22;
    card.layer.masksToBounds = YES;

    UIView *bg = nil;
    @try {
        UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleExtraLight];
        UIVisualEffectView *ev = [[UIVisualEffectView alloc] initWithEffect:eff];
        ev.frame = card.bounds;
        ev.alpha = 0.88;
        bg = ev;
    } @catch (NSException *e) {}
    if (!bg) {
        bg = [[UIView alloc] initWithFrame:card.bounds];
        bg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.75];
    }
    bg.userInteractionEnabled = NO;
    [card addSubview:bg];

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(pad, pad, iconS, iconS)];
    icon.layer.cornerRadius = 8;
    icon.layer.masksToBounds = YES;
    icon.contentMode = UIViewContentModeScaleAspectFill;
    UIImage *img = [self iconForBundle:it.bundleID];
    if (img) {
        icon.image = img;
    } else {
        icon.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1];
        UILabel *l = [[UILabel alloc] initWithFrame:icon.bounds];
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont boldSystemFontOfSize:18];
        l.text = it.appName.length ? [[it.appName substringToIndex:1] uppercaseString] : @"?";
        [icon addSubview:l];
    }
    [card addSubview:icon];

    UILabel *app = [[UILabel alloc] initWithFrame:CGRectMake(textX, pad, textW - 60, 16)];
    app.font = af;
    app.textColor = [UIColor colorWithWhite:0.25 alpha:0.9];
    app.text = [it.appName uppercaseString];
    [card addSubview:app];

    UILabel *time = [[UILabel alloc] initWithFrame:CGRectMake(w - pad - 60, pad, 60, 16)];
    time.font = af;
    time.textAlignment = NSTextAlignmentRight;
    time.textColor = [UIColor colorWithWhite:0.35 alpha:0.9];
    time.text = [self relativeTime:it.date];
    [card addSubview:time];

    CGFloat cy = pad + 18;
    if (titleH > 0) {
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(textX, cy, textW, titleH)];
        t.font = tf;
        t.textColor = [UIColor blackColor];
        t.text = it.title;
        [card addSubview:t];
        cy += titleH + 2;
    }
    if (msgH > 0) {
        UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(textX, cy, textW, msgH)];
        m.font = mf;
        m.numberOfLines = 3;
        m.lineBreakMode = NSLineBreakByTruncatingTail;
        m.textColor = [UIColor colorWithWhite:0.1 alpha:1];
        m.text = it.message;
        [card addSubview:m];
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openApp:)];
    [card addGestureRecognizer:tap];
    UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(deleteItem:)];
    sw.direction = NCLPhys(self.curOrient, 1);
    [card addGestureRecognizer:sw];
    return card;
}

- (void)shadow:(UIView *)v radius:(CGFloat)r {
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = 0.45;
    v.layer.shadowRadius = r;
    v.layer.shadowOffset = CGSizeMake(0, 1);
}

- (void)rebuild {
    @try {
        UIView *root = self.panelWindow.rootViewController.view;
        CGSize ps = [self portraitSize];
        root.frame = CGRectMake(0, 0, ps.width, ps.height);
        for (UIView *v in [root.subviews copy]) [v removeFromSuperview];

        BOOL land = [self isLandscape];
        CGFloat OW = land ? ps.height : ps.width;   // taille dans le repère de l'interface
        CGFloat OH = land ? ps.width : ps.height;

        UIView *content = [[UIView alloc] initWithFrame:root.bounds];
        content.backgroundColor = [UIColor clearColor];
        [root addSubview:content];
        self.content = content;

        // Léger voile dégradé : le fond d'écran reste bien visible
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.frame = content.bounds;
        grad.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.12].CGColor,
                        (id)[UIColor colorWithWhite:0 alpha:0.30].CGColor];
        [content.layer addSublayer:grad];

        UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapBackground:)];
        bgTap.delegate = self;
        [content addGestureRecognizer:bgTap];
        UISwipeGestureRecognizer *up = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipeUp:)];
        up.direction = NCLPhys(self.curOrient, 0);
        [content addGestureRecognizer:up];

        UIView *inner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, OW, OH)];
        inner.backgroundColor = [UIColor clearColor];
        inner.center = CGPointMake(ps.width / 2, ps.height / 2);
        [content addSubview:inner];
        self.inner = inner;

        NSDateFormatter *tfm = [NSDateFormatter new];
        tfm.dateFormat = @"HH:mm";
        NSDateFormatter *dfm = [NSDateFormatter new];
        dfm.locale = [NSLocale currentLocale];
        dfm.dateFormat = @"EEEE d MMMM";
        NSString *timeStr = [tfm stringFromDate:[NSDate date]];
        NSString *dateStr = [dfm stringFromDate:[NSDate date]];

        BOOL hasItems = self.items.count > 0;
        CGFloat listX, listW, listTop, listBottom;

        if (!land) {
            // ----- Portrait : horloge en haut, notifications dessous
            listW = MIN(OW - 40, 620);
            CGFloat x = (OW - listW) / 2;
            listX = x;

            UILabel *clock = [[UILabel alloc] initWithFrame:CGRectMake(x, 40, listW, 96)];
            clock.font = [UIFont fontWithName:@"HelveticaNeue-UltraLight" size:88] ?: [UIFont systemFontOfSize:88];
            clock.textColor = [UIColor whiteColor];
            clock.textAlignment = NSTextAlignmentCenter;
            clock.text = timeStr;
            [self shadow:clock radius:6];
            [inner addSubview:clock];

            UILabel *date = [[UILabel alloc] initWithFrame:CGRectMake(x, 134, listW, 26)];
            date.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
            date.textColor = [UIColor whiteColor];
            date.textAlignment = NSTextAlignmentCenter;
            date.text = dateStr;
            [self shadow:date radius:4];
            [inner addSubview:date];

            listTop = 184;
            if (hasItems) {
                [inner addSubview:[self clearButtonAt:CGRectMake(x + listW - 130, 172, 130, 34)]];
                listTop = 220;
            }
            listBottom = OH - 24;
        } else {
            // ----- Paysage : horloge à gauche, notifications à droite
            CGFloat leftW = floor(OW * 0.40);
            UILabel *clock = [[UILabel alloc] initWithFrame:CGRectMake(20, OH / 2 - 90, leftW, 96)];
            clock.font = [UIFont fontWithName:@"HelveticaNeue-UltraLight" size:88] ?: [UIFont systemFontOfSize:88];
            clock.textColor = [UIColor whiteColor];
            clock.textAlignment = NSTextAlignmentCenter;
            clock.adjustsFontSizeToFitWidth = YES;
            clock.text = timeStr;
            [self shadow:clock radius:6];
            [inner addSubview:clock];

            UILabel *date = [[UILabel alloc] initWithFrame:CGRectMake(20, OH / 2 + 8, leftW, 26)];
            date.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
            date.textColor = [UIColor whiteColor];
            date.textAlignment = NSTextAlignmentCenter;
            date.text = dateStr;
            [self shadow:date radius:4];
            [inner addSubview:date];

            if (hasItems) {
                [inner addSubview:[self clearButtonAt:CGRectMake(20 + (leftW - 130) / 2, OH / 2 + 50, 130, 34)]];
            }
            listX = 20 + leftW + 20;
            listW = OW - listX - 24;
            listTop = 24;
            listBottom = OH - 24;
        }

        UIScrollView *sc = [[UIScrollView alloc] initWithFrame:CGRectMake(listX, listTop, listW, listBottom - listTop)];
        sc.showsVerticalScrollIndicator = NO;
        sc.alwaysBounceVertical = YES;
        [inner addSubview:sc];
        self.scroll = sc;

        CGFloat y = 0;
        if (!hasItems) {
            UILabel *none = [[UILabel alloc] initWithFrame:CGRectMake(0, land ? OH / 2 - 40 : 10, listW, 30)];
            none.text = @"Aucune notification";
            none.textAlignment = NSTextAlignmentCenter;
            none.textColor = [UIColor whiteColor];
            none.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
            [self shadow:none radius:4];
            [sc addSubview:none];
        }
        for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
            UIView *card = [self cardForItem:self.items[i] index:i width:listW y:y];
            [sc addSubview:card];
            y += card.frame.size.height + 10;
        }
        sc.contentSize = CGSizeMake(listW, MAX(y, sc.bounds.size.height + 1));

        [self applyProgress:self.progress];
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"rebuild exception: %@", e]);
    }
}

- (UIButton *)clearButtonAt:(CGRect)f {
    UIButton *clear = [UIButton buttonWithType:UIButtonTypeCustom];
    clear.frame = f;
    clear.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
    clear.layer.cornerRadius = f.size.height / 2;
    clear.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [clear setTitle:@"Tout effacer" forState:UIControlStateNormal];
    [clear setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
    return clear;
}

// Le tap « fond » ne se déclenche que sur le fond, pas sur les cartes ni les boutons
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return (t.view == self.content || t.view == self.inner);
}

@end

#pragma mark - Hooks

@interface SpringBoard : UIApplication
@end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    NCLLog(@"SpringBoard lancé");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { [[NCLController shared] setup]; }
        @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"setup hook exception: %@", e]); }
    });
}

%end

%hook BBServer

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations alwaysToLockScreen:(BOOL)lock {
    %orig;
    @try { [[NCLController shared] addBulletin:bulletin]; }
    @catch (NSException *e) {}
}

%end

%ctor {
    NCLLog(@"dylib chargée");
}
