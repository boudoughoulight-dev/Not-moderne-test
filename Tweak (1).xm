// NotificationCenterLite - Tweak.xm
// Centre de notifications translucide pour iOS 9 (armv7, iPad 2).
// Le fond d'ecran reste visible : on cache le fond natif et on affiche
// nos propres cartes (verre sombre arrondi) + tuiles luminosite/volume.
//
// Compilation : Theos + Logos, ARC (-fobjc-arc), -fno-modules.
// Regles suivies pour compiler sur la chaine Linux + SDK 10.3 :
//  - aucune classe privee n'est referencee directement (NSClassFromString / %hook seulement)
//  - les CGRect sont lus par KVC + getValue: (pas de objc_msgSend_stret)
//  - pas de C++ (code Objective-C pur, meme dans un .xm)

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// REGLAGES (mettre 0 ou 1)
// ---------------------------------------------------------------------------
#define NCL_SHOW_SLIDERS     1   // 1 = tuiles luminosite + volume, 0 = sans
#define NCL_USE_BLUR         1   // 1 = flou (plus joli, plus lourd), 0 = verre sombre simple
#define NCL_DEMO_WHEN_EMPTY  1   // 1 = 5 cartes d'exemple tant qu'il n'y a aucune vraie notification
#define NCL_MAX_ITEMS        30
#define NCL_TAG              7731

static NSString *const kNCLLogPath = @"/var/mobile/NCL-log.txt";

// ---------------------------------------------------------------------------
// Declarations privees (jamais utilisees comme symboles de classe)
// ---------------------------------------------------------------------------
@interface SBNotificationCenterViewController : UIViewController
@end

@interface BBServer : NSObject
@end

@interface SBBrightnessController : NSObject
+ (id)sharedBrightnessController;
- (void)setBrightnessLevel:(float)level;
@end

@interface SBApplication : NSObject
- (NSString *)displayName;
@end

@interface SBApplicationController : NSObject
+ (id)sharedInstance;
- (id)applicationWithBundleIdentifier:(NSString *)bid;
@end

@interface UIImage (NCLPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)format scale:(CGFloat)scale;
@end

@interface UIApplication (NCLPrivate)
- (BOOL)launchApplicationWithIdentifier:(NSString *)ident suspended:(BOOL)suspended;
@end

// ---------------------------------------------------------------------------
// Etat global
// ---------------------------------------------------------------------------
@class NCLRoot;

static NSMutableArray *gItems = nil;      // notifications reelles (la plus recente en premier)
static BOOL gDemoDismissed = NO;          // YES apres « Tout effacer »
static char kNCLRootKey;
static __weak NCLRoot *gRoot = nil;

// ---------------------------------------------------------------------------
// Utilitaires
// ---------------------------------------------------------------------------
static void NCLLog(NSString *s) {
    NSLog(@"[NCL] %@", s);
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kNCLLogPath];
        if (!fh) {
            [line writeToFile:kNCLLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

// Lecture de bounds par KVC : evite objc_msgSend_stret sur armv7
static CGRect NCLBounds(UIView *v) {
    CGRect r = CGRectZero;
    @try {
        NSValue *nv = [v valueForKey:@"bounds"];
        if (nv) [nv getValue:&r];
    } @catch (NSException *e) {}
    return r;
}

static NSString *NCLAppName(NSString *sid) {
    if (sid.length == 0) return @"";
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"com.apple.MobileSMS": @"Messages",
                 @"com.apple.mobilemail": @"Mail",
                 @"com.apple.mobilecal": @"Calendrier",
                 @"com.apple.AppStore": @"App Store",
                 @"com.apple.mobilesafari": @"Safari",
                 @"com.apple.mobilephone": @"Téléphone",
                 @"com.apple.facetime": @"FaceTime",
                 @"com.apple.reminders": @"Rappels",
                 @"com.apple.Preferences": @"Réglages" };
    });
    NSString *n = [map objectForKey:sid];
    if (n) return n;
    @try {
        Class c = NSClassFromString(@"SBApplicationController");
        if (c && [c respondsToSelector:@selector(sharedInstance)]) {
            id ctl = [c sharedInstance];
            if ([ctl respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
                id app = [ctl applicationWithBundleIdentifier:sid];
                if (app && [app respondsToSelector:@selector(displayName)]) {
                    NSString *dn = [app displayName];
                    if (dn.length > 0) return dn;
                }
            }
        }
    } @catch (NSException *e) {}
    NSString *ext = [sid pathExtension];
    return ext.length > 0 ? ext : sid;
}

