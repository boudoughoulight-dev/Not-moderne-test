// MeteoWidget 3.1.0 - widgets style iOS 14/18 pour iOS 9 (SpringBoard, armv7)
// - 3 widgets max sur la 1re page de l'ecran d'accueil (derriere les icones)
// - 8 widgets au choix : Meteo, Previsions, Horloge, Date, Mois, Batterie, Stockage, Memoire
// - appui long sur une zone vide : choisir un widget ; appui long sur un widget : mode edition
// - en edition : glisser pour deplacer (par cases), croix en haut a droite pour supprimer,
//   bouton en bas a droite pour agrandir (jusqu'a 2 places d'app de plus, vers le bas uniquement)
// - option « Liberer la place » : les icones sont poussees hors des cases occupees par les widgets
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <unistd.h>

static NSString *const kMWCity = @"Libreville";
static const double kMWLat = 0.4162;
static const double kMWLon = 9.4673;
static const CGFloat kMWSize = 170.0;
static const CGFloat kMWTop = 56.0;
static const NSUInteger kMWMax = 3;
static NSString *const kMWDir = @"/var/mobile/Library/MeteoWidget";
static NSString *const kMWCache = @"/var/mobile/Library/MeteoWidget/cache.plist";
static NSString *const kMWTypesPath = @"/var/mobile/Library/MeteoWidget/widgets.plist";

@class MWWidgetView;
@class MWManager;

@interface SBIconListView : UIView
- (CGPoint)originForIconAtIndex:(NSUInteger)index;
- (void)layoutIconsNow;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isEditing;
- (void)setIsEditing:(BOOL)editing;
@end

static NSMutableArray *gWidgets = nil;      // MWWidgetView
static __weak UIView *gHost = nil;          // la liste d'icones qui porte les widgets
static NSInteger gHostIdx = -1;
static BOOL gEditing = NO;
static BOOL gSBEditAPI = NO;
static UIView *gPicker = nil;
static UILongPressGestureRecognizer *gLongPress = nil;
static MWManager *gMgr = nil;
static NSUInteger gTicks = 0;
static __weak UIScrollView *gLockedScroll = nil;
static BOOL gBypass = NO;                    // appel interne : on veut la position d'origine des icones
static BOOL gPush = YES;                     // option : pousser les icones hors des cases des widgets
static BOOL gPushAPI = NO;                   // la methode de placement des icones existe sur cet iOS
static NSString *const kMWOptions = @"/var/mobile/Library/MeteoWidget/options.plist";
static BOOL gDragging = NO;                  // un widget est en train d'etre deplace

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
static NSArray *MWAllTypes(void) {
    return @[@"meteo", @"previsions", @"horloge", @"date", @"mois", @"batterie", @"stockage", @"memoire"];
}

static NSString *MWTypeTitle(NSString *t) {
    if ([t isEqualToString:@"meteo"]) return @"☁️  Météo";
    if ([t isEqualToString:@"previsions"]) return @"📆  Prévisions";
    if ([t isEqualToString:@"horloge"]) return @"🕐  Horloge";
    if ([t isEqualToString:@"date"]) return @"📅  Date";
    if ([t isEqualToString:@"mois"]) return @"🗓  Mois";
    if ([t isEqualToString:@"batterie"]) return @"🔋  Batterie";
    if ([t isEqualToString:@"stockage"]) return @"💾  Stockage";
    if ([t isEqualToString:@"memoire"]) return @"🧠  Mémoire (RAM)";
    return t;
}

static id MWAt(id arr, NSUInteger i) {
    return ([arr isKindOfClass:[NSArray class]] && i < [(NSArray *)arr count]) ? [(NSArray *)arr objectAtIndex:i] : nil;
}

