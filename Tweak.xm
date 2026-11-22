// MeteoWidget 2.1.0 - widgets style iOS 14 pour iOS 9 (SpringBoard, armv7)
// - jusqu'a 3 widgets sur la 1re page de l'ecran d'accueil (derriere les icones)
// - appui long sur une zone vide de la page : choisir un widget (Meteo, Horloge, Batterie, Date)
// - appui long sur un widget : mode edition comme les apps (ils tremblent, croix en haut a droite pour supprimer)
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kMWCity = @"Libreville";
static const double kMWLat = 0.4162;
static const double kMWLon = 9.4673;
static const CGFloat kMWSize = 170.0;
static const CGFloat kMWGap = 14.0;
static const CGFloat kMWTop = 56.0;
static const NSUInteger kMWMax = 3;
static NSString *const kMWDir = @"/var/mobile/Library/MeteoWidget";
static NSString *const kMWCache = @"/var/mobile/Library/MeteoWidget/cache.plist";
static NSString *const kMWTypesPath = @"/var/mobile/Library/MeteoWidget/widgets.plist";

@class MWWidgetView;
@class MWManager;

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isEditing;
- (void)setIsEditing:(BOOL)editing;
@end

static NSMutableArray *gWidgets = nil;      // MWWidgetView, l'ordre = les emplacements
static __weak UIView *gHost = nil;          // la liste d'icones qui porte les widgets
static NSInteger gHostIdx = -1;
static BOOL gEditing = NO;
static BOOL gSBEditAPI = NO;
static UIView *gPicker = nil;
static UILongPressGestureRecognizer *gLongPress = nil;
static MWManager *gMgr = nil;
static NSUInteger gTicks = 0;

// ---------- journal ----------
static void MWLog(NSString *s) {
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:kMWDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [kMWDir stringByAppendingPathComponent:@"log.txt"];
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([a fileSize] > 60000) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) { [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]; return; }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (...) {}
}

// ---------- types de widgets ----------
static NSArray *MWAllTypes(void) { return @[@"meteo", @"horloge", @"batterie", @"date"]; }

static NSString *MWTypeTitle(NSString *t) {
    if ([t isEqualToString:@"meteo"]) return @"☁️  Météo";
    if ([t isEqualToString:@"horloge"]) return @"🕐  Horloge";
    if ([t isEqualToString:@"batterie"]) return @"🔋  Batterie";
    if ([t isEqualToString:@"date"]) return @"📅  Date";
    return t;
}

static void MWSaveTypes(void) {
    @try {
        NSMutableArray *a = [NSMutableArray array];
        for (id w in gWidgets) [a addObject:[w valueForKey:@"type"]];
        [[NSFileManager defaultManager] createDirectoryAtPath:kMWDir withIntermediateDirectories:YES attributes:nil error:nil];
        [a writeToFile:kMWTypesPath atomically:YES];
    } @catch (...) {}
}

static NSArray *MWLoadTypes(void) {
    @try {
        NSArray *a = [NSArray arrayWithContentsOfFile:kMWTypesPath];
        if ([a isKindOfClass:[NSArray class]]) {
            NSMutableArray *ok = [NSMutableArray array];
            for (id t in a) {
                if ([t isKindOfClass:[NSString class]] && [MWAllTypes() containsObject:t] && ![ok containsObject:t] && ok.count < kMWMax) [ok addObject:t];
            }
            return ok;   // peut etre vide : l'utilisateur a tout supprime
        }
    } @catch (...) {}
    return @[@"meteo"];  // premiere utilisation
}

// ---------- codes meteo -> emoji + texte ----------
static NSString *MWEmoji(int code, BOOL day) {
    if (code == 0) return day ? @"☀️" : @"🌙";
    if (code == 1) return day ? @"🌤" : @"🌙";
    if (code == 2) return @"⛅️";
    if (code == 3) return @"☁️";
    if (code == 45 || code == 48) return @"🌫";
    if (code >= 51 && code <= 57) return @"🌦";
    if (code >= 61 && code <= 67) return @"🌧";
    if (code >= 71 && code <= 77) return @"❄️";
    if (code >= 80 && code <= 82) return @"🌧";
    if (code == 85 || code == 86) return @"❄️";
    if (code >= 95) return @"⛈";
    return @"🌡";
}