static NSString *NCLAgo(NSDate *d) {
    if (!d) return @"";
    long s = (long)(-[d timeIntervalSinceNow]);
    if (s < 60) return @"à l’instant";
    if (s < 3600) return [NSString stringWithFormat:@"il y a %ld min", s / 60];
    if (s < 86400) return [NSString stringWithFormat:@"il y a %ld h", s / 3600];
    return [NSString stringWithFormat:@"il y a %ld j", s / 86400];
}

static void NCLSetBrightness(float v) {
    @try {
        Class c = NSClassFromString(@"SBBrightnessController");
        if (c && [c respondsToSelector:@selector(sharedBrightnessController)]) {
            id ctl = [c sharedBrightnessController];
            if (ctl && [ctl respondsToSelector:@selector(setBrightnessLevel:)]) {
                [ctl setBrightnessLevel:v];
                return;
            }
        }
        [UIScreen mainScreen].brightness = v;
    } @catch (NSException *e) {}
}

static UILabel *NCLLabel(CGRect f, NSString *text, UIFont *font, UIColor *color, NSTextAlignment al) {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.backgroundColor = [UIColor clearColor];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.textAlignment = al;
    return l;
}

// Fond « verre » arrondi (flou si disponible)
static UIView *NCLGlass(CGRect frame, CGFloat radius) {
    UIView *g = nil;
#if NCL_USE_BLUR
    if (NSClassFromString(@"UIVisualEffectView")) {
        UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        UIVisualEffectView *ev = [[UIVisualEffectView alloc] initWithEffect:eff];
        ev.frame = frame;
        ev.contentView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
        g = ev;
    }
#endif
    if (!g) {
        g = [[UIView alloc] initWithFrame:frame];
        g.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.62];
    }
    g.layer.cornerRadius = radius;
    g.layer.masksToBounds = YES;
    g.layer.borderWidth = 0.5;
    g.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.18] CGColor];
    g.tag = NCL_TAG;
    return g;
}

// Vue dans laquelle ajouter les sous-vues d'un « verre »
static UIView *NCLContent(UIView *g) {
    if ([g isKindOfClass:[UIVisualEffectView class]]) {
        return ((UIVisualEffectView *)g).contentView;
    }
    return g;
}

static UIView *NCLIconView(NSString *sid, CGRect frame, NSString *fallbackName) {
    UIImageView *iv = [[UIImageView alloc] initWithFrame:frame];
    iv.layer.cornerRadius = 11.0;
    iv.layer.masksToBounds = YES;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    UIImage *img = nil;
    @try {
        if (sid.length > 0 && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
            img = [UIImage _applicationIconImageForBundleIdentifier:sid format:2 scale:[UIScreen mainScreen].scale];
        }
    } @catch (NSException *e) { img = nil; }
    if (img) {
        iv.image = img;
    } else {
        iv.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
        NSString *letter = fallbackName.length > 0 ? [[fallbackName substringToIndex:1] uppercaseString] : @"?";
        UILabel *l = NCLLabel(CGRectMake(0, 0, frame.size.width, frame.size.height), letter,
                              [UIFont boldSystemFontOfSize:22.0], [UIColor whiteColor], NSTextAlignmentCenter);
        [iv addSubview:l];
    }
    return iv;
}

static NSArray *NCLDemoItems(void) {
    NSDate *n = [NSDate date];
    return @[
        @{ @"sid": @"com.apple.MobileSMS",   @"title": @"Messages",   @"msg": @"1 nouvelle notification",   @"date": [n dateByAddingTimeInterval:-60.0] },
        @{ @"sid": @"com.apple.mobilemail",  @"title": @"Mail",       @"msg": @"2 nouvelles notifications", @"date": [n dateByAddingTimeInterval:-180.0] },
        @{ @"sid": @"com.apple.mobilecal",   @"title": @"Calendrier", @"msg": @"Rappel : Réunion à 15h00",  @"date": [n dateByAddingTimeInterval:-300.0] },
        @{ @"sid": @"com.apple.AppStore",    @"title": @"App Store",  @"msg": @"Mise à jour disponible",    @"date": [n dateByAddingTimeInterval:-600.0] },
        @{ @"sid": @"com.apple.mobilesafari",@"title": @"Safari",     @"msg": @"Onglet enregistré",         @"date": [n dateByAddingTimeInterval:-720.0] }
    ];
}