static NSNumber *MWNum(id x) {
    if ([x isKindOfClass:[NSNumber class]]) return x;
    if ([x isKindOfClass:[NSString class]]) return @([(NSString *)x doubleValue]);
    return nil;
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

// ---------- lecture de la reponse (Open-Meteo ou wttr.in) ----------
static NSString *MWShortDay(NSString *iso) {
    NSDateFormatter *pf = [[NSDateFormatter alloc] init];
    pf.dateFormat = @"yyyy-MM-dd";
    pf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDate *d = [pf dateFromString:iso];
    if (!d) return @"?";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"EEE";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
    return [[df stringFromDate:d] stringByReplacingOccurrencesOfString:@"." withString:@""];
}

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
                NSArray *times = daily[@"time"];
                NSArray *codes = daily[@"weathercode"];
                NSArray *mx = daily[@"temperature_2m_max"];
                NSArray *mn = daily[@"temperature_2m_min"];
                if (MWNum(MWAt(mx, 0))) out[@"max"] = MWNum(MWAt(mx, 0));
                if (MWNum(MWAt(mn, 0))) out[@"min"] = MWNum(MWAt(mn, 0));
                NSMutableArray *days = [NSMutableArray array];
                for (NSUInteger i = 0; i < 5; i++) {
                    NSString *t = MWAt(times, i);
                    NSNumber *a = MWNum(MWAt(mx, i)), *b = MWNum(MWAt(mn, i));
                    if (![t isKindOfClass:[NSString class]] || !a || !b) break;
                    [days addObject:@{@"d": MWShortDay(t), @"c": MWNum(MWAt(codes, i)) ?: @0, @"mx": a, @"mn": b}];
                }
                if (days.count) out[@"days"] = days;
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
                NSMutableArray *days = [NSMutableArray array];
                for (NSUInteger i = 0; i < 5 && i < w.count; i++) {
                    NSDictionary *wi = w[i];
                    if (![wi isKindOfClass:[NSDictionary class]]) break;
                    NSString *dt = wi[@"date"];
                    NSNumber *a = MWNum(wi[@"maxtempC"]), *b = MWNum(wi[@"mintempC"]);
                    if (![dt isKindOfClass:[NSString class]] || !a || !b) break;
                    NSString *dsc = @"";
                    id hrl = MWAt(wi[@"hourly"], 4);
                    if ([hrl isKindOfClass:[NSDictionary class]]) {
                        id wdd = MWAt(hrl[@"weatherDesc"], 0);
                        if ([wdd isKindOfClass:[NSDictionary class]]) dsc = wdd[@"value"] ?: @"";
                    }
                    [days addObject:@{@"d": MWShortDay(dt), @"c": @(MWCodeFromEnglish(dsc)), @"mx": a, @"mn": b}];
                }
                if (days.count) out[@"days"] = days;
            }
            return out;
        }
    } @catch (...) {}
    return nil;
}

// ---------- infos systeme (stockage, memoire) ----------
static uint64_t MWFreeRAM(void) {
    vm_statistics_data_t vm;
    mach_msg_type_number_t cnt = HOST_VM_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vm, &cnt) != KERN_SUCCESS) return 0;
    uint64_t page = (uint64_t)sysconf(_SC_PAGESIZE);
    return ((uint64_t)vm.free_count + (uint64_t)vm.inactive_count) * page;
}

// ---------- le widget ----------
static UIColor *MWC(CGFloat r, CGFloat g, CGFloat b) { return [UIColor colorWithRed:r green:g blue:b alpha:0.96]; }

@interface MWWidgetView : UIView
@property (nonatomic, copy) NSString *type;
@property (nonatomic, assign) NSInteger col;
@property (nonatomic, assign) NSInteger row;
@property (nonatomic, assign) NSInteger span;       // 1 a 3 places en hauteur
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, strong) UILabel *cityLabel;
@property (nonatomic, strong) UILabel *tempLabel;
@property (nonatomic, strong) UILabel *iconLabel;
@property (nonatomic, strong) UILabel *condLabel;
@property (nonatomic, strong) UILabel *hiloLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *bodyLabel;
@property (nonatomic, strong) CAGradientLayer *grad;
@property (nonatomic, strong) UIButton *delButton;
@property (nonatomic, strong) UIButton *sizeButton;
@property (nonatomic, strong) CAShapeLayer *ringTrack;
@property (nonatomic, strong) CAShapeLayer *ringProgress;
@property (nonatomic, assign) CGRect baseTemp;
@property (nonatomic, assign) CGRect baseIcon;
@property (nonatomic, assign) CGRect baseCond;
@property (nonatomic, assign) CGRect baseHilo;
@property (nonatomic, assign) CGRect baseStatus;
- (instancetype)initWithType:(NSString *)type col:(NSInteger)col row:(NSInteger)row span:(NSInteger)span;
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
- (void)widgetPan:(UIPanGestureRecognizer *)g;
- (void)deleteTapped:(UIButton *)b;
- (void)sizeTapped:(UIButton *)b;
- (void)pickTapped:(UIButton *)b;
- (void)pushSwitched:(UISwitch *)sw;
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

- (void)setupRingWithColor:(UIColor *)color {
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
    self.ringProgress.strokeColor = color.CGColor;
    self.ringProgress.lineWidth = 10.0;
    self.ringProgress.lineCap = kCALineCapRound;
    self.ringProgress.strokeEnd = 0.0;
    [self.layer addSublayer:self.ringProgress];
    self.tempLabel.frame = CGRectMake(35, 54, 100, 44);
    self.tempLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightMedium];
    self.tempLabel.textAlignment = NSTextAlignmentCenter;
    self.condLabel.frame = CGRectMake(10, 138, 150, 18);
    self.condLabel.textAlignment = NSTextAlignmentCenter;
    self.iconLabel.hidden = YES;
    self.hiloLabel.hidden = YES;
}

