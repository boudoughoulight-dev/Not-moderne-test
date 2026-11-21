// NotificationCenterLite - centre de notifications 2 colonnes pour iPad 2 (iOS 9.3.5, armv7)
// Gauche : notifications (cartes arrondies translucides) | Droite : horloge + date + Camera
// Fond d'ecran flou (UIVisualEffectView) + grosse bande noire en bas pour remonter.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------- Reglages ----------
static const BOOL kNotifsOnLeft = YES;   // NO = notifications a droite, horloge a gauche
static const BOOL kBlockOriginal = YES;  // NO = ne bloque pas le centre de notifications d'origine

// ---------- Log ----------
static void NCLLog(NSString *s) {
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
        NSString *path = @"/var/mobile/NCL-log.txt";
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

// ---------- Donnees ----------
static NSMutableArray *gItems = nil;   // NSDictionary: title, message, app, sid, date
@class NCLPanel;
static NCLPanel *gPanel = nil;

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
        @"com.apple.mobilephone": @"Téléphone"
    };
    NSString *n = map[sid];
    if (n) return n;
    NSString *last = [[sid componentsSeparatedByString:@"."] lastObject];
    return last.length ? [last capitalizedString] : sid;
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
                NCLReloadPanel();
            } @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"add exc %@", e]); }
        });
    } @catch (...) {}
}

// ---------- Carte de notification ----------
static UIView *NCLMakeCard(NSDictionary *it, CGFloat w, NSDateFormatter *tf) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 84)];
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    card.layer.cornerRadius = 16;
    card.clipsToBounds = YES;

    NSString *app = it[@"app"];
    UIView *icon = [[UIView alloc] initWithFrame:CGRectMake(12, 12, 28, 28)];
    icon.backgroundColor = NCLColorFor(app);
    icon.layer.cornerRadius = 7;
    UILabel *letter = [[UILabel alloc] initWithFrame:icon.bounds];
    letter.text = app.length ? [[app substringToIndex:1] uppercaseString] : @"?";
    letter.textColor = [UIColor whiteColor];
    letter.textAlignment = NSTextAlignmentCenter;
    letter.font = [UIFont boldSystemFontOfSize:15];
    [icon addSubview:letter];
    [card addSubview:icon];

    UILabel *appL = [[UILabel alloc] initWithFrame:CGRectMake(48, 10, w - 48 - 70, 16)];
    appL.text = [app uppercaseString];
    appL.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    appL.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    [card addSubview:appL];

    UILabel *timeL = [[UILabel alloc] initWithFrame:CGRectMake(w - 62, 10, 52, 16)];
    timeL.text = [tf stringFromDate:it[@"date"]];
    timeL.font = [UIFont systemFontOfSize:11];
    timeL.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    timeL.textAlignment = NSTextAlignmentRight;
    [card addSubview:timeL];

    NSString *title = [it[@"title"] length] ? it[@"title"] : app;
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(48, 28, w - 48 - 12, 18)];
    tl.text = title;
    tl.font = [UIFont boldSystemFontOfSize:14];
    tl.textColor = [UIColor whiteColor];
    [card addSubview:tl];

    UILabel *ml = [[UILabel alloc] initWithFrame:CGRectMake(48, 46, w - 48 - 12, 34)];
    ml.text = it[@"message"];
    ml.numberOfLines = 2;
    ml.font = [UIFont systemFontOfSize:13];
    ml.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    [card addSubview:ml];
    return card;
}

// ---------- Panneau ----------
@interface NCLPanel : UIWindow
@property (nonatomic, strong) UIView *rotator;
@property (nonatomic, strong) UIView *dim;
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *tint;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, strong) UILabel *header;
@property (nonatomic, strong) UIButton *clearBtn;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UIButton *camBtn;
@property (nonatomic, strong) NSDateFormatter *timeFmt;
@property (nonatomic, strong) NSDateFormatter *dateFmt;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) CGFloat panelH;
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) CGFloat startP;
@property (nonatomic, assign) BOOL isOpen;
- (void)prepareLayout;
- (void)setProgress:(CGFloat)p;
- (void)beginShow;
- (void)openAnimated;
- (void)closeAnimated;
- (void)reload;
@end