// ---------------------------------------------------------------------------
// Actions (boutons, curseurs, taps)
// ---------------------------------------------------------------------------
@interface NCLActions : NSObject
+ (instancetype)shared;
- (void)brightness:(UISlider *)s;
- (void)clearAll;
- (void)cardTapped:(UITapGestureRecognizer *)g;
@end

// ---------------------------------------------------------------------------
// Vue racine ajoutee au centre de notifications
// ---------------------------------------------------------------------------
@interface NCLRoot : UIView
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, assign) CGFloat lastW;
@property (nonatomic, assign) BOOL building;
- (void)rebuild;
@end

#define NCL_CARD_H   72.0
#define NCL_GAP      8.0

static UIView *NCLCard(NSDictionary *it, CGFloat w, CGFloat y) {
    UIView *g = NCLGlass(CGRectMake(0, y, w, NCL_CARD_H), 20.0);
    UIView *c = NCLContent(g);

    NSString *sid = [it objectForKey:@"sid"];
    NSString *title = [it objectForKey:@"title"];
    NSString *msg = [it objectForKey:@"msg"];
    NSDate *date = [it objectForKey:@"date"];
    NSString *app = NCLAppName(sid);
    if (title.length == 0) title = app;

    [c addSubview:NCLIconView(sid, CGRectMake(14, 12, 48, 48), app)];
    [c addSubview:NCLLabel(CGRectMake(74, 10, w - 74 - 110, 24), title,
                           [UIFont boldSystemFontOfSize:17.0], [UIColor whiteColor], NSTextAlignmentLeft)];
    [c addSubview:NCLLabel(CGRectMake(w - 14 - 100, 12, 100, 20), NCLAgo(date),
                           [UIFont systemFontOfSize:13.0], [UIColor colorWithWhite:1.0 alpha:0.60], NSTextAlignmentRight)];
    [c addSubview:NCLLabel(CGRectMake(74, 38, w - 74 - 14, 24), msg,
                           [UIFont systemFontOfSize:16.0], [UIColor colorWithWhite:1.0 alpha:0.88], NSTextAlignmentLeft)];

    g.accessibilityIdentifier = sid;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[NCLActions shared]
                                                                          action:@selector(cardTapped:)];
    [g addGestureRecognizer:tap];
    return g;
}

@implementation NCLRoot

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _lastW = -1.0;

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.backgroundColor = [UIColor clearColor];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.delaysContentTouches = NO;
    [self addSubview:_scroll];
    return self;
}

// Les touches en dehors de nos cartes traversent la vue (le centre natif reste utilisable)
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *h = [super hitTest:point withEvent:event];
    return (h == self) ? nil : h;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = NCLBounds(self);
    if (!self.building && fabs(b.size.width - self.lastW) > 0.5) {
        [self rebuild];
    }
}