- (instancetype)initWithType:(NSString *)type col:(NSInteger)col row:(NSInteger)row span:(NSInteger)span {
    self = [super initWithFrame:CGRectMake(0, 0, kMWSize, kMWSize)];
    if (!self) return nil;
    self.type = type;
    self.col = col;
    self.row = row;
    self.span = MAX(1, MIN(3, span));
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
    self.bodyLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 36, 146, 122)];
    self.bodyLabel.backgroundColor = [UIColor clearColor];
    self.bodyLabel.numberOfLines = 0;
    self.bodyLabel.hidden = YES;
    [self addSubview:self.bodyLabel];

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
        self.grad.colors = @[(id)MWC(0.13, 0.13, 0.14).CGColor, (id)MWC(0.05, 0.05, 0.06).CGColor];
        self.cityLabel.text = @"Batteries";
        [self setupRingWithColor:[UIColor colorWithRed:0.30 green:0.85 blue:0.39 alpha:1.0]];
    } else if ([type isEqualToString:@"stockage"]) {
        self.grad.colors = @[(id)MWC(0.13, 0.13, 0.14).CGColor, (id)MWC(0.05, 0.05, 0.06).CGColor];
        self.cityLabel.text = @"Stockage";
        [self setupRingWithColor:[UIColor colorWithRed:0.25 green:0.60 blue:1.0 alpha:1.0]];
    } else if ([type isEqualToString:@"memoire"]) {
        self.grad.colors = @[(id)MWC(0.13, 0.13, 0.14).CGColor, (id)MWC(0.05, 0.05, 0.06).CGColor];
        self.cityLabel.text = @"Mémoire (RAM)";
        [self setupRingWithColor:[UIColor colorWithRed:1.0 green:0.62 blue:0.0 alpha:1.0]];
    } else if ([type isEqualToString:@"date"]) {
        self.grad.colors = @[(id)MWC(0.99, 0.99, 1.0).CGColor, (id)MWC(0.88, 0.88, 0.92).CGColor];
        w1 = [UIColor colorWithWhite:0.08 alpha:1.0];
        w2 = [UIColor colorWithWhite:0.15 alpha:0.9];
        w3 = [UIColor colorWithWhite:0.3 alpha:0.7];
        self.tempLabel.frame = CGRectMake(14, 34, 142, 74);
        self.tempLabel.font = [UIFont systemFontOfSize:62 weight:UIFontWeightLight];
        self.iconLabel.hidden = YES;
        self.condLabel.frame = CGRectMake(14, 112, 142, 18);
    } else if ([type isEqualToString:@"mois"]) {
        self.grad.colors = @[(id)MWC(0.17, 0.17, 0.19).CGColor, (id)MWC(0.07, 0.07, 0.09).CGColor];
        self.tempLabel.hidden = YES;
        self.iconLabel.hidden = YES;
        self.condLabel.hidden = YES;
        self.hiloLabel.hidden = YES;
        self.statusLabel.hidden = YES;
        self.bodyLabel.hidden = NO;
        self.bodyLabel.frame = CGRectMake(12, 34, 146, 126);
    } else if ([type isEqualToString:@"previsions"]) {
        self.grad.colors = @[(id)MWC(0.28, 0.56, 0.96).CGColor, (id)MWC(0.13, 0.33, 0.74).CGColor];
        self.cityLabel.text = [NSString stringWithFormat:@"Prévisions · %@", kMWCity];
        self.tempLabel.hidden = YES;
        self.iconLabel.hidden = YES;
        self.condLabel.hidden = YES;
        self.hiloLabel.hidden = YES;
        self.bodyLabel.hidden = NO;
        self.bodyLabel.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
        self.bodyLabel.text = @"Chargement...";
        self.bodyLabel.frame = CGRectMake(14, 36, 146, 104);
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
    self.bodyLabel.textColor = w2;
    if ([type isEqualToString:@"date"]) self.cityLabel.textColor = [UIColor colorWithRed:0.92 green:0.2 blue:0.2 alpha:1.0];
    if ([type isEqualToString:@"mois"]) self.cityLabel.textColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.3 alpha:1.0];

    self.baseTemp = self.tempLabel.frame;
    self.baseIcon = self.iconLabel.frame;
    self.baseCond = self.condLabel.frame;
    self.baseHilo = self.hiloLabel.frame;
    self.baseStatus = self.statusLabel.frame;

    // croix de suppression (edition), en haut a droite
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

    // bouton agrandir (edition), en bas a droite
    self.sizeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.sizeButton.frame = CGRectMake(kMWSize - 34, kMWSize - 34, 28, 28);
    self.sizeButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.85];
    self.sizeButton.layer.cornerRadius = 14.0;
    [self.sizeButton setTitle:@"↕" forState:UIControlStateNormal];
    [self.sizeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sizeButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.sizeButton addTarget:gMgr action:@selector(sizeTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.sizeButton.hidden = YES;
    [self addSubview:self.sizeButton];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gMgr action:@selector(widgetLongPress:)];
    lp.minimumPressDuration = 0.6;
    lp.delegate = gMgr;
    [self addGestureRecognizer:lp];
    UITapGestureRecognizer *tp = [[UITapGestureRecognizer alloc] initWithTarget:gMgr action:@selector(widgetTap:)];
    tp.delegate = gMgr;
    [self addGestureRecognizer:tp];
    UIPanGestureRecognizer *pn = [[UIPanGestureRecognizer alloc] initWithTarget:gMgr action:@selector(widgetPan:)];
    pn.maximumNumberOfTouches = 1;
    pn.delegate = gMgr;
    [self addGestureRecognizer:pn];
    return self;
}