@implementation NCLPanel

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

    self.blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    [self.content addSubview:self.blur];
    self.tint = [[UIView alloc] init];
    self.tint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    [self.content addSubview:self.tint];

    // Colonne notifications
    self.header = [[UILabel alloc] init];
    self.header.text = @"Notifications";
    self.header.font = [UIFont boldSystemFontOfSize:22];
    self.header.textColor = [UIColor whiteColor];
    [self.content addSubview:self.header];

    self.clearBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.clearBtn setTitle:@"Tout effacer" forState:UIControlStateNormal];
    [self.clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.clearBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.clearBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    self.clearBtn.layer.cornerRadius = 13;
    [self.clearBtn addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
    [self.content addSubview:self.clearBtn];

    self.scroll = [[UIScrollView alloc] init];
    self.scroll.showsVerticalScrollIndicator = NO;
    self.scroll.alwaysBounceVertical = YES;
    [self.content addSubview:self.scroll];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = @"Aucune notification";
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:17];
    self.emptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    [self.content addSubview:self.emptyLabel];

    // Colonne horloge
    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.font = [UIFont systemFontOfSize:84 weight:UIFontWeightUltraLight];
    self.timeLabel.textColor = [UIColor whiteColor];
    self.timeLabel.textAlignment = NSTextAlignmentCenter;
    self.timeLabel.adjustsFontSizeToFitWidth = YES;
    [self.content addSubview:self.timeLabel];

    self.dateLabel = [[UILabel alloc] init];
    self.dateLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightLight];
    self.dateLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    self.dateLabel.textAlignment = NSTextAlignmentCenter;
    [self.content addSubview:self.dateLabel];

    self.camBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.camBtn setTitle:@"📷  Caméra" forState:UIControlStateNormal];
    [self.camBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.camBtn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    self.camBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    self.camBtn.layer.cornerRadius = 18;
    [self.camBtn addTarget:self action:@selector(openCamera) forControlEvents:UIControlEventTouchUpInside];
    [self.content addSubview:self.camBtn];

    // Grosse bande noire (poignee)
    self.bar = [[UIView alloc] init];
    self.bar.backgroundColor = [UIColor blackColor];
    [self.content addSubview:self.bar];
    self.handle = [[UIView alloc] init];
    self.handle.backgroundColor = [UIColor colorWithWhite:0.6 alpha:1];
    self.handle.layer.cornerRadius = 3;
    [self.bar addSubview:self.handle];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(barPan:)];
    [self.bar addGestureRecognizer:pan];
    UITapGestureRecognizer *barTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapClose)];
    [self.bar addGestureRecognizer:barTap];
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
    CGFloat H = MAX(380, MIN(rh * 0.6, 560));
    self.panelH = H;
    CGFloat barH = 40;
    CGFloat bodyH = H - barH;

    self.blur.frame = CGRectMake(0, 0, rw, bodyH);
    self.tint.frame = self.blur.frame;
    self.bar.frame = CGRectMake(0, bodyH, rw, barH);
    self.handle.frame = CGRectMake((rw - 48) / 2, (barH - 6) / 2, 48, 6);

    CGFloat colW = rw / 2 - 28;
    CGFloat xN = kNotifsOnLeft ? 20 : rw / 2 + 8;
    CGFloat xC = kNotifsOnLeft ? rw / 2 + 8 : 20;

    self.header.frame = CGRectMake(xN, 28, colW - 110, 30);
    self.clearBtn.frame = CGRectMake(xN + colW - 100, 30, 100, 26);
    self.scroll.frame = CGRectMake(xN, 68, colW, bodyH - 68 - 14);
    self.emptyLabel.frame = CGRectMake(xN, 68 + (bodyH - 68 - 14) / 2 - 15, colW, 30);

    self.timeLabel.frame = CGRectMake(xC, 44, colW, 96);
    self.dateLabel.frame = CGRectMake(xC, 142, colW, 28);
    self.camBtn.frame = CGRectMake(xC + 20, bodyH - 14 - 56, colW - 40, 56);

    [self reload];
    [self setProgress:self.progress];
}