- (void)rebuild {
    if (self.building) return;
    self.building = YES;
    @try {
        for (UIView *s in [self.scroll.subviews copy]) {
            if (s.tag == NCL_TAG) [s removeFromSuperview];
        }

        CGRect b = NCLBounds(self);
        CGFloat W = b.size.width;
        CGFloat H = b.size.height;
        if (W < 80.0 || H < 80.0) return;
        self.lastW = W;

        BOOL wide = (W > 640.0);
        CGFloat colW = wide ? 440.0 : (W - 32.0);
        CGFloat x = wide ? (W - colW - 16.0) : 16.0;
        CGFloat top = 36.0;
        self.scroll.frame = CGRectMake(x, top, colW, H - top - 12.0);

        CGFloat y = 0.0;

#if NCL_SHOW_SLIDERS
        {
            CGFloat tw = (colW - 12.0) / 2.0;
            CGFloat th = 84.0;

            // Luminosite
            UIView *t1 = NCLGlass(CGRectMake(0, y, tw, th), 22.0);
            UIView *c1 = NCLContent(t1);
            [c1 addSubview:NCLLabel(CGRectMake(16, 8, 40, 30), @"\u2600\uFE0E",
                                    [UIFont systemFontOfSize:24.0], [UIColor whiteColor], NSTextAlignmentLeft)];
            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, 46, tw - 32, 28)];
            sl.minimumValue = 0.0;
            sl.maximumValue = 1.0;
            sl.value = (float)[UIScreen mainScreen].brightness;
            sl.minimumTrackTintColor = [UIColor whiteColor];
            sl.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.28];
            [sl addTarget:[NCLActions shared] action:@selector(brightness:) forControlEvents:UIControlEventValueChanged];
            [c1 addSubview:sl];
            [self.scroll addSubview:t1];

            // Volume (composant systeme)
            UIView *t2 = NCLGlass(CGRectMake(tw + 12.0, y, tw, th), 22.0);
            UIView *c2 = NCLContent(t2);
            [c2 addSubview:NCLLabel(CGRectMake(16, 8, 40, 30), @"\U0001F50A",
                                    [UIFont systemFontOfSize:22.0], [UIColor whiteColor], NSTextAlignmentLeft)];
            MPVolumeView *mv = [[MPVolumeView alloc] initWithFrame:CGRectMake(16, 46, tw - 32, 28)];
            mv.showsRouteButton = NO;
            mv.showsVolumeSlider = YES;
            mv.tintColor = [UIColor whiteColor];
            [c2 addSubview:mv];
            [self.scroll addSubview:t2];

            y += th + NCL_GAP;
        }
#endif

        NSArray *items = gItems ? [gItems copy] : @[];
#if NCL_DEMO_WHEN_EMPTY
        if (items.count == 0 && !gDemoDismissed) items = NCLDemoItems();
#endif

        if (items.count == 0) {
            UILabel *e = NCLLabel(CGRectMake(0, y + 24.0, colW, 30.0), @"Aucune notification",
                                  [UIFont systemFontOfSize:18.0], [UIColor colorWithWhite:1.0 alpha:0.75], NSTextAlignmentCenter);
            e.tag = NCL_TAG;
            [self.scroll addSubview:e];
            y += 70.0;
        } else {
            for (NSDictionary *it in items) {
                [self.scroll addSubview:NCLCard(it, colW, y)];
                y += NCL_CARD_H + NCL_GAP;
            }

            // Bouton « Tout effacer »
            y += 4.0;
            CGFloat bw = 200.0, bh = 46.0;
            UIView *g = NCLGlass(CGRectMake(floor((colW - bw) / 2.0), y, bw, bh), 23.0);
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(0, 0, bw, bh);
            [btn setTitle:@"Tout effacer" forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont systemFontOfSize:17.0];
            [btn addTarget:[NCLActions shared] action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
            [NCLContent(g) addSubview:btn];
            [self.scroll addSubview:g];
            y += bh + 16.0;
        }

        self.scroll.contentSize = CGSizeMake(colW, y);
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"ERREUR rebuild: %@", e]);
    } @finally {
        self.building = NO;
    }
}

@end

@implementation NCLActions

+ (instancetype)shared {
    static NCLActions *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NCLActions alloc] init]; });
    return s;
}

- (void)brightness:(UISlider *)s {
    NCLSetBrightness(s.value);
}

- (void)clearAll {
    gDemoDismissed = YES;
    [gItems removeAllObjects];
    [gRoot rebuild];
}

- (void)cardTapped:(UITapGestureRecognizer *)g {
    @try {
        NSString *sid = g.view.accessibilityIdentifier;
        if (sid.length == 0) return;
        UIApplication *app = [UIApplication sharedApplication];
        if ([app respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
            [app launchApplicationWithIdentifier:sid suspended:NO];
        }
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"ERREUR tap: %@", e]);
    }
}

@end