// le contenu s'adapte quand le widget est agrandi
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.grad.frame = self.bounds;
    CGFloat extra = MAX(0.0, self.bounds.size.height - kMWSize);
    BOOL ring = (self.ringProgress != nil);
    CGFloat topShift = extra * (ring ? 0.4 : 0.3);
    CGRect f = self.baseTemp; f.origin.y += topShift; self.tempLabel.frame = f;
    f = self.baseIcon; f.origin.y += topShift; self.iconLabel.frame = f;
    f = self.baseCond; f.origin.y += (ring ? extra : extra * 0.85); self.condLabel.frame = f;
    f = self.baseHilo; f.origin.y += extra * 0.85; self.hiloLabel.frame = f;
    f = self.baseStatus; f.origin.y += extra; self.statusLabel.frame = f;
    if (ring) {
        CATransform3D t = CATransform3DMakeTranslation(0, topShift, 0);
        self.ringTrack.transform = t;
        self.ringProgress.transform = t;
    }
    if (!self.bodyLabel.hidden) {
        CGRect b = self.bodyLabel.frame;
        b.size.height = self.bounds.size.height - b.origin.y - 10.0;
        self.bodyLabel.frame = b;
    }
    self.sizeButton.frame = CGRectMake(kMWSize - 34, self.bounds.size.height - 34, 28, 28);
    [CATransaction commit];
}

- (void)applyInfo:(NSDictionary *)info stale:(BOOL)stale {
    @try {
        if ([self.type isEqualToString:@"previsions"]) {
            NSArray *days = info[@"days"];
            if (![days isKindOfClass:[NSArray class]] || !days.count) { self.bodyLabel.text = @"Pas de prévisions"; return; }
            NSMutableArray *lines = [NSMutableArray array];
            for (NSDictionary *d in days) {
                [lines addObject:[NSString stringWithFormat:@"%@ %@ %d°/%d°", d[@"d"], MWEmoji([d[@"c"] intValue], YES),
                                  (int)lround([d[@"mx"] doubleValue]), (int)lround([d[@"mn"] doubleValue])]];
            }
            self.bodyLabel.text = [lines componentsJoinedByString:@"\n"];
            self.statusLabel.hidden = YES;
            return;
        }
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

- (void)showStatus:(NSString *)s {
    if ([self.type isEqualToString:@"previsions"]) self.bodyLabel.text = s;
    else self.statusLabel.text = s;
}

- (void)refreshMonth {
    NSLocale *fr = [NSLocale localeWithLocaleIdentifier:@"fr_FR"];
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSDate *now = [NSDate date];
    NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
    NSInteger today = c.day;
    c.day = 1;
    NSDate *first = [cal dateFromComponents:c];
    NSInteger wd = [cal component:NSCalendarUnitWeekday fromDate:first];   // 1 = dimanche
    NSInteger lead = (wd + 5) % 7;                                           // lundi = 0
    NSInteger nb = [cal rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:first].length;

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = fr;
    f.dateFormat = @"MMMM yyyy";
    self.cityLabel.text = [[f stringFromDate:now] uppercaseStringWithLocale:fr];

    UIFont *font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    UIFont *bold = [UIFont fontWithName:@"Menlo-Bold" size:11] ?: font;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineSpacing = 2.0;
    NSDictionary *base = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.85], NSParagraphStyleAttributeName: ps};
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:@"Lu Ma Me Je Ve Sa Di\n" attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.5], NSParagraphStyleAttributeName: ps}];
    NSInteger cell = 0;
    for (NSInteger i = 0; i < lead; i++) { [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"   " attributes:base]]; cell++; }
    for (NSInteger d = 1; d <= nb; d++) {
        NSString *tok = [NSString stringWithFormat:@"%2ld", (long)d];
        NSDictionary *at = (d == today) ? @{NSFontAttributeName: bold, NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.35 blue:0.3 alpha:1.0], NSParagraphStyleAttributeName: ps} : base;
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:tok attributes:at]];
        cell++;
        NSString *sep = (cell % 7 == 0) ? @"\n" : @" ";
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:sep attributes:base]];
    }
    self.bodyLabel.attributedText = out;
}