- (void)setProgress:(CGFloat)p {
    _progress = NCLClamp(p);
    self.content.frame = CGRectMake(0, -self.panelH * (1 - _progress), self.rotator.bounds.size.width, self.panelH);
    self.dim.alpha = 0.35 * _progress;
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
            UIView *c = NCLMakeCard(it, w, self.timeFmt);
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
    [self prepareLayout];
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
    [self reload];
}

- (void)openCamera {
    [self closeAnimated];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            SEL s = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
            if ([app respondsToSelector:s]) {
                ((void (*)(id, SEL, id, BOOL))objc_msgSend)(app, s, @"com.apple.camera", NO);
            }
        } @catch (...) {}
    });
}

- (void)barPan:(UIPanGestureRecognizer *)g {
    CGFloat ty = [g translationInView:self.rotator].y;
    CGFloat vy = [g velocityInView:self.rotator].y;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.startP = self.progress;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        [self setProgress:self.startP + ty / self.panelH];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.progress < 0.75 || vy < -300) [self closeAnimated]; else [self openAnimated];
    }
}
@end

static void NCLReloadPanel(void) {
    if (gPanel && !gPanel.hidden) [gPanel reload];
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
    CGFloat t = 22;
    CGRect f;
    switch (NCLOrient()) {
        case UIInterfaceOrientationPortraitUpsideDown: f = CGRectMake(0, ps.height - t, ps.width, t); break;
        case UIInterfaceOrientationLandscapeLeft:      f = CGRectMake(0, 0, t, ps.height); break;
        case UIInterfaceOrientationLandscapeRight:     f = CGRectMake(ps.width - t, 0, t, ps.height); break;
        default:                                       f = CGRectMake(0, 0, ps.width, t); break;
    }
    self.frame = f;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!gPanel) return;
    @try {
        CGFloat d = NCLDown([g translationInView:g.view]);
        CGFloat vd = NCLDown([g velocityInView:g.view]);
        if (g.state == UIGestureRecognizerStateBegan) {
            [gPanel beginShow];
        } else if (g.state == UIGestureRecognizerStateChanged) {
            [gPanel setProgress:d / gPanel.panelH];
        } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
            if (gPanel.progress > 0.3 || vd > 500) [gPanel openAnimated]; else [gPanel closeAnimated];
        }
    } @catch (NSException *e) { NCLLog([NSString stringWithFormat:@"pan exc %@", e]); }
}
@end

static NCLTrigger *gTrigger = nil;

static void NCLSetup(void) {
    @try {
        if (gPanel) return;
        CGSize ps = NCLPortraitSize();
        gItems = gItems ?: [NSMutableArray array];
        gPanel = [[NCLPanel alloc] initWithFrame:CGRectMake(0, 0, ps.width, ps.height)];
        gTrigger = [[NCLTrigger alloc] initWithFrame:CGRectMake(0, 0, ps.width, 22)];
        [gTrigger updateFrame];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            [gTrigger updateFrame];
        }];
        NCLLog(@"setup OK");
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

// On neutralise le centre de notifications d'origine (sinon les deux s'ouvrent)
%hook SBNotificationCenterController
- (void)handleShowNotificationCenterSystemGesture:(id)g {
    if (!kBlockOriginal) %orig;
}
- (void)presentAnimated:(BOOL)animated {
    if (!kBlockOriginal) %orig;
}
- (void)presentAnimated:(BOOL)animated completion:(id)completion {
    if (!kBlockOriginal) %orig;
}
%end

%ctor {
    NCLLog(@"NotificationCenterLite charge");
}