static NSString *MWText(int code) {
    if (code == 0) return @"Ciel dégagé";
    if (code == 1) return @"Plutôt dégagé";
    if (code == 2) return @"Peu nuageux";
    if (code == 3) return @"Couvert";
    if (code == 45 || code == 48) return @"Brouillard";
    if (code >= 51 && code <= 57) return @"Bruine";
    if (code >= 61 && code <= 67) return @"Pluie";
    if (code >= 71 && code <= 77) return @"Neige";
    if (code >= 80 && code <= 82) return @"Averses";
    if (code == 85 || code == 86) return @"Averses de neige";
    if (code >= 95) return @"Orage";
    return @"Météo";
}

static int MWCodeFromEnglish(NSString *d) {
    NSString *l = [d lowercaseString];
    if ([l rangeOfString:@"thunder"].location != NSNotFound) return 95;
    if ([l rangeOfString:@"snow"].location != NSNotFound) return 71;
    if ([l rangeOfString:@"shower"].location != NSNotFound) return 80;
    if ([l rangeOfString:@"drizzle"].location != NSNotFound) return 51;
    if ([l rangeOfString:@"rain"].location != NSNotFound) return 61;
    if ([l rangeOfString:@"fog"].location != NSNotFound || [l rangeOfString:@"mist"].location != NSNotFound) return 45;
    if ([l rangeOfString:@"overcast"].location != NSNotFound || [l rangeOfString:@"cloudy"].location != NSNotFound) {
        return [l rangeOfString:@"partly"].location != NSNotFound ? 2 : 3;
    }
    if ([l rangeOfString:@"clear"].location != NSNotFound || [l rangeOfString:@"sunny"].location != NSNotFound) return 0;
    return 2;
}

static NSNumber *MWNum(id x) {
    if ([x isKindOfClass:[NSNumber class]]) return x;
    if ([x isKindOfClass:[NSString class]]) return @([(NSString *)x doubleValue]);
    return nil;
}

// ---------- lecture de la reponse (Open-Meteo ou wttr.in) ----------
static NSDictionary *MWParse(NSData *data) {
    @try {
        id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) return nil;
        NSDictionary *root = j;
        NSMutableDictionary *out = [NSMutableDictionary dictionary];

        NSDictionary *cw = root[@"current_weather"];
        if ([cw isKindOfClass:[NSDictionary class]] && MWNum(cw[@"temperature"])) {
            out[@"temp"] = MWNum(cw[@"temperature"]);
            out[@"code"] = MWNum(cw[@"weathercode"]) ?: @0;
            out[@"day"] = MWNum(cw[@"is_day"]) ?: @1;
            NSDictionary *daily = root[@"daily"];
            if ([daily isKindOfClass:[NSDictionary class]]) {
                NSArray *mx = daily[@"temperature_2m_max"];
                NSArray *mn = daily[@"temperature_2m_min"];
                if ([mx isKindOfClass:[NSArray class]] && mx.count && MWNum(mx[0])) out[@"max"] = MWNum(mx[0]);
                if ([mn isKindOfClass:[NSArray class]] && mn.count && MWNum(mn[0])) out[@"min"] = MWNum(mn[0]);
            }
            return out;
        }

        NSArray *cc = root[@"current_condition"];
        if ([cc isKindOfClass:[NSArray class]] && cc.count && [cc[0] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *c = cc[0];
            if (!MWNum(c[@"temp_C"])) return nil;
            out[@"temp"] = MWNum(c[@"temp_C"]);
            NSArray *wd = c[@"weatherDesc"];
            NSString *desc = @"";
            if ([wd isKindOfClass:[NSArray class]] && wd.count && [wd[0] isKindOfClass:[NSDictionary class]]) desc = wd[0][@"value"] ?: @"";
            out[@"code"] = @(MWCodeFromEnglish(desc));
            NSInteger hr = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
            out[@"day"] = @((hr >= 6 && hr < 19) ? 1 : 0);
            NSArray *w = root[@"weather"];
            if ([w isKindOfClass:[NSArray class]] && w.count && [w[0] isKindOfClass:[NSDictionary class]]) {
                if (MWNum(w[0][@"maxtempC"])) out[@"max"] = MWNum(w[0][@"maxtempC"]);
                if (MWNum(w[0][@"mintempC"])) out[@"min"] = MWNum(w[0][@"mintempC"]);
            }
            return out;
        }
    } @catch (...) {}
    return nil;
}