// ---------------------------------------------------------------------------
// Reception des vraies notifications (BulletinBoard)
// ---------------------------------------------------------------------------
static void NCLStoreBulletin(id b) {
    if (!b) return;
    NSString *sid = nil, *title = nil, *msg = nil, *bid = nil;
    NSDate *date = nil;
    @try {
        id v = [b valueForKey:@"sectionID"];
        if ([v isKindOfClass:[NSString class]]) sid = v;
        v = [b valueForKey:@"title"];
        if ([v isKindOfClass:[NSString class]]) title = v;
        v = [b valueForKey:@"message"];
        if ([v isKindOfClass:[NSString class]]) msg = v;
        v = [b valueForKey:@"bulletinID"];
        if ([v isKindOfClass:[NSString class]]) bid = v;
        v = [b valueForKey:@"date"];
        if ([v isKindOfClass:[NSDate class]]) date = v;
    } @catch (NSException *e) {
        return;
    }
    NSDictionary *it = @{ @"sid": sid ?: @"",
                          @"title": title ?: @"",
                          @"msg": msg ?: @"",
                          @"bid": bid ?: @"",
                          @"date": date ?: [NSDate date] };
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gItems) gItems = [NSMutableArray array];
            NSString *k = [it objectForKey:@"bid"];
            if (k.length > 0) {
                for (NSUInteger i = 0; i < gItems.count; i++) {
                    if ([[[gItems objectAtIndex:i] objectForKey:@"bid"] isEqualToString:k]) {
                        [gItems removeObjectAtIndex:i];
                        break;
                    }
                }
            }
            [gItems insertObject:it atIndex:0];
            while (gItems.count > NCL_MAX_ITEMS) [gItems removeLastObject];
            gDemoDismissed = YES;   // une vraie notification remplace les exemples
            NCLRoot *r = gRoot;
            if (r && r.window) [r rebuild];
        } @catch (NSException *e) {}
    });
}

// ---------------------------------------------------------------------------
// Installation de la vue dans le centre de notifications
// ---------------------------------------------------------------------------
static void NCLHideNative(UIView *host, UIView *keep) {
    for (UIView *s in [host.subviews copy]) {
        if (s == keep) continue;
        CGRect r = NCLBounds(s);
        // On cache les grandes vues natives (fond, contenu) ; les petites (poignee) restent
        if (r.size.height > 120.0 && r.size.width > 200.0) {
            s.hidden = YES;
        }
    }
}

static void NCLDumpSubviews(UIView *host) {
    NSMutableString *s = [NSMutableString stringWithString:@"sous-vues :"];
    for (UIView *v in host.subviews) {
        CGRect r = NCLBounds(v);
        [s appendFormat:@" [%@ %.0fx%.0f%@]", NSStringFromClass([v class]),
            (double)r.size.width, (double)r.size.height, v.hidden ? @" cache" : @""];
    }
    NCLLog(s);
}

static void NCLAttach(UIViewController *vc, BOOL rebuild) {
    UIView *host = vc.view;
    if (!host) return;

    NCLRoot *root = objc_getAssociatedObject(vc, &kNCLRootKey);
    if (!root) {
        root = [[NCLRoot alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(vc, &kNCLRootKey, root, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    gRoot = root;

    if (root.superview != host) {
        [root removeFromSuperview];
        [host addSubview:root];
    }
    [host bringSubviewToFront:root];
    host.backgroundColor = [UIColor clearColor];
    NCLHideNative(host, root);

    CGRect b = NCLBounds(host);
    root.frame = CGRectMake(0, 0, b.size.width, b.size.height);
    if (rebuild) [root rebuild];
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------
%hook SBNotificationCenterViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try {
        NCLAttach(self, YES);
        NCLDumpSubviews(self.view);
    } @catch (NSException *e) {
        NCLLog([NSString stringWithFormat:@"ERREUR viewWillAppear: %@", e]);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @try { NCLAttach(self, NO); } @catch (NSException *e) {}
}

- (void)viewDidLayoutSubviews {
    %orig;
    @try { NCLAttach(self, NO); } @catch (NSException *e) {}
}

%end

%hook BBServer

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations alwaysToLockScreen:(BOOL)lock {
    %orig;
    NCLStoreBulletin(bulletin);
}

%end

%ctor {
    @autoreleasepool {
        gItems = [NSMutableArray array];
        %init;   // indispensable : sans %init, aucun hook n'est installe
        NCLLog([NSString stringWithFormat:@"charge dans %@ | NotificationCenterViewController=%d BBServer=%d",
                [[NSBundle mainBundle] bundleIdentifier],
                objc_getClass("SBNotificationCenterViewController") != NULL ? 1 : 0,
                objc_getClass("BBServer") != NULL ? 1 : 0]);
    }
}