// contenu des widgets locaux (horloge, date, mois, batterie, stockage, memoire)
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
        } else if ([self.type isEqualToString:@"mois"]) {
            [self refreshMonth];
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
        } else if ([self.type isEqualToString:@"stockage"]) {
            NSDictionary *a = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@"/var/mobile" error:nil];
            double total = [a[NSFileSystemSize] doubleValue];
            double freeB = [a[NSFileSystemFreeSize] doubleValue];
            if (total > 0) {
                double g = 1024.0 * 1024.0 * 1024.0;
                self.tempLabel.text = [NSString stringWithFormat:@"%.1f Go", freeB / g];
                self.condLabel.text = [NSString stringWithFormat:@"libres sur %.0f Go", total / g];
                self.ringProgress.strokeEnd = (CGFloat)(1.0 - freeB / total);
            }
        } else if ([self.type isEqualToString:@"memoire"]) {
            double total = (double)[NSProcessInfo processInfo].physicalMemory;
            double freeB = (double)MWFreeRAM();
            if (total > 0) {
                double m = 1024.0 * 1024.0;
                self.tempLabel.text = [NSString stringWithFormat:@"%.0f Mo", freeB / m];
                self.condLabel.text = [NSString stringWithFormat:@"libres sur %.0f Mo", total / m];
                self.ringProgress.strokeEnd = (CGFloat)MAX(0.0, MIN(1.0, 1.0 - freeB / total));
            }
        }
    } @catch (...) {}
}