// ---------- le widget ----------
static UIColor *MWC(CGFloat r, CGFloat g, CGFloat b) { return [UIColor colorWithRed:r green:g blue:b alpha:0.96]; }

@interface MWWidgetView : UIView
@property (nonatomic, copy) NSString *type;
@property (nonatomic, strong) UILabel *cityLabel;
@property (nonatomic, strong) UILabel *tempLabel;
@property (nonatomic, strong) UILabel *iconLabel;
@property (nonatomic, strong) UILabel *condLabel;
@property (nonatomic, strong) UILabel *hiloLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) CAGradientLayer *grad;
@property (nonatomic, strong) UIButton *delButton;
@property (nonatomic, strong) CAShapeLayer *ringTrack;
@property (nonatomic, strong) CAShapeLayer *ringProgress;
- (instancetype)initWithType:(NSString *)type;
- (void)applyInfo:(NSDictionary *)info stale:(BOOL)stale;
- (void)showStatus:(NSString *)s;
- (void)refresh;
- (void)prime;
- (void)setEditing:(BOOL)e;
@end

static void MWFetch(NSUInteger idx, NSString *lastErr);

@interface MWManager : NSObject <UIGestureRecognizerDelegate>
- (void)hostLongPress:(UILongPressGestureRecognizer *)g;
- (void)widgetLongPress:(UILongPressGestureRecognizer *)g;
- (void)widgetTap:(UITapGestureRecognizer *)g;
- (void)deleteTapped:(UIButton *)b;
- (void)pickTapped:(UIButton *)b;
- (void)dismissPicker;
- (void)tick:(NSTimer *)t;
- (void)battChanged;
@end

static void MWEnterEditing(void);
static void MWExitEditing(void);

@implementation MWWidgetView

- (UILabel *)makeLabel:(CGRect)f font:(UIFont *)font {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.backgroundColor = [UIColor clearColor];
    l.font = font;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7;
    [self addSubview:l];
    return l;
}

