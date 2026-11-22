// MeteoWidget 1.0.0 - widget meteo style iOS 14 pour iOS 9 (SpringBoard, armv7)
// Ville : Libreville. Le widget se place derriere les icones, en haut a droite de la 1re page.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kMWCity = @"Libreville";
static const double kMWLat = 0.4162;
static const double kMWLon = 9.4673;
static const CGFloat kMWSize = 170.0;
static NSString *const kMWDir = @"/var/mobile/Library/MeteoWidget";
static NSString *const kMWCache = @"/var/mobile/Library/MeteoWidget/cache.plist";

@class MWWidgetView;
static MWWidgetView *gWidget = nil;
static __weak UIView *gHost = nil;

// ---------- journal (dossier a nous, donc toujours inscriptible) ----------
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
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSInteger hr = [cal component:NSCalendarUnitHour fromDate:[NSDate date]];
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
@interface MWWidgetView : UIView
@property (nonatomic, strong) UILabel *cityLabel;
@property (nonatomic, strong) UILabel *tempLabel;
@property (nonatomic, strong) UILabel *iconLabel;
@property (nonatomic, strong) UILabel *condLabel;
@property (nonatomic, strong) UILabel *hiloLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) CAGradientLayer *grad;
- (void)applyInfo:(NSDictionary *)info stale:(BOOL)stale;
- (void)showStatus:(NSString *)s;
- (void)loadCacheAndStart;
+ (void)tick;
@end

static void MWFetch(NSUInteger idx, NSString *lastErr);

@implementation MWWidgetView

- (UILabel *)makeLabel:(CGRect)f font:(UIFont *)font alpha:(CGFloat)a {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.backgroundColor = [UIColor clearColor];
    l.textColor = [UIColor colorWithWhite:1.0 alpha:a];
    l.font = font;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7;
    [self addSubview:l];
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.layer.cornerRadius = 22.0;
    self.layer.masksToBounds = YES;

    self.grad = [CAGradientLayer layer];
    self.grad.frame = CGRectMake(0, 0, kMWSize, kMWSize);
    self.grad.colors = @[(id)[UIColor colorWithRed:0.28 green:0.56 blue:0.96 alpha:0.95].CGColor,
                         (id)[UIColor colorWithRed:0.13 green:0.33 blue:0.74 alpha:0.95].CGColor];
    [self.layer insertSublayer:self.grad atIndex:0];

    self.cityLabel = [self makeLabel:CGRectMake(14, 12, 142, 20) font:[UIFont boldSystemFontOfSize:15] alpha:1.0];
    self.cityLabel.text = kMWCity;
    self.tempLabel = [self makeLabel:CGRectMake(14, 32, 100, 54) font:[UIFont systemFontOfSize:46 weight:UIFontWeightLight] alpha:1.0];
    self.tempLabel.text = @"--°";
    self.iconLabel = [self makeLabel:CGRectMake(108, 38, 52, 46) font:[UIFont systemFontOfSize:36] alpha:1.0];
    self.iconLabel.textAlignment = NSTextAlignmentCenter;
    self.condLabel = [self makeLabel:CGRectMake(14, 100, 142, 18) font:[UIFont boldSystemFontOfSize:13] alpha:0.95];
    self.hiloLabel = [self makeLabel:CGRectMake(14, 120, 142, 16) font:[UIFont systemFontOfSize:12] alpha:0.85];
    self.statusLabel = [self makeLabel:CGRectMake(14, 146, 142, 14) font:[UIFont systemFontOfSize:9] alpha:0.6];
    self.statusLabel.text = @"Chargement...";
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
            self.grad.colors = @[(id)[UIColor colorWithRed:0.28 green:0.56 blue:0.96 alpha:0.95].CGColor,
                                 (id)[UIColor colorWithRed:0.13 green:0.33 blue:0.74 alpha:0.95].CGColor];
        } else {
            self.grad.colors = @[(id)[UIColor colorWithRed:0.10 green:0.14 blue:0.35 alpha:0.95].CGColor,
                                 (id)[UIColor colorWithRed:0.04 green:0.06 blue:0.18 alpha:0.95].CGColor];
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

- (void)loadCacheAndStart {
    @try {
        NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kMWCache];
        if ([c isKindOfClass:[NSDictionary class]] && c[@"temp"]) [self applyInfo:c stale:YES];
    } @catch (...) {}
    static BOOL started = NO;
    if (!started) {
        started = YES;
        [NSTimer scheduledTimerWithTimeInterval:1800.0 target:[MWWidgetView class] selector:@selector(tick) userInfo:nil repeats:YES];
    }
    MWFetch(0, nil);
}

+ (void)tick { MWFetch(0, nil); }

@end

// ---------- telechargement (3 adresses essayees l'une apres l'autre) ----------
static void MWFetch(NSUInteger idx, NSString *lastErr) {
    NSArray *urls = @[
        [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true&daily=temperature_2m_max,temperature_2m_min&timezone=auto", kMWLat, kMWLon],
        [NSString stringWithFormat:@"http://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true&daily=temperature_2m_max,temperature_2m_min&timezone=auto", kMWLat, kMWLon],
        [NSString stringWithFormat:@"http://wttr.in/%@?format=j1", kMWCity]
    ];
    if (idx >= urls.count) {
        MWLog([NSString stringWithFormat:@"echec total: %@", lastErr]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gWidget) [gWidget showStatus:[NSString stringWithFormat:@"Météo indisponible (%@)", lastErr ?: @"?"]];
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
                    if (gWidget) [gWidget applyInfo:info stale:NO];
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

// ---------- accrochage a la 1re page de l'ecran d'accueil ----------
static void MWAttach(UIView *lv) {
    @try {
        NSString *cn = NSStringFromClass([lv class]);
        if (![cn isEqualToString:@"SBIconListView"] && ![cn isEqualToString:@"SBRootIconListView"]) return;
        CGRect f = CGRectMake(lv.bounds.size.width - kMWSize - 28.0, 48.0, kMWSize, kMWSize);
        if (gWidget && gWidget.superview == lv) {
            if (!CGRectEqualToRect(gWidget.frame, f)) gWidget.frame = f;
            return;
        }
        if (gHost && gHost != lv && gHost.superview) return;   // un seul hote : la 1re page
        gHost = lv;
        BOOL fresh = NO;
        if (!gWidget) {
            gWidget = [[MWWidgetView alloc] initWithFrame:f];
            fresh = YES;
        }
        [gWidget removeFromSuperview];
        gWidget.frame = f;
        [lv insertSubview:gWidget atIndex:0];
        MWLog([NSString stringWithFormat:@"widget accroche a %@", cn]);
        if (fresh) [gWidget loadCacheAndStart];
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

%ctor {
    MWLog(@"MeteoWidget 1.0.0 charge");
}