// premier remplissage d'un widget
- (void)prime {
    if ([self.type isEqualToString:@"meteo"] || [self.type isEqualToString:@"previsions"]) {
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
    self.sizeButton.hidden = !e;
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
static BOOL MWIsWeatherType(NSString *t) { return [t isEqualToString:@"meteo"] || [t isEqualToString:@"previsions"]; }

static void MWFetch(NSUInteger idx, NSString *lastErr) {
    NSArray *urls = @[
        [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true&daily=weathercode,temperature_2m_max,temperature_2m_min&timezone=auto", kMWLat, kMWLon],
        [NSString stringWithFormat:@"http://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true&daily=weathercode,temperature_2m_max,temperature_2m_min&timezone=auto", kMWLat, kMWLon],
        [NSString stringWithFormat:@"http://wttr.in/%@?format=j1", kMWCity]
    ];
    if (idx >= urls.count) {
        MWLog([NSString stringWithFormat:@"echec total: %@", lastErr]);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (MWWidgetView *w in gWidgets) {
                if (MWIsWeatherType(w.type)) [w showStatus:[NSString stringWithFormat:@"Météo indisponible (%@)", lastErr ?: @"?"]];
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
                        if (MWIsWeatherType(w.type)) [w applyInfo:info stale:NO];
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

// ---------- grille, placement, edition ----------
static NSInteger MWCols(UIView *lv) { return lv.bounds.size.width > 900.0 ? 5 : 4; }

static CGFloat MWCellW(UIView *lv) { return lv.bounds.size.width / (CGFloat)MWCols(lv); }

// iPad : 4 colonnes x 5 lignes en portrait, 5 x 4 en paysage
static NSInteger MWMaxRows(UIView *lv) { return MWCols(lv) == 5 ? 4 : 5; }

// haut de la 1re ligne et hauteur d'une ligne : lus sur la vraie grille d'icones si possible
static void MWRowGeometry(UIView *lv, CGFloat *top0, CGFloat *ch) {
    *top0 = kMWTop;
    *ch = MWCellW(lv) * 0.86;
    @try {
        if ([lv respondsToSelector:@selector(originForIconAtIndex:)]) {
            gBypass = YES;
            CGPoint p0 = [(SBIconListView *)lv originForIconAtIndex:0];
            CGPoint pr = [(SBIconListView *)lv originForIconAtIndex:(NSUInteger)MWCols(lv)];
            gBypass = NO;
            CGFloat d = pr.y - p0.y;
            if (d > 80.0 && d < 400.0) { *ch = d; *top0 = p0.y - 6.0; }
        }
    } @catch (...) {}
    gBypass = NO;
}

// ou va l'icone numero i quand les widgets occupent des cases : i-eme case libre ;
// les icones en trop (page pleine) vont sur les cases des widgets, au lieu de disparaitre
static NSUInteger MWMappedIndex(UIView *lv, NSUInteger i) {
    NSInteger cols = MWCols(lv), rows = MWMaxRows(lv);
    NSInteger total = cols * rows;
    if (total <= 0 || total > 64 || !gWidgets.count) return i;
    BOOL occ[64];
    for (NSInteger k = 0; k < 64; k++) occ[k] = NO;
    for (MWWidgetView *w in gWidgets) {
        NSInteger col = MAX(0, MIN(w.col, cols - 1));
        NSInteger row = MAX(0, MIN(w.row, rows - w.span));
        for (NSInteger r = row; r < row + w.span && r < rows; r++) occ[r * cols + col] = YES;
    }
    NSUInteger freeSeen = 0;
    for (NSInteger c = 0; c < total; c++) {
        if (occ[c]) continue;
        if (freeSeen == i) return (NSUInteger)c;
        freeSeen++;
    }
    NSUInteger extra = i - freeSeen, seen = 0;
    for (NSInteger c = 0; c < total; c++) {
        if (!occ[c]) continue;
        if (seen == extra) return (NSUInteger)c;
        seen++;
    }
    return i;
}

// remet les icones a leur place apres un changement de widgets
static void MWRelayoutIcons(void) {
    UIView *lv = gHost;
    if (!lv || !gPushAPI) return;
    @try {
        if ([lv respondsToSelector:@selector(layoutIconsNow)]) {
            [UIView animateWithDuration:0.25 animations:^{ [(SBIconListView *)lv layoutIconsNow]; }];
        } else {
            [lv setNeedsLayout];
        }
    } @catch (...) {}
}

static BOOL MWOverlaps(MWWidgetView *me, NSInteger col, NSInteger row, NSInteger span) {
    for (MWWidgetView *o in gWidgets) {
        if (o == me || o.col != col) continue;
        if (row < o.row + o.span && o.row < row + span) return YES;
    }
    return NO;
}

static void MWLayout(UIView *lv) {
    if (!lv || !gWidgets.count) return;
    CGFloat cw = MWCellW(lv), ch = 0, top0 = 0;
    MWRowGeometry(lv, &top0, &ch);
    NSInteger cols = MWCols(lv), maxRows = MWMaxRows(lv);
    for (MWWidgetView *v in gWidgets) {
        NSInteger col = MAX(0, MIN(v.col, cols - 1));
        NSInteger row = MAX(0, MIN(v.row, maxRows - v.span));
        CGFloat h = kMWSize + (v.span - 1) * ch;
        CGRect b = CGRectMake(0, 0, kMWSize, h);
        if (!CGRectEqualToRect(v.bounds, b)) v.bounds = b;
        CGPoint c = CGPointMake((col + 0.5) * cw, top0 + row * ch + h / 2.0);
        if (!CGPointEqualToPoint(v.center, c)) v.center = c;
    }
}

static void MWSaveTypes(void) {
    @try {
        NSMutableArray *a = [NSMutableArray array];
        for (MWWidgetView *w in gWidgets) {
            [a addObject:@{@"type": w.type, @"col": @(w.col), @"row": @(w.row), @"span": @(w.span)}];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:kMWDir withIntermediateDirectories:YES attributes:nil error:nil];
        [a writeToFile:kMWTypesPath atomically:YES];
    } @catch (...) {}
}

// lit les widgets sauvegardes (accepte aussi l'ancien format : liste de noms)
static NSArray *MWLoadSaved(void) {
    @try {
        NSArray *a = [NSArray arrayWithContentsOfFile:kMWTypesPath];
        if ([a isKindOfClass:[NSArray class]]) {
            NSMutableArray *ok = [NSMutableArray array];
            NSMutableArray *seen = [NSMutableArray array];
            for (id e in a) {
                if (ok.count >= kMWMax) break;
                NSString *t = nil; NSInteger col = (NSInteger)ok.count, row = 0, span = 1;
                if ([e isKindOfClass:[NSString class]]) t = e;
                else if ([e isKindOfClass:[NSDictionary class]]) {
                    t = e[@"type"];
                    if (e[@"col"]) col = [e[@"col"] integerValue];
                    if (e[@"row"]) row = [e[@"row"] integerValue];
                    if (e[@"span"]) span = [e[@"span"] integerValue];
                }
                if (![t isKindOfClass:[NSString class]] || ![MWAllTypes() containsObject:t] || [seen containsObject:t]) continue;
                [seen addObject:t];
                [ok addObject:@{@"type": t, @"col": @(col), @"row": @(row), @"span": @(span)}];
            }
            return ok;   // peut etre vide : l'utilisateur a tout supprime
        }
    } @catch (...) {}
    return @[@{@"type": @"meteo", @"col": @0, @"row": @0, @"span": @1}];   // premiere utilisation
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

static void MWScrollLock(BOOL lock) {
    if (lock) {
        UIView *h = gHost;
        for (UIView *v = h.superview; v; v = v.superview) {
            if ([v isKindOfClass:[UIScrollView class]]) {
                gLockedScroll = (UIScrollView *)v;
                gLockedScroll.scrollEnabled = NO;
                break;
            }
        }
    } else {
        UIScrollView *s = gLockedScroll;
        if (s) s.scrollEnabled = YES;
        gLockedScroll = nil;
    }
}

static void MWDismissPicker(void) {
    [gPicker removeFromSuperview];
    gPicker = nil;
}

static void MWAddType(NSString *type) {
    UIView *lv = gHost;
    if (!lv || gWidgets.count >= kMWMax) return;
    for (MWWidgetView *w in gWidgets) { if ([w.type isEqualToString:type]) return; }
    NSInteger cols = MWCols(lv), maxRows = MWMaxRows(lv);
    NSInteger fc = -1, fr = -1;
    for (NSInteger r = 0; r < maxRows && fc < 0; r++) {
        for (NSInteger c = 0; c < cols; c++) {
            if (!MWOverlaps(nil, c, r, 1)) { fc = c; fr = r; break; }
        }
    }
    if (fc < 0) return;
    MWWidgetView *nw = [[MWWidgetView alloc] initWithType:type col:fc row:fr span:1];
    [gWidgets addObject:nw];
    [lv insertSubview:nw atIndex:0];
    [nw setEditing:gEditing];
    MWLayout(lv);
    [nw prime];
    MWSaveTypes();
    MWRelayoutIcons();
    MWLog([NSString stringWithFormat:@"widget ajoute: %@ (col %ld, ligne %ld)", type, (long)fc, (long)fr]);
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
    MWRelayoutIcons();
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
    CGFloat ph = 64 + rows * 54 + 10 + (gPushAPI ? 48 : 0);
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
    if (gPushAPI) {
        CGFloat sy = 64 + rows * 54 + 4;
        UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(18, sy, 230, 36)];
        sl.text = @"Libérer la place (pousser les icônes)";
        sl.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        sl.font = [UIFont systemFontOfSize:14];
        sl.numberOfLines = 2;
        [panel addSubview:sl];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.center = CGPointMake(330 - 18 - sw.bounds.size.width / 2.0, sy + 18);
        sw.on = gPush;
        [sw addTarget:gMgr action:@selector(pushSwitched:) forControlEvents:UIControlEventValueChanged];
        [panel addSubview:sw];
    }
    [lv addSubview:dim];
    gPicker = dim;
}

@implementation MWManager

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

// on ne deplace un widget qu'en mode edition
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) return gEditing;
    return YES;
}

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

- (void)widgetPan:(UIPanGestureRecognizer *)g {
    UIView *lv = gHost;
    MWWidgetView *w = (MWWidgetView *)g.view;
    if (!lv || ![w isKindOfClass:[MWWidgetView class]]) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        w.dragStart = w.center;
        gDragging = YES;
        MWScrollLock(YES);
        [lv bringSubviewToFront:w];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:lv];
        w.center = CGPointMake(w.dragStart.x + t.x, w.dragStart.y + t.y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) {
        MWScrollLock(NO);
        gDragging = NO;
        CGFloat cw = MWCellW(lv), ch = 0, top0 = 0;
        MWRowGeometry(lv, &top0, &ch);
        NSInteger col = (NSInteger)lround(w.center.x / cw - 0.5);
        CGFloat topY = w.center.y - w.bounds.size.height / 2.0;
        NSInteger row = (NSInteger)lround((topY - top0) / ch);
        col = MAX(0, MIN(col, MWCols(lv) - 1));
        row = MAX(0, MIN(row, MWMaxRows(lv) - w.span));
        if (g.state == UIGestureRecognizerStateEnded && !MWOverlaps(w, col, row, w.span)) {
            w.col = col;
            w.row = row;
            MWSaveTypes();
        }
        [lv sendSubviewToBack:w];
        [UIView animateWithDuration:0.2 animations:^{ MWLayout(lv); }];
        MWRelayoutIcons();
    }
}

- (void)deleteTapped:(UIButton *)b {
    UIView *v = b.superview;
    if ([v isKindOfClass:[MWWidgetView class]]) MWRemove((MWWidgetView *)v);
}

- (void)sizeTapped:(UIButton *)b {
    UIView *lv = gHost;
    MWWidgetView *w = (MWWidgetView *)b.superview;
    if (!lv || ![w isKindOfClass:[MWWidgetView class]]) return;
    NSInteger maxRows = MWMaxRows(lv);
    // 1 place -> 2 -> 3 (soit 2 places d'app en plus, vers le bas) -> retour a 1
    for (NSInteger k = 1; k <= 3; k++) {
        NSInteger cand = ((w.span - 1 + k) % 3) + 1;
        if (w.row + cand <= maxRows && !MWOverlaps(w, w.col, w.row, cand)) { w.span = cand; break; }
    }
    MWSaveTypes();
    [UIView animateWithDuration:0.2 animations:^{ MWLayout(lv); }];
    MWRelayoutIcons();
}

- (void)pushSwitched:(UISwitch *)sw {
    gPush = sw.on;
    @try { [@{@"push": @(gPush)} writeToFile:kMWOptions atomically:YES]; } @catch (...) {}
    MWRelayoutIcons();
}

- (void)pickTapped:(UIButton *)b {
    NSString *t = b.accessibilityIdentifier;
    MWDismissPicker();
    if (t) MWAddType(t);
}

- (void)dismissPicker { MWDismissPicker(); }

- (void)tick:(NSTimer *)t {
    gTicks++;
    BOOL hasWeather = NO;
    for (MWWidgetView *w in gWidgets) {
        if (MWIsWeatherType(w.type)) hasWeather = YES; else [w refresh];
    }
    if (hasWeather && gTicks % 60 == 0) MWFetch(0, nil);   // toutes les 30 minutes
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
    @try {
        NSDictionary *o = [NSDictionary dictionaryWithContentsOfFile:kMWOptions];
        if ([o isKindOfClass:[NSDictionary class]] && o[@"push"]) gPush = [o[@"push"] boolValue];
    } @catch (...) {}
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    [[NSNotificationCenter defaultCenter] addObserver:gMgr selector:@selector(battChanged) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:gMgr selector:@selector(battChanged) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    for (NSDictionary *d in MWLoadSaved()) {
        MWWidgetView *w = [[MWWidgetView alloc] initWithType:d[@"type"] col:[d[@"col"] integerValue] row:[d[@"row"] integerValue] span:[d[@"span"] integerValue]];
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
    MWLog([NSString stringWithFormat:@"accroche a %@ (page %ld, x=%.0f, largeur=%.0f, hauteur=%.0f)", NSStringFromClass([lv class]), (long)idx, lv.frame.origin.x, lv.bounds.size.width, lv.bounds.size.height]);
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
            if (!gDragging) MWLayout(lv);
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

%hook SBIconListView
- (void)layoutSubviews {
    %orig;
    MWAttach(self);
}
%end

%group MWPushHook
%hook SBIconListView
- (CGPoint)originForIconAtIndex:(NSUInteger)index {
    if (gBypass || !gPush || (UIView *)self != gHost) return %orig;
    return %orig(MWMappedIndex((UIView *)self, index));
}
%end
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
    Class lc = objc_getClass("SBIconListView");
    if (lc && class_getInstanceMethod(lc, @selector(originForIconAtIndex:))) {
        gPushAPI = YES;
        %init(MWPushHook);
    }
    // diagnostic : noms de methodes utiles de la liste d'icones (aide a ajuster si besoin)
    if (lc) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(lc, &n);
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++) {
            NSString *nm = NSStringFromSelector(method_getName(ms[i]));
            NSString *l = [nm lowercaseString];
            if ([l rangeOfString:@"origin"].location != NSNotFound || [l rangeOfString:@"coordinate"].location != NSNotFound ||
                [l rangeOfString:@"layouticons"].location != NSNotFound || [l rangeOfString:@"maxicons"].location != NSNotFound) {
                [names addObject:nm];
            }
        }
        if (ms) free(ms);
        MWLog([NSString stringWithFormat:@"SBIconListView: %@", [names componentsJoinedByString:@", "]]);
    }
    MWLog([NSString stringWithFormat:@"MeteoWidget 3.1.0 charge (placement des icones: %d)", (int)gPushAPI]);
}