- (instancetype)initWithType:(NSString *)type {
    self = [super initWithFrame:CGRectMake(0, 0, kMWSize, kMWSize)];
    if (!self) return nil;
    self.type = type;
    self.userInteractionEnabled = YES;
    self.layer.cornerRadius = 22.0;
    self.layer.masksToBounds = YES;

    self.grad = [CAGradientLayer layer];
    self.grad.frame = CGRectMake(0, 0, kMWSize, kMWSize);
    [self.layer insertSublayer:self.grad atIndex:0];

    self.cityLabel = [self makeLabel:CGRectMake(14, 12, 142, 20) font:[UIFont boldSystemFontOfSize:15]];
    self.tempLabel = [self makeLabel:CGRectMake(14, 32, 100, 54) font:[UIFont systemFontOfSize:46 weight:UIFontWeightLight]];
    self.iconLabel = [self makeLabel:CGRectMake(108, 38, 52, 46) font:[UIFont systemFontOfSize:36]];
    self.iconLabel.textAlignment = NSTextAlignmentCenter;
    self.condLabel = [self makeLabel:CGRectMake(14, 100, 142, 18) font:[UIFont boldSystemFontOfSize:13]];
    self.hiloLabel = [self makeLabel:CGRectMake(14, 120, 142, 16) font:[UIFont systemFontOfSize:12]];
    self.statusLabel = [self makeLabel:CGRectMake(14, 146, 142, 14) font:[UIFont systemFontOfSize:9]];

    UIColor *w1 = [UIColor colorWithWhite:1.0 alpha:1.0];
    UIColor *w2 = [UIColor colorWithWhite:1.0 alpha:0.9];
    UIColor *w3 = [UIColor colorWithWhite:1.0 alpha:0.7];
    if ([type isEqualToString:@"horloge"]) {
        self.grad.colors = @[(id)MWC(0.22, 0.23, 0.29).CGColor, (id)MWC(0.05, 0.05, 0.10).CGColor];
        self.cityLabel.text = @"Horloge";
        self.tempLabel.frame = CGRectMake(14, 40, 142, 60);
        self.tempLabel.font = [UIFont systemFontOfSize:52 weight:UIFontWeightLight];
        self.iconLabel.hidden = YES;
        self.condLabel.frame = CGRectMake(14, 112, 142, 18);
    } else if ([type isEqualToString:@"batterie"]) {
        // style « Batteries » d'iOS 18 : carte noire, anneau de charge vert, pourcentage au centre
        self.grad.colors = @[(id)MWC(0.13, 0.13, 0.14).CGColor, (id)MWC(0.05, 0.05, 0.06).CGColor];
        self.cityLabel.text = @"Batteries";
        self.iconLabel.hidden = YES;
        self.hiloLabel.hidden = YES;
        self.tempLabel.frame = CGRectMake(35, 54, 100, 44);
        self.tempLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightMedium];
        self.tempLabel.textAlignment = NSTextAlignmentCenter;
        self.condLabel.frame = CGRectMake(10, 138, 150, 18);
        self.condLabel.textAlignment = NSTextAlignmentCenter;
        UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(85, 76) radius:46 startAngle:-M_PI_2 endAngle:(3.0 * M_PI_2) clockwise:YES];
        self.ringTrack = [CAShapeLayer layer];
        self.ringTrack.path = path.CGPath;
        self.ringTrack.fillColor = [UIColor clearColor].CGColor;
        self.ringTrack.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
        self.ringTrack.lineWidth = 10.0;
        [self.layer addSublayer:self.ringTrack];
        self.ringProgress = [CAShapeLayer layer];
        self.ringProgress.path = path.CGPath;
        self.ringProgress.fillColor = [UIColor clearColor].CGColor;
        self.ringProgress.strokeColor = [UIColor colorWithRed:0.30 green:0.85 blue:0.39 alpha:1.0].CGColor;
        self.ringProgress.lineWidth = 10.0;
        self.ringProgress.lineCap = kCALineCapRound;
        self.ringProgress.strokeEnd = 0.0;
        [self.layer addSublayer:self.ringProgress];
    } else if ([type isEqualToString:@"date"]) {
        self.grad.colors = @[(id)MWC(0.99, 0.99, 1.0).CGColor, (id)MWC(0.88, 0.88, 0.92).CGColor];
        w1 = [UIColor colorWithWhite:0.08 alpha:1.0];
        w2 = [UIColor colorWithWhite:0.15 alpha:0.9];
        w3 = [UIColor colorWithWhite:0.3 alpha:0.7];
        self.tempLabel.frame = CGRectMake(14, 34, 142, 74);
        self.tempLabel.font = [UIFont systemFontOfSize:62 weight:UIFontWeightLight];
        self.iconLabel.hidden = YES;
        self.condLabel.frame = CGRectMake(14, 112, 142, 18);
    } else {
        self.grad.colors = @[(id)MWC(0.28, 0.56, 0.96).CGColor, (id)MWC(0.13, 0.33, 0.74).CGColor];
        self.cityLabel.text = kMWCity;
        self.tempLabel.text = @"--°";
        self.statusLabel.text = @"Chargement...";
    }
    self.cityLabel.textColor = w1;
    self.tempLabel.textColor = w1;
    self.iconLabel.textColor = w1;
    self.condLabel.textColor = w2;
    self.hiloLabel.textColor = w2;
    self.statusLabel.textColor = w3;
    if ([type isEqualToString:@"date"]) self.cityLabel.textColor = [UIColor colorWithRed:0.92 green:0.2 blue:0.2 alpha:1.0];

    // croix de suppression (visible seulement en mode edition), en haut a droite
    self.delButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.delButton.frame = CGRectMake(kMWSize - 34, 6, 28, 28);
    self.delButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.85];
    self.delButton.layer.cornerRadius = 14.0;
    [self.delButton setTitle:@"✕" forState:UIControlStateNormal];
    [self.delButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.delButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.delButton addTarget:gMgr action:@selector(deleteTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.delButton.hidden = YES;
    [self addSubview:self.delButton];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gMgr action:@selector(widgetLongPress:)];
    lp.minimumPressDuration = 0.6;
    [self addGestureRecognizer:lp];
    UITapGestureRecognizer *tp = [[UITapGestureRecognizer alloc] initWithTarget:gMgr action:@selector(widgetTap:)];
    [self addGestureRecognizer:tp];
    return self;
}

- (void)applyInfo:(NSDictionary *)info stale:(BOOL)stale {
    @try {
        int code = [info[@"code"] intValue];
        BOOL day = [info[@"day"] intValue] != 0;
        self.tempLabel.text = [NSString stringWithFormat:@"%d°", (int)lround([info[@"temp"] doubleValue])];
        self.iconLabel.text = MWEmoji(code, day);
        self.condLabel.text = MWText(code);
        if (info[@"max"] && info[@"min"]) {
            self.hiloLabel.text = [NSString stringWithFormat:@"Max %d°  Min %d°", (int)lround([info[@"max"] doubleValue]), (int)lround([info[@"min"] doubleValue])];
        } else {
            self.hiloLabel.text = @"";
        }
        if (day) {
            self.grad.colors = @[(id)MWC(0.28, 0.56, 0.96).CGColor, (id)MWC(0.13, 0.33, 0.74).CGColor];
        } else {
            self.grad.colors = @[(id)MWC(0.10, 0.14, 0.35).CGColor, (id)MWC(0.04, 0.06, 0.18).CGColor];
        }
        if (stale) {
            self.statusLabel.text = @"Hors ligne (dernière météo)";
        } else {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.dateFormat = @"HH:mm";
            self.statusLabel.text = [NSString stringWithFormat:@"Mise à jour %@", [f stringFromDate:[NSDate date]]];
        }
    } @catch (...) {}
}

- (void)showStatus:(NSString *)s { self.statusLabel.text = s; }

// contenu des widgets locaux (horloge, date, batterie)
- (void)refresh {
    @try {
        NSDate *now = [NSDate date];
        NSLocale *fr = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.locale = fr;
        if ([self.type isEqualToString:@"horloge"]) {
            f.dateFormat = @"HH:mm";
            self.tempLabel.text = [f stringFromDate:now];
            f.dateFormat = @"EEEE d MMMM";
            self.condLabel.text = [f stringFromDate:now];
        } else if ([self.type isEqualToString:@"date"]) {
            f.dateFormat = @"EEEE";
            self.cityLabel.text = [[f stringFromDate:now] uppercaseStringWithLocale:fr];
            f.dateFormat = @"d";
            self.tempLabel.text = [f stringFromDate:now];
            f.dateFormat = @"MMMM yyyy";
            self.condLabel.text = [f stringFromDate:now];
        } else if ([self.type isEqualToString:@"batterie"]) {
            UIDevice *d = [UIDevice currentDevice];
            float lv = d.batteryLevel;
            self.tempLabel.text = lv < 0 ? @"--%" : [NSString stringWithFormat:@"%d%%", (int)lroundf(lv * 100.0f)];
            BOOL chg = (d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull);
            NSString *etat = d.batteryState == UIDeviceBatteryStateFull ? @"Chargée" : (chg ? @"⚡️ En charge" : @"Sur batterie");
            self.condLabel.text = [NSString stringWithFormat:@"%@ · %@", d.model, etat];
            float p = lv < 0 ? 0.0f : lv;
            self.ringProgress.strokeEnd = p;
            UIColor *col = (!chg && p <= 0.20f) ? [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0]
                                                  : [UIColor colorWithRed:0.30 green:0.85 blue:0.39 alpha:1.0];
            self.ringProgress.strokeColor = col.CGColor;
        }
    } @catch (...) {}
}

// premier remplissage d'un widget
- (void)prime {
    if ([self.type isEqualToString:@"meteo"]) {
        @try {
            NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kMWCache];
            if ([c isKindOfClass:[NSDictionary class]] && c[@"temp"]) [self applyInfo:c stale:YES];
        } @catch (...) {}
        MWFetch(0, nil);
    } else {
        [self refresh];
    }
}

- (void)setEditing:(BOOL)e {
    self.delButton.hidden = !e;
    [self.layer removeAnimationForKey:@"mwwiggle"];
    if (e) {
        CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        a.values = @[@(-0.016), @(0.016), @(-0.016)];
        a.duration = 0.26;
        a.repeatCount = HUGE_VALF;
        a.timeOffset = (arc4random() % 100) / 100.0 * 0.26;
        [self.layer addAnimation:a forKey:@"mwwiggle"];
    }
}

@end

// ---------- telechargement meteo (3 adresses essayees l'une apres l'autre) ----------
static void MWFetch(NSUInteger idx, NSString *lastErr) {
    NSArray *urls = @[
        [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true&daily=temperature_2m_max,temperature_2m_min&timezone=auto", kMWLat, kMWLon],
        [NSString stringWithFormat:@"http://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true&daily=temperature_2m_max,temperature_2m_min&timezone=auto", kMWLat, kMWLon],
        [NSString stringWithFormat:@"http://wttr.in/%@?format=j1", kMWCity]
    ];
    if (idx >= urls.count) {
        MWLog([NSString stringWithFormat:@"echec total: %@", lastErr]);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (MWWidgetView *w in gWidgets) {
                if ([w.type isEqualToString:@"meteo"]) [w showStatus:[NSString stringWithFormat:@"Météo indisponible (%@)", lastErr ?: @"?"]];
            }
        });
        return;
    }
    @try {
        NSURL *u = [NSURL URLWithString:urls[idx]];
        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
        [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            NSDictionary *info = (d && !e) ? MWParse(d) : nil;
            if (info) {
                MWLog([NSString stringWithFormat:@"meteo OK via adresse %lu : %@", (unsigned long)idx, info[@"temp"]]);
                @try {
                    [[NSFileManager defaultManager] createDirectoryAtPath:kMWDir withIntermediateDirectories:YES attributes:nil error:nil];
                    [info writeToFile:kMWCache atomically:YES];
                } @catch (...) {}
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (MWWidgetView *w in gWidgets) {
                        if ([w.type isEqualToString:@"meteo"]) [w applyInfo:info stale:NO];
                    }
                });
            } else {
                NSString *err = e ? [NSString stringWithFormat:@"%ld", (long)e.code] : @"donnees";
                MWLog([NSString stringWithFormat:@"adresse %lu echec: %@", (unsigned long)idx, e ? e.localizedDescription : @"reponse illisible"]);
                MWFetch(idx + 1, err);
            }
        }] resume];
    } @catch (NSException *ex) {
        MWFetch(idx + 1, @"exc");
    }
}

// ---------- placement / edition ----------
static void MWLayout(UIView *lv) {
    NSUInteger n = gWidgets.count;
    if (!n || !lv) return;
    CGFloat w = lv.bounds.size.width;
    CGFloat total = n * kMWSize + (n - 1) * kMWGap;
    CGFloat x = floor((w - total) / 2.0);
    for (NSUInteger i = 0; i < n; i++) {
        MWWidgetView *v = gWidgets[i];
        CGPoint c = CGPointMake(x + i * (kMWSize + kMWGap) + kMWSize / 2.0, kMWTop + kMWSize / 2.0);
        if (!CGPointEqualToPoint(v.center, c)) v.center = c;
    }
}

static void MWSetEditing(BOOL e) {
    if (gEditing == e) return;
    gEditing = e;
    for (MWWidgetView *w in gWidgets) [w setEditing:e];
}

static void MWEnterEditing(void) {
    if (gSBEditAPI) [[%c(SBIconController) sharedInstance] setIsEditing:YES];
    else MWSetEditing(YES);
}

static void MWExitEditing(void) {
    if (gSBEditAPI) [[%c(SBIconController) sharedInstance] setIsEditing:NO];
    else MWSetEditing(NO);
}

static void MWDismissPicker(void) {
    [gPicker removeFromSuperview];
    gPicker = nil;
}

static void MWAddType(NSString *type) {
    if (!gHost || gWidgets.count >= kMWMax) return;
    for (MWWidgetView *w in gWidgets) { if ([w.type isEqualToString:type]) return; }
    MWWidgetView *nw = [[MWWidgetView alloc] initWithType:type];
    [gWidgets addObject:nw];
    [gHost insertSubview:nw atIndex:0];
    [nw setEditing:gEditing];
    MWLayout(gHost);
    [nw prime];
    MWSaveTypes();
    MWLog([NSString stringWithFormat:@"widget ajoute: %@", type]);
}

static void MWRemove(MWWidgetView *w) {
    [gWidgets removeObject:w];
    MWSaveTypes();
    [UIView animateWithDuration:0.2 animations:^{
        w.alpha = 0.0;
        w.transform = CGAffineTransformMakeScale(0.6, 0.6);
    } completion:^(BOOL f) {
        [w removeFromSuperview];
    }];
    if (gHost) MWLayout(gHost);
    MWLog([NSString stringWithFormat:@"widget supprime: %@", w.type]);
}

static void MWShowPicker(void) {
    UIView *lv = gHost;
    if (!lv) return;
    MWDismissPicker();
    NSMutableArray *avail = [NSMutableArray array];
    for (NSString *t in MWAllTypes()) {
        BOOL used = NO;
        for (MWWidgetView *w in gWidgets) { if ([w.type isEqualToString:t]) used = YES; }
        if (!used) [avail addObject:t];
    }
    BOOL full = gWidgets.count >= kMWMax;

    UIView *dim = [[UIView alloc] initWithFrame:lv.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:gMgr action:@selector(dismissPicker)];
    [dim addGestureRecognizer:tap];

    NSUInteger rows = (full || avail.count == 0) ? 1 : avail.count;
    CGFloat ph = 64 + rows * 54 + 10;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 330, ph)];
    panel.center = CGPointMake(CGRectGetMidX(lv.bounds), CGRectGetMidY(lv.bounds) - 40);
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    panel.backgroundColor = [UIColor colorWithWhite:0.14 alpha:0.97];
    panel.layer.cornerRadius = 22.0;
    [dim addSubview:panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, 298, 30)];
    title.text = @"Ajouter un widget";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:title];

    if (full || avail.count == 0) {
        UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(16, 54, 298, 54)];
        m.text = full ? @"3 widgets maximum (mémoire de l'iPad 2). Supprime-en un d'abord." : @"Tous les widgets sont déjà ajoutés.";
        m.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
        m.font = [UIFont systemFontOfSize:15];
        m.numberOfLines = 3;
        m.textAlignment = NSTextAlignmentCenter;
        [panel addSubview:m];
    } else {
        for (NSUInteger i = 0; i < avail.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(16, 54 + i * 54, 298, 46);
            b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.95];
            b.layer.cornerRadius = 12.0;
            [b setTitle:MWTypeTitle(avail[i]) forState:UIControlStateNormal];
            [b setTitleColor:[UIColor colorWithWhite:0.1 alpha:1.0] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:18];
            b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
            b.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 0);
            b.accessibilityIdentifier = avail[i];
            [b addTarget:gMgr action:@selector(pickTapped:) forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:b];
        }
    }
    [lv addSubview:dim];
    gPicker = dim;
}

@implementation MWManager

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

- (void)hostLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIView *lv = gHost;
    if (!lv || gPicker) return;
    CGPoint pt = [g locationInView:lv];
    UIView *hit = [lv hitTest:pt withEvent:nil];
    for (UIView *v = hit; v && v != lv; v = v.superview) {
        if ([v isKindOfClass:[MWWidgetView class]]) return;
        if ([NSStringFromClass([v class]) rangeOfString:@"IconView"].location != NSNotFound) return;
    }
    MWShowPicker();
}

- (void)widgetLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && !gEditing) MWEnterEditing();
}

- (void)widgetTap:(UITapGestureRecognizer *)g {
    if (gEditing) MWExitEditing();
}

- (void)deleteTapped:(UIButton *)b {
    UIView *v = b.superview;
    if ([v isKindOfClass:[MWWidgetView class]]) MWRemove((MWWidgetView *)v);
}

- (void)pickTapped:(UIButton *)b {
    NSString *t = b.accessibilityIdentifier;
    MWDismissPicker();
    if (t) MWAddType(t);
}

- (void)dismissPicker { MWDismissPicker(); }

- (void)tick:(NSTimer *)t {
    gTicks++;
    BOOL hasMeteo = NO;
    for (MWWidgetView *w in gWidgets) {
        if ([w.type isEqualToString:@"meteo"]) hasMeteo = YES; else [w refresh];
    }
    if (hasMeteo && gTicks % 60 == 0) MWFetch(0, nil);   // toutes les 30 minutes
}

- (void)battChanged {
    for (MWWidgetView *w in gWidgets) { if ([w.type isEqualToString:@"batterie"]) [w refresh]; }
}

@end

// ---------- accrochage a la 1re page de l'ecran d'accueil ----------
static BOOL MWIsPageList(UIView *lv) {
    NSString *cn = NSStringFromClass([lv class]);
    return [cn isEqualToString:@"SBIconListView"] || [cn isEqualToString:@"SBRootIconListView"];
}

// numero de la page (0 = 1re page), -1 si on ne sait pas
static NSInteger MWPageIndex(UIView *lv) {
    @try {
        id model = [lv valueForKey:@"model"];
        id folder = [model valueForKey:@"folder"];
        NSArray *lists = [folder valueForKey:@"lists"];
        if ([lists isKindOfClass:[NSArray class]]) {
            NSUInteger i = [lists indexOfObjectIdenticalTo:model];
            if (i != NSNotFound) return (NSInteger)i;
        }
    } @catch (...) {}
    return -1;
}

static void MWBoot(void) {
    gMgr = [[MWManager alloc] init];
    gWidgets = [NSMutableArray array];
    @try {
        id ic = [%c(SBIconController) sharedInstance];
        gSBEditAPI = (ic && [ic respondsToSelector:@selector(isEditing)] && [ic respondsToSelector:@selector(setIsEditing:)]);
    } @catch (...) {}
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [[NSNotificationCenter defaultCenter] addObserver:gMgr selector:@selector(battChanged) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:gMgr selector:@selector(battChanged) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    for (NSString *t in MWLoadTypes()) {
        MWWidgetView *w = [[MWWidgetView alloc] initWithType:t];
        [gWidgets addObject:w];
    }
    [NSTimer scheduledTimerWithTimeInterval:30.0 target:gMgr selector:@selector(tick:) userInfo:nil repeats:YES];
    MWLog([NSString stringWithFormat:@"demarrage: %lu widget(s), API edition SpringBoard: %d", (unsigned long)gWidgets.count, (int)gSBEditAPI]);
}

static void MWSetHost(UIView *lv, NSInteger idx) {
    BOOL first = (gWidgets == nil);
    if (first) MWBoot();
    if (gHost && gHost != lv) {
        if (gLongPress) [gHost removeGestureRecognizer:gLongPress];
        for (MWWidgetView *w in gWidgets) [w removeFromSuperview];
        MWDismissPicker();
    }
    gHost = lv;
    gHostIdx = idx;
    for (MWWidgetView *w in gWidgets) [lv insertSubview:w atIndex:0];
    if (!gLongPress) {
        gLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:gMgr action:@selector(hostLongPress:)];
        gLongPress.minimumPressDuration = 0.7;
        gLongPress.cancelsTouchesInView = NO;
        gLongPress.delegate = gMgr;
    }
    [lv addGestureRecognizer:gLongPress];
    MWLayout(lv);
    MWLog([NSString stringWithFormat:@"accroche a %@ (page %ld, x=%.0f)", NSStringFromClass([lv class]), (long)idx, lv.frame.origin.x]);
    if (first) { for (MWWidgetView *w in gWidgets) [w prime]; }
}

static void MWSyncEditing(void) {
    if (!gSBEditAPI) return;
    @try {
        BOOL ed = [[%c(SBIconController) sharedInstance] isEditing];
        if (ed != gEditing) MWSetEditing(ed);
    } @catch (...) {}
}

static void MWAttach(UIView *lv) {
    @try {
        if (!MWIsPageList(lv)) return;
        if (gHost == lv) {
            MWLayout(lv);
            MWSyncEditing();
            return;
        }
        NSInteger idx = MWPageIndex(lv);
        UIView *cur = gHost;
        BOOL take = NO;
        if (!cur || !cur.superview) take = YES;
        else if (idx >= 0 && (gHostIdx < 0 || idx < gHostIdx)) take = YES;
        else if (idx < 0 && gHostIdx < 0 && lv.frame.origin.x < cur.frame.origin.x - 1.0) take = YES;
        if (take) MWSetHost(lv, idx);
    } @catch (NSException *e) {
        MWLog([NSString stringWithFormat:@"exception accroche: %@", e]);
    }
}

@interface SBIconListView : UIView
@end

%hook SBIconListView
- (void)layoutSubviews {
    %orig;
    MWAttach(self);
}
%end

%group MWEditHook
%hook SBIconController
- (void)setIsEditing:(BOOL)editing {
    %orig;
    MWSetEditing(editing);
}
%end
%end

%ctor {
    %init;
    Class c = objc_getClass("SBIconController");
    if (c && class_getInstanceMethod(c, @selector(setIsEditing:))) {
        %init(MWEditHook);
    }
    MWLog(@"MeteoWidget 2.1.0 charge");
}
