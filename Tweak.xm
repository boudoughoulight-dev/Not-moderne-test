// MeteoWidget 5.0.0 - widgets style iOS 18 pour iOS 9 (SpringBoard, armv7)
// - widgets sur TOUTES les pages de l'ecran d'accueil, 5 widgets maximum par page
// - mode edition (tremblement d'iOS) : bouton « + » en haut a gauche de la page -> petite fenetre pour choisir un widget
// - appui long sur un widget : edition ; glisser pour deplacer ; poignees d'angle (style iOS 18) pour agrandir
//   (+1 place d'app a chaque cran, 2 places max de chaque cote) ; tout le contenu grandit avec le widget
// - option « Liberer la place » : les icones sont poussees hors des cases occupees par les widgets
// - 11 widgets : Meteo, Previsions, Musique, Horloge, Date, Mois, Batterie, Stockage, Memoire, Lune, Nouvel An
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <unistd.h>
#include <dlfcn.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>

static NSString *const kMWCity = @"Libreville";
static const double kMWLat = 0.4162;
static const double kMWLon = 9.4673;
static const CGFloat kMWBaseW = 170.0;       // taille de reference du contenu
static const CGFloat kMWBaseH = 148.0;
static const CGFloat kMWTop = 62.0;
static const CGFloat kMWInsetX = 10.0;       // marge a gauche/droite : un widget ne touche jamais une icone
static const CGFloat kMWUpOff = 6.0;         // le widget commence un peu au-dessus de la ligne d'icones
static const CGFloat kMWDownOff = 18.0;      // et s'arrete avant la ligne suivante
static const NSUInteger kMWMax = 5;          // widgets max par page
static NSString *const kMWDir = @"/var/mobile/Library/MeteoWidget";
static NSString *const kMWCache = @"/var/mobile/Library/MeteoWidget/cache.plist";
static NSString *const kMWTypesPath = @"/var/mobile/Library/MeteoWidget/widgets.plist";
static NSString *const kMWOptions = @"/var/mobile/Library/MeteoWidget/options.plist";

@class MWWidgetView;
@class MWManager;
@class MWPage;

@interface SBIconListView : UIView
- (CGPoint)originForIconAtIndex:(NSUInteger)index;
- (void)layoutIconsNow;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isEditing;
- (void)setIsEditing:(BOOL)editing;
@end

static NSMutableDictionary *gPages = nil;    // @(numero de page) -> MWPage
static NSMutableArray *gSaved = nil;         // widgets sauvegardes (dictionnaires)
static BOOL gEditing = NO;
static BOOL gSBEditAPI = NO;
static BOOL gBypass = NO;                    // appel interne : position d'origine des icones
static BOOL gPush = YES;                     // option : pousser les icones hors des cases des widgets
static BOOL gPushAPI = NO;                   // la methode de placement des icones existe sur cet iOS
static BOOL gDragging = NO;
static UIView *gPicker = nil;
static __weak MWPage *gPickerPage = nil;
static MWManager *gMgr = nil;
static NSUInteger gTicks = 0;
static BOOL gPlaceReady = YES;               // NO tant que la ville de l'iPad n'est pas trouvee
static UIView *gGallery = nil;
static __weak MWWidgetView *gGalleryTarget = nil;
static double gLat = kMWLat;                 // position utilisee pour la meteo (Libreville par defaut)
static double gLon = kMWLon;
static NSString *gCity = nil;
static NSString *const kMWPlace = @"/var/mobile/Library/MeteoWidget/place.plist";

static __weak UIScrollView *gLockedScroll = nil;

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

// ---------- langue, region et heure de l'iPad ----------
// les textes sont ecrits en francais ; MWL les traduit selon la langue de l'iPad (fr, en, es ; autres langues -> anglais)
static NSString *MWL(NSString *fr) {
    static NSDictionary *en = nil, *es = nil;
    static NSString *lang = nil;
    if (!lang) {
        NSString *l = [[NSLocale preferredLanguages] firstObject] ?: @"en";
        lang = [[[l componentsSeparatedByString:@"-"] firstObject] lowercaseString];
        en = @{@"Météo": @"Weather", @"Prévisions": @"Forecast", @"Musique": @"Music", @"Horloge": @"Clock", @"Date": @"Date", @"Mois": @"Month",
               @"Photo": @"Photo", @"Photos": @"Photos", @"Batterie": @"Battery", @"Batteries": @"Batteries", @"Stockage": @"Storage",
               @"Mémoire (RAM)": @"Memory (RAM)", @"Lune": @"Moon", @"Nouvel An": @"New Year",
               @"Ciel dégagé": @"Clear sky", @"Plutôt dégagé": @"Mostly clear", @"Peu nuageux": @"Partly cloudy", @"Couvert": @"Overcast",
               @"Brouillard": @"Fog", @"Bruine": @"Drizzle", @"Pluie": @"Rain", @"Neige": @"Snow", @"Averses": @"Showers",
               @"Averses de neige": @"Snow showers", @"Orage": @"Thunderstorm", @"Chargement...": @"Loading...",
               @"Hors ligne (dernière météo)": @"Offline (last weather)", @"Mise à jour": @"Updated", @"Météo indisponible": @"Weather unavailable",
               @"Pas de prévisions": @"No forecast", @"Chargée": @"Charged", @"En charge": @"Charging", @"Sur batterie": @"On battery",
               @"libres sur": @"free of", @"Go": @"GB", @"Mo": @"MB", @"Max": @"Hi", @"Min": @"Lo", @"jour restant": @"day left",
               @"jours restants": @"days left", @"Nouvelle lune": @"New moon", @"Pleine lune": @"Full moon", @"Lune croissante": @"Waxing moon",
               @"Lune décroissante": @"Waning moon", @"Rien en lecture": @"Nothing playing", @"Indisponible": @"Unavailable",
               @"Touche pour choisir une photo": @"Tap to choose a photo", @"Widgets": @"Widgets", @"Aucune photo trouvée": @"No photos found",
               @"5 widgets maximum sur cette page (mémoire de l'iPad 2). Supprime-en un d'abord.": @"5 widgets maximum on this page (iPad 2 memory). Remove one first.",
               @"Tous les widgets sont déjà sur cette page.": @"All widgets are already on this page.",
               @"Libérer la place (pousser les icônes)": @"Make room (push icons away)"};
        es = @{@"Météo": @"Clima", @"Prévisions": @"Pronóstico", @"Musique": @"Música", @"Horloge": @"Reloj", @"Date": @"Fecha", @"Mois": @"Mes",
               @"Photo": @"Foto", @"Photos": @"Fotos", @"Batterie": @"Batería", @"Batteries": @"Baterías", @"Stockage": @"Almacenamiento",
               @"Mémoire (RAM)": @"Memoria (RAM)", @"Lune": @"Luna", @"Nouvel An": @"Año Nuevo",
               @"Ciel dégagé": @"Despejado", @"Plutôt dégagé": @"Mayormente despejado", @"Peu nuageux": @"Parcialmente nublado", @"Couvert": @"Nublado",
               @"Brouillard": @"Niebla", @"Bruine": @"Llovizna", @"Pluie": @"Lluvia", @"Neige": @"Nieve", @"Averses": @"Chubascos",
               @"Averses de neige": @"Chubascos de nieve", @"Orage": @"Tormenta", @"Chargement...": @"Cargando...",
               @"Hors ligne (dernière météo)": @"Sin conexión (último dato)", @"Mise à jour": @"Actualizado", @"Météo indisponible": @"Clima no disponible",
               @"Pas de prévisions": @"Sin pronóstico", @"Chargée": @"Cargada", @"En charge": @"Cargando", @"Sur batterie": @"Con batería",
               @"libres sur": @"libres de", @"Go": @"GB", @"Mo": @"MB", @"Max": @"Máx", @"Min": @"Mín", @"jour restant": @"día restante",
               @"jours restants": @"días restantes", @"Nouvelle lune": @"Luna nueva", @"Pleine lune": @"Luna llena", @"Lune croissante": @"Luna creciente",
               @"Lune décroissante": @"Luna menguante", @"Rien en lecture": @"Nada en reproducción", @"Indisponible": @"No disponible",
               @"Touche pour choisir une photo": @"Toca para elegir una foto", @"Widgets": @"Widgets", @"Aucune photo trouvée": @"No se encontraron fotos",
               @"5 widgets maximum sur cette page (mémoire de l'iPad 2). Supprime-en un d'abord.": @"Máximo 5 widgets en esta página (memoria del iPad 2). Elimina uno primero.",
               @"Tous les widgets sont déjà sur cette page.": @"Todos los widgets ya están en esta página.",
               @"Libérer la place (pousser les icônes)": @"Hacer espacio (apartar los iconos)"};
    }
    if ([lang isEqualToString:@"fr"]) return fr;
    NSString *r = [lang isEqualToString:@"es"] ? es[fr] : nil;
    return r ?: (en[fr] ?: fr);
}

// Fahrenheit dans les pays qui l'utilisent (selon la region de l'iPad)
static BOOL MWFahrenheit(void) {
    NSString *cc = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return [@[@"US", @"BS", @"BZ", @"KY", @"PW", @"FM", @"MH", @"LR"] containsObject:cc ?: @""];
}

static int MWT(double celsius) { return (int)lround(MWFahrenheit() ? celsius * 9.0 / 5.0 + 32.0 : celsius); }

// heure au format de l'iPad (24 h ou 12 h)
static NSString *MWTimeFormat(void) {
    return [NSDateFormatter dateFormatFromTemplate:@"jmm" options:0 locale:[NSLocale currentLocale]] ?: @"HH:mm";
}

static NSString *MWDateTpl(NSString *tpl) {
    return [NSDateFormatter dateFormatFromTemplate:tpl options:0 locale:[NSLocale currentLocale]] ?: tpl;
}

// initiales des jours de la semaine, dans la langue de l'iPad, en commencant par le 1er jour de la semaine
static NSString *MWWeekHeader(NSInteger fw) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale currentLocale];
    NSArray *sy = f.shortWeekdaySymbols;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSInteger i = 0; i < 7 && sy.count == 7; i++) {
        NSString *x = [sy[(fw - 1 + i) % 7] stringByReplacingOccurrencesOfString:@"." withString:@""];
        if (x.length > 2) x = [x substringToIndex:2];
        [parts addObject:[[x capitalizedString] stringByPaddingToLength:2 withString:@" " startingAtIndex:0]];
    }
    return [[parts componentsJoinedByString:@" "] stringByAppendingString:@"\n"];
}

// ---------- types de widgets ----------
static NSArray *MWAllTypes(void) {
    return @[@"meteo", @"previsions", @"musique", @"horloge", @"date", @"mois", @"photo", @"batterie", @"stockage", @"memoire", @"lune", @"decompte"];
}

static NSString *MWTypeTitle(NSString *t) {
    NSDictionary *emo = @{@"meteo": @"☁️", @"previsions": @"📆", @"musique": @"🎵", @"horloge": @"🕐", @"date": @"📅", @"mois": @"🗓",
                          @"photo": @"🖼", @"batterie": @"🔋", @"stockage": @"💾", @"memoire": @"🧠", @"lune": @"🌙", @"decompte": @"🎆"};
    NSDictionary *nom = @{@"meteo": @"Météo", @"previsions": @"Prévisions", @"musique": @"Musique", @"horloge": @"Horloge", @"date": @"Date", @"mois": @"Mois",
                          @"photo": @"Photo", @"batterie": @"Batterie", @"stockage": @"Stockage", @"memoire": @"Mémoire (RAM)", @"lune": @"Lune", @"decompte": @"Nouvel An"};
    if (!nom[t]) return t;
    return [NSString stringWithFormat:@"%@  %@", emo[t], MWL(nom[t])];
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
    NSString *k = @"Météo";
    if (code == 0) k = @"Ciel dégagé";
    else if (code == 1) k = @"Plutôt dégagé";
    else if (code == 2) k = @"Peu nuageux";
    else if (code == 3) k = @"Couvert";
    else if (code == 45 || code == 48) k = @"Brouillard";
    else if (code >= 51 && code <= 57) k = @"Bruine";
    else if (code >= 61 && code <= 67) k = @"Pluie";
    else if (code >= 71 && code <= 77) k = @"Neige";
    else if (code >= 80 && code <= 82) k = @"Averses";
    else if (code == 85 || code == 86) k = @"Averses de neige";
    else if (code >= 95) k = @"Orage";
    return MWL(k);
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
    df.locale = [NSLocale currentLocale];
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

// ---------- infos systeme (memoire) ----------
static uint64_t MWFreeRAM(void) {
    vm_statistics_data_t vm;
    mach_msg_type_number_t cnt = HOST_VM_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_VM_INFO, (host_info_t)&vm, &cnt) != KERN_SUCCESS) return 0;
    uint64_t page = (uint64_t)sysconf(_SC_PAGESIZE);
    return ((uint64_t)vm.free_count + (uint64_t)vm.inactive_count) * page;
}

// ---------- images ----------
// miniature via ImageIO : pas de decodage complet de la photo (leger pour l'iPad 2) et orientation EXIF geree.
// les fonctions sont trouvees avec dlsym : aucun framework a ajouter au Makefile.
static UIImage *MWImageIOThumb(NSString *path, CGFloat maxDim) {
    static CGImageSourceRef (*createSrc)(CFURLRef, CFDictionaryRef) = NULL;
    static CGImageRef (*createThumb)(CGImageSourceRef, size_t, CFDictionaryRef) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createSrc = (CGImageSourceRef (*)(CFURLRef, CFDictionaryRef))dlsym(RTLD_DEFAULT, "CGImageSourceCreateWithURL");
        createThumb = (CGImageRef (*)(CGImageSourceRef, size_t, CFDictionaryRef))dlsym(RTLD_DEFAULT, "CGImageSourceCreateThumbnailAtIndex");
    });
    if (!createSrc || !createThumb || !path.length) return nil;
    CGImageSourceRef src = createSrc((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return nil;
    NSDictionary *opt = @{@"kCGImageSourceCreateThumbnailFromImageAlways": @YES,
                          @"kCGImageSourceCreateThumbnailWithTransform": @YES,
                          @"kCGImageSourceShouldCache": @NO,
                          @"kCGImageSourceThumbnailMaxPixelSize": @(maxDim)};
    CGImageRef cg = createThumb(src, 0, (__bridge CFDictionaryRef)opt);
    CFRelease(src);
    if (!cg) return nil;
    UIImage *im = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return im;
}

static UIImage *MWLoadScaled(NSString *path, CGFloat maxDim) {
    UIImage *t = MWImageIOThumb(path, maxDim);
    if (t && t.size.width > 0 && t.size.height > 0) return t;
    // secours : chargement UIKit classique
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    UIImage *im = data.length ? [UIImage imageWithData:data] : [UIImage imageWithContentsOfFile:path];
    if (!im || im.size.width <= 0 || im.size.height <= 0) {
        MWLog([NSString stringWithFormat:@"photo illisible: %@", path]);
        return nil;
    }
    CGFloat m = MAX(im.size.width, im.size.height);
    if (m <= maxDim) return im;
    CGFloat sc = maxDim / m;
    CGSize ns = CGSizeMake(floor(im.size.width * sc), floor(im.size.height * sc));
    UIGraphicsBeginImageContextWithOptions(ns, NO, 1.0);   // NO : si le dessin echoue, on n'obtient pas un carre noir
    [im drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    UIImage *o = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return o;
}

static UIImage *MWSquareThumb(UIImage *im, CGFloat side) {
    if (!im || im.size.width <= 0 || im.size.height <= 0) return nil;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 1.0);
    CGFloat s = MAX(side / im.size.width, side / im.size.height);
    CGFloat w = im.size.width * s, h = im.size.height * s;
    [im drawInRect:CGRectMake((side - w) / 2.0, (side - h) / 2.0, w, h)];
    UIImage *o = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return o;
}

// icones vectorielles des boutons de musique : 0 precedent, 1 lecture, 2 pause, 3 suivant
static UIImage *MWGlyph(int kind) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(64, 64), NO, 0);
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (kind == 1 || kind == 2) {
        [[UIColor whiteColor] setFill];
        CGContextFillEllipseInRect(c, CGRectMake(2, 2, 60, 60));
        [[UIColor colorWithWhite:0.1 alpha:1.0] setFill];
        if (kind == 1) {
            UIBezierPath *t = [UIBezierPath bezierPath];
            [t moveToPoint:CGPointMake(25, 18)]; [t addLineToPoint:CGPointMake(25, 46)]; [t addLineToPoint:CGPointMake(48, 32)]; [t closePath];
            [t fill];
        } else {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(22, 19, 8, 26) cornerRadius:2.5] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(34, 19, 8, 26) cornerRadius:2.5] fill];
        }
    } else {
        [[UIColor colorWithWhite:1.0 alpha:0.95] setFill];
        UIBezierPath *t = [UIBezierPath bezierPath];
        if (kind == 0) {
            [t moveToPoint:CGPointMake(48, 16)]; [t addLineToPoint:CGPointMake(48, 48)]; [t addLineToPoint:CGPointMake(22, 32)]; [t closePath];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(14, 16, 6, 32) cornerRadius:2.5] fill];
        } else {
            [t moveToPoint:CGPointMake(16, 16)]; [t addLineToPoint:CGPointMake(16, 48)]; [t addLineToPoint:CGPointMake(42, 32)]; [t closePath];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(44, 16, 6, 32) cornerRadius:2.5] fill];
        }
        [t fill];
    }
    UIImage *im = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return im;
}

// ---------- musique (MediaRemote, charge a l'execution) ----------
static void (*gMRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *)) = NULL;
static void (*gMRSend)(int, id) = NULL;

static void MWLoadMR(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!h) { MWLog(@"MediaRemote introuvable"); return; }
    *(void **)(&gMRGetInfo) = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    *(void **)(&gMRSend) = dlsym(h, "MRMediaRemoteSendCommand");
    MWLog([NSString stringWithFormat:@"MediaRemote: info=%d commande=%d", gMRGetInfo != NULL, gMRSend != NULL]);
}

// ---------- classes ----------
static UIColor *MWRGB(CGFloat r, CGFloat g, CGFloat b) { return [UIColor colorWithRed:r green:g blue:b alpha:1.0]; }

@interface MWPage : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, weak) UIView *host;
@property (nonatomic, strong) NSMutableArray *widgets;
@property (nonatomic, strong) UIButton *plusButton;
@end

@implementation MWPage
@end

@interface MWWidgetView : UIView
@property (nonatomic, copy) NSString *type;
@property (nonatomic, weak) MWPage *page;
@property (nonatomic, assign) NSInteger col;
@property (nonatomic, assign) NSInteger row;
@property (nonatomic, assign) NSInteger up;         // places gagnees vers le haut (0 a 2)
@property (nonatomic, assign) NSInteger down;
@property (nonatomic, assign) NSInteger left;
@property (nonatomic, assign) NSInteger right;
@property (nonatomic, assign) NSInteger i0up;       // tailles au debut d'un geste d'agrandissement
@property (nonatomic, assign) NSInteger i0down;
@property (nonatomic, assign) NSInteger i0left;
@property (nonatomic, assign) NSInteger i0right;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGFloat curScale;
@property (nonatomic, assign) NSUInteger artSig;
@property (nonatomic, strong) UILabel *cityLabel;
@property (nonatomic, strong) UILabel *tempLabel;
@property (nonatomic, strong) UILabel *iconLabel;
@property (nonatomic, strong) UILabel *condLabel;
@property (nonatomic, strong) UILabel *hiloLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *bodyLabel;
@property (nonatomic, strong) UIImageView *artView;
@property (nonatomic, strong) UIImageView *photoView;
@property (nonatomic, copy) NSString *photoPath;
@property (nonatomic, weak) UIView *dragSup;
@property (nonatomic, strong) UIButton *prevBtn;
@property (nonatomic, strong) UIButton *playBtn;
@property (nonatomic, strong) UIButton *nextBtn;
@property (nonatomic, strong) CAGradientLayer *grad;
@property (nonatomic, strong) UIButton *delButton;
@property (nonatomic, strong) UIView *handleBR;
@property (nonatomic, strong) UIView *handleTL;
@property (nonatomic, strong) CAShapeLayer *ringTrack;
@property (nonatomic, strong) CAShapeLayer *ringProgress;
@property (nonatomic, strong) NSArray *tracked;        // vues du contenu (mises a l'echelle avec le widget)
@property (nonatomic, strong) NSArray *baseFrames;
@property (nonatomic, strong) NSArray *baseSizes;
- (instancetype)initWithType:(NSString *)type col:(NSInteger)col row:(NSInteger)row up:(NSInteger)up down:(NSInteger)down left:(NSInteger)left right:(NSInteger)right;
- (void)applyInfo:(NSDictionary *)info stale:(BOOL)stale;
- (void)showStatus:(NSString *)s;
- (void)refresh;
- (void)applyPhoto;
- (void)prime;
- (void)setEditing:(BOOL)e;
@end

static void MWFetch(NSUInteger idx, NSString *lastErr);

@interface MWManager : NSObject <UIGestureRecognizerDelegate>
- (void)widgetLongPress:(UILongPressGestureRecognizer *)g;
- (void)widgetTap:(UITapGestureRecognizer *)g;
- (void)widgetPan:(UIPanGestureRecognizer *)g;
- (void)handlePan:(UIPanGestureRecognizer *)g;
- (void)deleteTapped:(UIButton *)b;
- (void)plusTapped:(UIButton *)b;
- (void)musicTapped:(UIButton *)b;
- (void)pickTapped:(UIButton *)b;
- (void)pushSwitched:(UISwitch *)sw;
- (void)photoTapped:(UIButton *)b;
- (void)dismissGallery;
- (void)dismissPicker;
- (void)tick:(NSTimer *)t;
- (void)musicTick:(NSTimer *)t;
- (void)battChanged;
@end

static void MWEnterEditing(void);
static void MWExitEditing(void);
static void MWDismissGallery(void);

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

- (void)setGradFrom:(UIColor *)a to:(UIColor *)b {
    self.grad.colors = @[(id)a.CGColor, (id)b.CGColor];
}

- (void)setupRingWithColor:(UIColor *)color {
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(85, 66) radius:40 startAngle:-M_PI_2 endAngle:(3.0 * M_PI_2) clockwise:YES];
    self.ringTrack = [CAShapeLayer layer];
    self.ringTrack.bounds = CGRectMake(0, 0, kMWBaseW, kMWBaseH);
    self.ringTrack.position = CGPointMake(kMWBaseW / 2.0, kMWBaseH / 2.0);
    self.ringTrack.path = path.CGPath;
    self.ringTrack.fillColor = [UIColor clearColor].CGColor;
    self.ringTrack.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    self.ringTrack.lineWidth = 9.0;
    [self.layer addSublayer:self.ringTrack];
    self.ringProgress = [CAShapeLayer layer];
    self.ringProgress.bounds = CGRectMake(0, 0, kMWBaseW, kMWBaseH);
    self.ringProgress.position = CGPointMake(kMWBaseW / 2.0, kMWBaseH / 2.0);
    self.ringProgress.path = path.CGPath;
    self.ringProgress.fillColor = [UIColor clearColor].CGColor;
    self.ringProgress.strokeColor = color.CGColor;
    self.ringProgress.lineWidth = 9.0;
    self.ringProgress.lineCap = kCALineCapRound;
    self.ringProgress.strokeEnd = 0.0;
    [self.layer addSublayer:self.ringProgress];
    self.tempLabel.frame = CGRectMake(35, 48, 100, 36);
    self.tempLabel.font = [UIFont systemFontOfSize:27 weight:UIFontWeightMedium];
    self.tempLabel.textAlignment = NSTextAlignmentCenter;
    self.condLabel.frame = CGRectMake(10, 116, 150, 18);
    self.condLabel.textAlignment = NSTextAlignmentCenter;
    self.iconLabel.hidden = YES;
    self.hiloLabel.hidden = YES;
}

- (UIButton *)makeMusicButton:(int)glyph frame:(CGRect)f tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = f;
    [b setImage:MWGlyph(glyph) forState:UIControlStateNormal];
    b.imageView.contentMode = UIViewContentModeScaleAspectFit;
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    b.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    b.adjustsImageWhenHighlighted = YES;
    b.tag = tag;
    [b addTarget:gMgr action:@selector(musicTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

// poignee d'angle facon iOS 18 : un quart de cercle blanc
- (UIView *)makeHandle:(BOOL)bottomRight tag:(NSInteger)tag {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    h.tag = tag;
    h.backgroundColor = [UIColor clearColor];
    CAShapeLayer *l = [CAShapeLayer layer];
    UIBezierPath *p = bottomRight
        ? [UIBezierPath bezierPathWithArcCenter:CGPointMake(14, 14) radius:20 startAngle:0 endAngle:M_PI_2 clockwise:YES]
        : [UIBezierPath bezierPathWithArcCenter:CGPointMake(30, 30) radius:20 startAngle:M_PI endAngle:(3.0 * M_PI_2) clockwise:YES];
    l.path = p.CGPath;
    l.fillColor = [UIColor clearColor].CGColor;
    l.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;
    l.lineWidth = 4.5;
    l.lineCap = kCALineCapRound;
    l.shadowColor = [UIColor blackColor].CGColor;
    l.shadowOpacity = 0.35;
    l.shadowRadius = 2.0;
    l.shadowOffset = CGSizeMake(0, 1);
    [h.layer addSublayer:l];
    UIPanGestureRecognizer *pn = [[UIPanGestureRecognizer alloc] initWithTarget:gMgr action:@selector(handlePan:)];
    pn.maximumNumberOfTouches = 1;
    [h addGestureRecognizer:pn];
    h.hidden = YES;
    [self addSubview:h];
    return h;
}

- (instancetype)initWithType:(NSString *)type col:(NSInteger)col row:(NSInteger)row up:(NSInteger)up down:(NSInteger)down left:(NSInteger)left right:(NSInteger)right {
    self = [super initWithFrame:CGRectMake(0, 0, kMWBaseW, kMWBaseH)];
    if (!self) return nil;
    self.type = type;
    self.col = col;
    self.row = row;
    self.up = MAX(0, MIN(2, up));
    self.down = MAX(0, MIN(2, down));
    self.left = MAX(0, MIN(2, left));
    self.right = MAX(0, MIN(2, right));
    self.curScale = 1.0;
    self.userInteractionEnabled = YES;
    self.layer.cornerRadius = 26.0;
    self.layer.masksToBounds = YES;

    self.grad = [CAGradientLayer layer];
    self.grad.frame = CGRectMake(0, 0, kMWBaseW, kMWBaseH);
    [self.layer insertSublayer:self.grad atIndex:0];

    self.cityLabel = [self makeLabel:CGRectMake(14, 10, 142, 20) font:[UIFont boldSystemFontOfSize:15]];
    self.tempLabel = [self makeLabel:CGRectMake(14, 28, 100, 50) font:[UIFont systemFontOfSize:42 weight:UIFontWeightLight]];
    self.iconLabel = [self makeLabel:CGRectMake(108, 32, 52, 44) font:[UIFont systemFontOfSize:34]];
    self.iconLabel.textAlignment = NSTextAlignmentCenter;
    self.condLabel = [self makeLabel:CGRectMake(14, 84, 142, 18) font:[UIFont boldSystemFontOfSize:13]];
    self.hiloLabel = [self makeLabel:CGRectMake(14, 102, 142, 16) font:[UIFont systemFontOfSize:12]];
    self.statusLabel = [self makeLabel:CGRectMake(14, 126, 142, 14) font:[UIFont systemFontOfSize:9]];
    self.bodyLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 32, 146, 106)];
    self.bodyLabel.backgroundColor = [UIColor clearColor];
    self.bodyLabel.numberOfLines = 0;
    self.bodyLabel.hidden = YES;
    [self addSubview:self.bodyLabel];

    UIColor *w1 = [UIColor colorWithWhite:1.0 alpha:1.0];
    UIColor *w2 = [UIColor colorWithWhite:1.0 alpha:0.9];
    UIColor *w3 = [UIColor colorWithWhite:1.0 alpha:0.7];
    NSMutableArray *extra = [NSMutableArray array];   // vues en plus a mettre a l'echelle

    if ([type isEqualToString:@"horloge"]) {
        [self setGradFrom:MWRGB(0.24, 0.25, 0.31) to:MWRGB(0.06, 0.06, 0.11)];
        self.cityLabel.text = MWL(@"Horloge");
        self.tempLabel.frame = CGRectMake(14, 34, 142, 56);
        self.tempLabel.font = [UIFont systemFontOfSize:50 weight:UIFontWeightLight];
        self.iconLabel.hidden = YES;
        self.condLabel.frame = CGRectMake(14, 100, 142, 18);
    } else if ([type isEqualToString:@"batterie"]) {
        [self setGradFrom:MWRGB(0.14, 0.14, 0.15) to:MWRGB(0.05, 0.05, 0.06)];
        self.cityLabel.text = MWL(@"Batteries");
        [self setupRingWithColor:MWRGB(0.30, 0.85, 0.39)];
    } else if ([type isEqualToString:@"stockage"]) {
        [self setGradFrom:MWRGB(0.14, 0.14, 0.15) to:MWRGB(0.05, 0.05, 0.06)];
        self.cityLabel.text = MWL(@"Stockage");
        [self setupRingWithColor:MWRGB(0.25, 0.60, 1.0)];
    } else if ([type isEqualToString:@"memoire"]) {
        [self setGradFrom:MWRGB(0.14, 0.14, 0.15) to:MWRGB(0.05, 0.05, 0.06)];
        self.cityLabel.text = MWL(@"Mémoire (RAM)");
        [self setupRingWithColor:MWRGB(1.0, 0.62, 0.0)];
    } else if ([type isEqualToString:@"date"]) {
        [self setGradFrom:MWRGB(1.0, 1.0, 1.0) to:MWRGB(0.90, 0.90, 0.94)];
        w1 = [UIColor colorWithWhite:0.08 alpha:1.0];
        w2 = [UIColor colorWithWhite:0.15 alpha:0.9];
        w3 = [UIColor colorWithWhite:0.3 alpha:0.7];
        self.tempLabel.frame = CGRectMake(14, 28, 142, 68);
        self.tempLabel.font = [UIFont systemFontOfSize:58 weight:UIFontWeightLight];
        self.iconLabel.hidden = YES;
        self.condLabel.frame = CGRectMake(14, 100, 142, 18);
    } else if ([type isEqualToString:@"mois"]) {
        [self setGradFrom:MWRGB(0.18, 0.18, 0.20) to:MWRGB(0.07, 0.07, 0.09)];
        self.tempLabel.hidden = YES;
        self.iconLabel.hidden = YES;
        self.condLabel.hidden = YES;
        self.hiloLabel.hidden = YES;
        self.statusLabel.hidden = YES;
        self.bodyLabel.hidden = NO;
        self.bodyLabel.frame = CGRectMake(12, 30, 146, 108);
    } else if ([type isEqualToString:@"previsions"]) {
        [self setGradFrom:MWRGB(0.33, 0.62, 0.95) to:MWRGB(0.16, 0.38, 0.80)];
        self.cityLabel.text = [NSString stringWithFormat:@"%@ · %@", MWL(@"Prévisions"), gCity ?: kMWCity];
        self.tempLabel.hidden = YES;
        self.iconLabel.hidden = YES;
        self.condLabel.hidden = YES;
        self.hiloLabel.hidden = YES;
        self.bodyLabel.hidden = NO;
        self.bodyLabel.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
        self.bodyLabel.text = MWL(@"Chargement...");
        self.bodyLabel.frame = CGRectMake(14, 32, 146, 100);
    } else if ([type isEqualToString:@"photo"]) {
        [self setGradFrom:MWRGB(0.24, 0.24, 0.28) to:MWRGB(0.08, 0.08, 0.10)];
        self.cityLabel.hidden = YES;
        self.tempLabel.hidden = YES;
        self.hiloLabel.hidden = YES;
        self.statusLabel.hidden = YES;
        self.iconLabel.frame = CGRectMake(14, 24, 142, 58);
        self.iconLabel.font = [UIFont systemFontOfSize:46];
        self.iconLabel.text = @"📷";
        self.condLabel.frame = CGRectMake(10, 88, 150, 36);
        self.condLabel.numberOfLines = 2;
        self.condLabel.textAlignment = NSTextAlignmentCenter;
        self.condLabel.adjustsFontSizeToFitWidth = NO;
        self.condLabel.font = [UIFont systemFontOfSize:12];
        self.condLabel.text = MWL(@"Touche pour choisir une photo");
        self.photoView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, kMWBaseW, kMWBaseH)];
        self.photoView.contentMode = UIViewContentModeScaleAspectFill;
        self.photoView.clipsToBounds = YES;
        self.photoView.hidden = YES;
        [self insertSubview:self.photoView atIndex:0];
    } else if ([type isEqualToString:@"musique"]) {
        [self setGradFrom:MWRGB(0.46, 0.14, 0.22) to:MWRGB(0.13, 0.05, 0.10)];
        self.tempLabel.hidden = YES;
        self.iconLabel.hidden = YES;
        self.hiloLabel.hidden = YES;
        self.statusLabel.hidden = YES;
        self.artView = [[UIImageView alloc] initWithFrame:CGRectMake(12, 12, 62, 62)];
        self.artView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
        self.artView.layer.cornerRadius = 11.0;
        self.artView.layer.masksToBounds = YES;
        self.artView.contentMode = UIViewContentModeScaleAspectFill;
        [self addSubview:self.artView];
        [extra addObject:self.artView];
        self.cityLabel.frame = CGRectMake(82, 12, 78, 38);
        self.cityLabel.numberOfLines = 2;
        self.cityLabel.adjustsFontSizeToFitWidth = NO;
        self.cityLabel.font = [UIFont boldSystemFontOfSize:13];
        self.cityLabel.text = MWL(@"Musique");
        self.condLabel.frame = CGRectMake(82, 54, 78, 16);
        self.condLabel.font = [UIFont systemFontOfSize:11];
        self.condLabel.text = MWL(@"Rien en lecture");
        self.prevBtn = [self makeMusicButton:0 frame:CGRectMake(24, 100, 30, 30) tag:1];
        self.playBtn = [self makeMusicButton:1 frame:CGRectMake(64, 94, 42, 42) tag:2];
        self.nextBtn = [self makeMusicButton:3 frame:CGRectMake(116, 100, 30, 30) tag:3];
        [extra addObjectsFromArray:@[self.prevBtn, self.playBtn, self.nextBtn]];
    } else if ([type isEqualToString:@"lune"]) {
        [self setGradFrom:MWRGB(0.12, 0.14, 0.34) to:MWRGB(0.03, 0.04, 0.13)];
        self.cityLabel.text = MWL(@"Lune");
        self.iconLabel.frame = CGRectMake(12, 34, 70, 64);
        self.iconLabel.font = [UIFont systemFontOfSize:54];
        self.tempLabel.frame = CGRectMake(88, 40, 72, 40);
        self.tempLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightMedium];
        self.condLabel.frame = CGRectMake(14, 108, 142, 18);
        self.hiloLabel.hidden = YES;
        self.statusLabel.hidden = YES;
    } else if ([type isEqualToString:@"decompte"]) {
        [self setGradFrom:MWRGB(1.0, 0.62, 0.18) to:MWRGB(0.95, 0.28, 0.22)];
        self.cityLabel.text = MWL(@"Nouvel An");
        self.tempLabel.frame = CGRectMake(14, 28, 142, 68);
        self.tempLabel.font = [UIFont systemFontOfSize:58 weight:UIFontWeightLight];
        self.iconLabel.hidden = YES;
        self.condLabel.frame = CGRectMake(14, 100, 142, 18);
        self.hiloLabel.hidden = YES;
        self.statusLabel.hidden = YES;
    } else {
        [self setGradFrom:MWRGB(0.33, 0.62, 0.95) to:MWRGB(0.16, 0.38, 0.80)];
        self.cityLabel.text = gCity ?: kMWCity;
        self.tempLabel.text = @"--°";
        self.statusLabel.text = MWL(@"Chargement...");
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

    // tout le contenu grandit avec le widget : on garde les cadres et tailles de police de base
    NSMutableArray *views = [NSMutableArray arrayWithArray:@[self.cityLabel, self.tempLabel, self.iconLabel, self.condLabel, self.hiloLabel, self.statusLabel, self.bodyLabel]];
    [views addObjectsFromArray:extra];
    NSMutableArray *frames = [NSMutableArray array], *sizes = [NSMutableArray array];
    for (UIView *v in views) {
        [frames addObject:[NSValue valueWithCGRect:v.frame]];
        CGFloat fs = 0;
        if ([v isKindOfClass:[UILabel class]]) fs = ((UILabel *)v).font.pointSize;
        else if ([v isKindOfClass:[UIButton class]]) fs = ((UIButton *)v).titleLabel.font.pointSize;
        [sizes addObject:@(fs)];
    }
    self.tracked = views;
    self.baseFrames = frames;
    self.baseSizes = sizes;

    // croix de suppression (edition), en haut a droite
    self.delButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.delButton.frame = CGRectMake(kMWBaseW - 34, 6, 28, 28);
    self.delButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.85];
    self.delButton.layer.cornerRadius = 14.0;
    [self.delButton setTitle:@"✕" forState:UIControlStateNormal];
    [self.delButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.delButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.delButton addTarget:gMgr action:@selector(deleteTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.delButton.hidden = YES;
    [self addSubview:self.delButton];

    // poignees d'angle pour agrandir : bas droite (1) et haut gauche (2)
    self.handleBR = [self makeHandle:YES tag:901];
    self.handleTL = [self makeHandle:NO tag:902];

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

// le contenu s'adapte a la taille du widget : tout grandit ensemble, le fond remplit tout
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    self.grad.frame = self.bounds;
    self.photoView.frame = self.bounds;
    CGFloat s = MAX(0.8, MIN(2.6, MIN(W / kMWBaseW, H / kMWBaseH)));
    CGFloat ox = (W - kMWBaseW * s) / 2.0, oy = (H - kMWBaseH * s) / 2.0;
    for (NSUInteger i = 0; i < self.tracked.count; i++) {
        UIView *v = self.tracked[i];
        CGRect f = [self.baseFrames[i] CGRectValue];
        v.frame = CGRectMake(ox + f.origin.x * s, oy + f.origin.y * s, f.size.width * s, f.size.height * s);
        CGFloat fs = [self.baseSizes[i] doubleValue];
        if (fs > 0) {
            if ([v isKindOfClass:[UILabel class]]) {
                UILabel *l = (UILabel *)v;
                if (fabs(l.font.pointSize - fs * s) > 0.2 && ![self.type isEqualToString:@"mois"]) l.font = [l.font fontWithSize:fs * s];
            } else if ([v isKindOfClass:[UIButton class]]) {
                UIButton *b = (UIButton *)v;
                b.titleLabel.font = [b.titleLabel.font fontWithSize:fs * s];
            }
        }
    }
    if (self.ringProgress) {
        CATransform3D t = CATransform3DMakeScale(s, s, 1.0);
        CGPoint pos = CGPointMake(ox + kMWBaseW * s / 2.0, oy + kMWBaseH * s / 2.0);
        self.ringTrack.position = pos;
        self.ringProgress.position = pos;
        self.ringTrack.transform = t;
        self.ringProgress.transform = t;
    }
    self.delButton.frame = CGRectMake(W - 34, 6, 28, 28);
    self.handleBR.frame = CGRectMake(W - 44, H - 44, 44, 44);
    self.handleTL.frame = CGRectMake(0, 0, 44, 44);
    [CATransaction commit];
    if ([self.type isEqualToString:@"mois"] && fabs(self.curScale - s) > 0.02) {
        self.curScale = s;
        [self refresh];
    }
    self.curScale = s;
}

- (void)applyInfo:(NSDictionary *)info stale:(BOOL)stale {
    @try {
        if ([self.type isEqualToString:@"previsions"]) {
            NSArray *days = info[@"days"];
            if (![days isKindOfClass:[NSArray class]] || !days.count) { self.bodyLabel.text = MWL(@"Pas de prévisions"); return; }
            NSMutableArray *lines = [NSMutableArray array];
            for (NSDictionary *d in days) {
                [lines addObject:[NSString stringWithFormat:@"%@ %@ %d°/%d°", d[@"d"], MWEmoji([d[@"c"] intValue], YES),
                                  MWT([d[@"mx"] doubleValue]), MWT([d[@"mn"] doubleValue])]];
            }
            self.bodyLabel.text = [lines componentsJoinedByString:@"\n"];
            return;
        }
        int code = [info[@"code"] intValue];
        BOOL day = [info[@"day"] intValue] != 0;
        self.tempLabel.text = [NSString stringWithFormat:@"%d°", MWT([info[@"temp"] doubleValue])];
        self.iconLabel.text = MWEmoji(code, day);
        self.condLabel.text = MWText(code);
        if (info[@"max"] && info[@"min"]) {
            self.hiloLabel.text = [NSString stringWithFormat:@"%@ %d°  %@ %d°", MWL(@"Max"), MWT([info[@"max"] doubleValue]), MWL(@"Min"), MWT([info[@"min"] doubleValue])];
        } else {
            self.hiloLabel.text = @"";
        }
        if (day) [self setGradFrom:MWRGB(0.33, 0.62, 0.95) to:MWRGB(0.16, 0.38, 0.80)];
        else [self setGradFrom:MWRGB(0.12, 0.16, 0.38) to:MWRGB(0.04, 0.06, 0.18)];
        if (stale) {
            self.statusLabel.text = MWL(@"Hors ligne (dernière météo)");
        } else {
            NSDateFormatter *f = [[NSDateFormatter alloc] init];
            f.dateFormat = MWTimeFormat();
            self.statusLabel.text = [NSString stringWithFormat:@"%@ %@", MWL(@"Mise à jour"), [f stringFromDate:[NSDate date]]];
        }
    } @catch (...) {}
}

- (void)showStatus:(NSString *)s {
    if ([self.type isEqualToString:@"previsions"]) self.bodyLabel.text = s;
    else self.statusLabel.text = s;
}

- (void)applyPhoto {
    UIImage *im = self.photoPath.length ? MWLoadScaled(self.photoPath, 700) : nil;
    self.photoView.backgroundColor = [UIColor clearColor];
    self.photoView.image = im;
    self.photoView.hidden = (im == nil);
    self.iconLabel.hidden = (im != nil);
    self.condLabel.hidden = (im != nil);
}

- (void)refreshMonth {
    NSLocale *fr = [NSLocale currentLocale];
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSDate *now = [NSDate date];
    NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:now];
    NSInteger today = c.day;
    c.day = 1;
    NSDate *first = [cal dateFromComponents:c];
    NSInteger wd = [cal component:NSCalendarUnitWeekday fromDate:first];   // 1 = dimanche
    NSInteger fw = [[NSCalendar currentCalendar] firstWeekday];             // 1er jour de la semaine selon la region
    NSInteger lead = (wd - fw + 7) % 7;
    NSInteger nb = [cal rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:first].length;

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = fr;
    f.dateFormat = MWDateTpl(@"MMMMy");
    self.cityLabel.text = [[f stringFromDate:now] uppercaseStringWithLocale:fr];

    CGFloat sz = 11.0 * MAX(0.8, self.curScale);
    UIFont *font = [UIFont fontWithName:@"Menlo" size:sz] ?: [UIFont systemFontOfSize:sz];
    UIFont *bold = [UIFont fontWithName:@"Menlo-Bold" size:sz] ?: font;
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineSpacing = 2.0 * MAX(0.8, self.curScale);
    NSDictionary *base = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.85], NSParagraphStyleAttributeName: ps};
    NSString *hdr = MWWeekHeader(fw);
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:hdr attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.5], NSParagraphStyleAttributeName: ps}];
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

- (void)refreshMusic {
    if (!gMRGetInfo) { self.cityLabel.text = MWL(@"Musique"); self.condLabel.text = MWL(@"Indisponible"); return; }
    __weak MWWidgetView *ws = self;
    gMRGetInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        MWWidgetView *w = ws;
        if (!w) return;
        @try {
            if (![info isKindOfClass:[NSDictionary class]]) info = @{};
            NSString *t = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            NSString *a = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            BOOL has = [t isKindOfClass:[NSString class]] && t.length;
            w.cityLabel.text = has ? t : MWL(@"Musique");
            w.condLabel.text = ([a isKindOfClass:[NSString class]] && a.length) ? a : (has ? @"" : MWL(@"Rien en lecture"));
            [w.playBtn setImage:MWGlyph(rate.doubleValue > 0.01 ? 2 : 1) forState:UIControlStateNormal];
            if ([art isKindOfClass:[NSData class]] && art.length) {
                if (art.length != w.artSig) { w.artSig = art.length; w.artView.image = [UIImage imageWithData:art]; }
            } else if (w.artSig) {
                w.artSig = 0;
                w.artView.image = nil;
            }
        } @catch (...) {}
    });
}

// contenu des widgets locaux
- (void)refresh {
    @try {
        NSDate *now = [NSDate date];
        NSLocale *fr = [NSLocale currentLocale];
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.locale = fr;
        if ([self.type isEqualToString:@"horloge"]) {
            f.dateFormat = MWTimeFormat();
            self.tempLabel.text = [f stringFromDate:now];
            f.dateFormat = MWDateTpl(@"EEEEdMMMM");
            self.condLabel.text = [f stringFromDate:now];
        } else if ([self.type isEqualToString:@"date"]) {
            f.dateFormat = @"EEEE";
            self.cityLabel.text = [[f stringFromDate:now] uppercaseStringWithLocale:fr];
            f.dateFormat = @"d";
            self.tempLabel.text = [f stringFromDate:now];
            f.dateFormat = MWDateTpl(@"MMMMy");
            self.condLabel.text = [f stringFromDate:now];
        } else if ([self.type isEqualToString:@"mois"]) {
            [self refreshMonth];
        } else if ([self.type isEqualToString:@"musique"]) {
            [self refreshMusic];
        } else if ([self.type isEqualToString:@"lune"]) {
            double days = [now timeIntervalSince1970] / 86400.0 - 10962.7597;
            double ph = fmod(days / 29.530588853, 1.0);
            if (ph < 0) ph += 1.0;
            NSArray *em = @[@"🌑", @"🌒", @"🌓", @"🌔", @"🌕", @"🌖", @"🌗", @"🌘"];
            self.iconLabel.text = em[((int)lround(ph * 8.0)) % 8];
            self.tempLabel.text = [NSString stringWithFormat:@"%d%%", (int)lround((1.0 - cos(2.0 * M_PI * ph)) / 2.0 * 100.0)];
            NSString *nm = (ph < 0.03 || ph > 0.97) ? MWL(@"Nouvelle lune") : (fabs(ph - 0.5) < 0.03 ? MWL(@"Pleine lune") : (ph < 0.5 ? MWL(@"Lune croissante") : MWL(@"Lune décroissante")));
            self.condLabel.text = nm;
        } else if ([self.type isEqualToString:@"decompte"]) {
            NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSDateComponents *c = [cal components:NSCalendarUnitYear fromDate:now];
            c.year += 1; c.month = 1; c.day = 1; c.hour = 0; c.minute = 0;
            NSDate *target = [cal dateFromComponents:c];
            NSDateComponents *d = [cal components:NSCalendarUnitDay fromDate:now toDate:target options:0];
            self.tempLabel.text = [NSString stringWithFormat:@"%ld", (long)d.day];
            self.condLabel.text = d.day <= 1 ? MWL(@"jour restant") : MWL(@"jours restants");
        } else if ([self.type isEqualToString:@"batterie"]) {
            UIDevice *d = [UIDevice currentDevice];
            float lv = d.batteryLevel;
            self.tempLabel.text = lv < 0 ? @"--%" : [NSString stringWithFormat:@"%d%%", (int)lroundf(lv * 100.0f)];
            BOOL chg = (d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull);
            NSString *etat = d.batteryState == UIDeviceBatteryStateFull ? MWL(@"Chargée") : (chg ? [@"⚡️ " stringByAppendingString:MWL(@"En charge")] : MWL(@"Sur batterie"));
            self.condLabel.text = [NSString stringWithFormat:@"%@ · %@", d.model, etat];
            float p = lv < 0 ? 0.0f : lv;
            self.ringProgress.strokeEnd = p;
            UIColor *col = (!chg && p <= 0.20f) ? MWRGB(1.0, 0.27, 0.23) : MWRGB(0.30, 0.85, 0.39);
            self.ringProgress.strokeColor = col.CGColor;
        } else if ([self.type isEqualToString:@"stockage"]) {
            NSDictionary *a = [[NSFileManager defaultManager] attributesOfFileSystemForPath:@"/var/mobile" error:nil];
            double total = [a[NSFileSystemSize] doubleValue];
            double freeB = [a[NSFileSystemFreeSize] doubleValue];
            if (total > 0) {
                double g = 1024.0 * 1024.0 * 1024.0;
                self.tempLabel.text = [NSString stringWithFormat:@"%.1f %@", freeB / g, MWL(@"Go")];
                self.condLabel.text = [NSString stringWithFormat:@"%@ %.0f %@", MWL(@"libres sur"), total / g, MWL(@"Go")];
                self.ringProgress.strokeEnd = (CGFloat)(1.0 - freeB / total);
            }
        } else if ([self.type isEqualToString:@"memoire"]) {
            double total = (double)[NSProcessInfo processInfo].physicalMemory;
            double freeB = (double)MWFreeRAM();
            if (total > 0) {
                double m = 1024.0 * 1024.0;
                self.tempLabel.text = [NSString stringWithFormat:@"%.0f %@", freeB / m, MWL(@"Mo")];
                self.condLabel.text = [NSString stringWithFormat:@"%@ %.0f %@", MWL(@"libres sur"), total / m, MWL(@"Mo")];
                self.ringProgress.strokeEnd = (CGFloat)MAX(0.0, MIN(1.0, 1.0 - freeB / total));
            }
        }
    } @catch (...) {}
}

static BOOL MWIsWeatherType(NSString *t) { return [t isEqualToString:@"meteo"] || [t isEqualToString:@"previsions"]; }

// premier remplissage d'un widget
- (void)prime {
    if (MWIsWeatherType(self.type)) {
        @try {
            NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kMWCache];
            if ([c isKindOfClass:[NSDictionary class]] && c[@"temp"]) [self applyInfo:c stale:YES];
        } @catch (...) {}
        MWFetch(0, nil);
    } else if ([self.type isEqualToString:@"photo"]) {
        [self applyPhoto];
    } else {
        [self refresh];
    }
}

- (void)setEditing:(BOOL)e {
    self.delButton.hidden = !e;
    self.handleBR.hidden = !e;
    self.handleTL.hidden = !e;
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

// ---------- outils ----------
#define MWCLAMP(x, a, b) MAX((a), MIN((b), (x)))

static void MWEachWidget(void (^blk)(MWWidgetView *w)) {
    for (NSNumber *k in [gPages allKeys]) {
        MWPage *pg = gPages[k];
        for (MWWidgetView *w in [pg.widgets copy]) blk(w);
    }
}

// ---------- telechargement meteo (3 adresses essayees l'une apres l'autre) ----------
static void MWFetch(NSUInteger idx, NSString *lastErr) {
    if (!gPlaceReady) return;
    NSArray *urls = @[
        [NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true&daily=weathercode,temperature_2m_max,temperature_2m_min&timezone=auto", gLat, gLon],
        [NSString stringWithFormat:@"http://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true&daily=weathercode,temperature_2m_max,temperature_2m_min&timezone=auto", gLat, gLon],
        [NSString stringWithFormat:@"http://wttr.in/%.4f,%.4f?format=j1", gLat, gLon]
    ];
    if (idx >= urls.count) {
        MWLog([NSString stringWithFormat:@"echec total: %@", lastErr]);
        dispatch_async(dispatch_get_main_queue(), ^{
            MWEachWidget(^(MWWidgetView *w) {
                if (MWIsWeatherType(w.type)) [w showStatus:[NSString stringWithFormat:@"%@ (%@)", MWL(@"Météo indisponible"), lastErr ?: @"?"]];
            });
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
                    MWEachWidget(^(MWWidgetView *w) { if (MWIsWeatherType(w.type)) [w applyInfo:info stale:NO]; });
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

// ---------- grille d'icones ----------
static NSInteger MWCols(UIView *lv) { return lv.bounds.size.width > 900.0 ? 5 : 4; }
static CGFloat MWCellW(UIView *lv) { return lv.bounds.size.width / (CGFloat)MWCols(lv); }
// iPad : 4 colonnes x 5 lignes en portrait, 5 x 4 en paysage
static NSInteger MWMaxRows(UIView *lv) { return MWCols(lv) == 5 ? 4 : 5; }

// haut de la 1re ligne d'icones et hauteur d'une ligne : lus sur la vraie grille d'icones si possible
static void MWRowGeometry(UIView *lv, CGFloat *top0, CGFloat *ch) {
    *top0 = kMWTop;
    *ch = MWCellW(lv) * 0.8;
    @try {
        if ([lv respondsToSelector:@selector(originForIconAtIndex:)]) {
            gBypass = YES;
            CGPoint p0 = [(SBIconListView *)lv originForIconAtIndex:0];
            CGPoint pr = [(SBIconListView *)lv originForIconAtIndex:(NSUInteger)MWCols(lv)];
            gBypass = NO;
            CGFloat d = pr.y - p0.y;
            if (d > 80.0 && d < 400.0) { *ch = d; *top0 = p0.y; }
        }
    } @catch (...) {}
    gBypass = NO;
}

static MWPage *MWPageOf(UIView *lv) {
    for (MWPage *pg in [gPages allValues]) { if (pg.host == lv) return pg; }
    return nil;
}

// cases occupees par un widget : colonnes c0..c1, lignes r0..r1 (recadrees dans la grille)
static void MWFoot(MWWidgetView *w, UIView *lv, NSInteger *c0, NSInteger *r0, NSInteger *c1, NSInteger *r1) {
    NSInteger cols = MWCols(lv), rows = MWMaxRows(lv);
    *c0 = MAX(0, w.col - w.left);
    *c1 = MIN(cols - 1, w.col + w.right);
    *r0 = MAX(0, w.row - w.up);
    *r1 = MIN(rows - 1, w.row + w.down);
    if (*c1 < *c0) *c1 = *c0;
    if (*r1 < *r0) *r1 = *r0;
}

// le rectangle de cases est-il dans la grille et libre (sans autre widget de la page) ?
static BOOL MWRectFree(MWPage *pg, MWWidgetView *me, NSInteger c0, NSInteger r0, NSInteger c1, NSInteger r1) {
    UIView *lv = pg.host;
    if (!lv) return NO;
    if (c0 < 0 || r0 < 0 || c1 >= MWCols(lv) || r1 >= MWMaxRows(lv)) return NO;
    for (MWWidgetView *o in pg.widgets) {
        if (o == me) continue;
        NSInteger a0, b0, a1, b1;
        MWFoot(o, lv, &a0, &b0, &a1, &b1);
        if (c0 <= a1 && a0 <= c1 && r0 <= b1 && b0 <= r1) return NO;
    }
    return YES;
}

// ou va l'icone numero i : i-eme case libre ; les icones en trop (page pleine) vont sur les cases des widgets
static NSUInteger MWMappedIndex(MWPage *pg, NSUInteger i) {
    UIView *lv = pg.host;
    if (!lv) return i;
    NSInteger cols = MWCols(lv), rows = MWMaxRows(lv);
    NSInteger total = cols * rows;
    if (total <= 0 || total > 64 || !pg.widgets.count) return i;
    BOOL occ[64];
    for (NSInteger k = 0; k < 64; k++) occ[k] = NO;
    for (MWWidgetView *w in pg.widgets) {
        NSInteger c0, r0, c1, r1;
        MWFoot(w, lv, &c0, &r0, &c1, &r1);
        for (NSInteger r = r0; r <= r1; r++) {
            for (NSInteger c = c0; c <= c1; c++) occ[r * cols + c] = YES;
        }
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

static void MWRelayoutIcons(MWPage *pg) {
    UIView *lv = pg.host;
    if (!lv || !gPushAPI) return;
    @try {
        if ([lv respondsToSelector:@selector(layoutIconsNow)]) {
            [UIView animateWithDuration:0.25 animations:^{ [(SBIconListView *)lv layoutIconsNow]; }];
        } else {
            [lv setNeedsLayout];
        }
    } @catch (...) {}
}

// le widget remplit ses cases en gardant une marge : il ne touche jamais une icone
static void MWLayout(MWPage *pg) {
    UIView *lv = pg.host;
    if (!lv || !pg.widgets.count) return;
    CGFloat cw = MWCellW(lv), ch = 0, top0 = 0;
    MWRowGeometry(lv, &top0, &ch);
    for (MWWidgetView *v in pg.widgets) {
        NSInteger c0, r0, c1, r1;
        MWFoot(v, lv, &c0, &r0, &c1, &r1);
        CGFloat x = c0 * cw + kMWInsetX;
        CGFloat y = top0 - kMWUpOff + r0 * ch;
        CGFloat w = (c1 - c0 + 1) * cw - 2.0 * kMWInsetX;
        CGFloat h = (r1 - r0 + 1) * ch - (kMWDownOff - kMWUpOff);
        CGRect b = CGRectMake(0, 0, MAX(130.0, w), MAX(120.0, h));
        if (!CGRectEqualToRect(v.bounds, b)) v.bounds = b;
        CGPoint c = CGPointMake(x + b.size.width / 2.0, y + b.size.height / 2.0);
        if (!CGPointEqualToPoint(v.center, c)) v.center = c;
    }
}

// ---------- sauvegarde ----------
static void MWSaveAll(void) {
    @try {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *d in gSaved) {
            if (!gPages[@([d[@"page"] integerValue])]) [out addObject:d];   // pages pas encore affichees : on garde
        }
        for (NSNumber *k in [gPages allKeys]) {
            MWPage *pg = gPages[k];
            for (MWWidgetView *w in pg.widgets) {
                NSMutableDictionary *dd = [NSMutableDictionary dictionaryWithDictionary:@{@"page": k, @"type": w.type, @"col": @(w.col), @"row": @(w.row),
                                 @"up": @(w.up), @"down": @(w.down), @"left": @(w.left), @"right": @(w.right)}];
                if (w.photoPath.length) dd[@"photo"] = w.photoPath;
                [out addObject:dd];
            }
        }
        gSaved = out;
        [[NSFileManager defaultManager] createDirectoryAtPath:kMWDir withIntermediateDirectories:YES attributes:nil error:nil];
        [out writeToFile:kMWTypesPath atomically:YES];
    } @catch (...) {}
}

// accepte les anciens formats (liste de noms, « span » en hauteur, pas de page = page 0)
static NSMutableArray *MWLoadSaved(void) {
    NSMutableArray *ok = [NSMutableArray array];
    @try {
        NSArray *a = [NSArray arrayWithContentsOfFile:kMWTypesPath];
        if ([a isKindOfClass:[NSArray class]]) {
            NSMutableDictionary *perPage = [NSMutableDictionary dictionary];
            for (id e in a) {
                NSString *t = nil, *photo = nil;
                NSInteger page = 0, col = 0, row = 0, up = 0, down = 0, left = 0, right = 0;
                if ([e isKindOfClass:[NSString class]]) { t = e; col = (NSInteger)ok.count; }
                else if ([e isKindOfClass:[NSDictionary class]]) {
                    t = e[@"type"];
                    if (e[@"page"]) page = [e[@"page"] integerValue];
                    if (e[@"col"]) col = [e[@"col"] integerValue];
                    if (e[@"row"]) row = [e[@"row"] integerValue];
                    if (e[@"span"]) down = MAX(0, [e[@"span"] integerValue] - 1);
                    if (e[@"up"]) up = [e[@"up"] integerValue];
                    if (e[@"down"]) down = [e[@"down"] integerValue];
                    if (e[@"left"]) left = [e[@"left"] integerValue];
                    if (e[@"right"]) right = [e[@"right"] integerValue];
                    if ([e[@"photo"] isKindOfClass:[NSString class]]) photo = e[@"photo"];
                }
                if (![t isKindOfClass:[NSString class]] || ![MWAllTypes() containsObject:t]) continue;
                NSMutableArray *seen = perPage[@(page)];
                if (!seen) { seen = [NSMutableArray array]; perPage[@(page)] = seen; }
                if (([seen containsObject:t] && ![t isEqualToString:@"photo"]) || seen.count >= kMWMax) continue;
                [seen addObject:t];
                NSMutableDictionary *nd = [NSMutableDictionary dictionaryWithDictionary:@{@"page": @(page), @"type": t, @"col": @(col), @"row": @(row), @"up": @(up), @"down": @(down), @"left": @(left), @"right": @(right)}];
                if (photo) nd[@"photo"] = photo;
                [ok addObject:nd];
            }
            return ok;   // peut etre vide : l'utilisateur a tout supprime
        }
    } @catch (...) {}
    [ok addObject:@{@"page": @0, @"type": @"meteo", @"col": @0, @"row": @0, @"up": @0, @"down": @0, @"left": @0, @"right": @0}];   // premiere utilisation
    return ok;
}

// ---------- edition ----------
static void MWSetEditing(BOOL e) {
    if (gEditing == e) return;
    gEditing = e;
    for (MWPage *pg in [gPages allValues]) {
        for (MWWidgetView *w in pg.widgets) [w setEditing:e];
        pg.plusButton.hidden = !e;
        if (e && pg.host && pg.plusButton) [pg.host bringSubviewToFront:pg.plusButton];
    }
    if (!e && gPicker) { [gPicker removeFromSuperview]; gPicker = nil; }
    if (!e) MWDismissGallery();
}

static void MWEnterEditing(void) {
    if (gSBEditAPI) [[%c(SBIconController) sharedInstance] setIsEditing:YES];
    else MWSetEditing(YES);
}

static void MWExitEditing(void) {
    if (gSBEditAPI) [[%c(SBIconController) sharedInstance] setIsEditing:NO];
    else MWSetEditing(NO);
}

static void MWScrollLock(BOOL lock, UIView *lv) {
    if (lock) {
        for (UIView *v = lv.superview; v; v = v.superview) {
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

static void MWAddType(MWPage *pg, NSString *type) {
    UIView *lv = pg.host;
    if (!lv || pg.widgets.count >= kMWMax) return;
    for (MWWidgetView *w in pg.widgets) { if ([w.type isEqualToString:type] && ![type isEqualToString:@"photo"]) return; }
    NSInteger cols = MWCols(lv), maxRows = MWMaxRows(lv);
    NSInteger fc = -1, fr = -1;
    for (NSInteger r = 0; r < maxRows && fc < 0; r++) {
        for (NSInteger c = 0; c < cols; c++) {
            if (MWRectFree(pg, nil, c, r, c, r)) { fc = c; fr = r; break; }
        }
    }
    if (fc < 0) return;
    MWWidgetView *nw = [[MWWidgetView alloc] initWithType:type col:fc row:fr up:0 down:0 left:0 right:0];
    nw.page = pg;
    [pg.widgets addObject:nw];
    [lv insertSubview:nw atIndex:0];
    [nw setEditing:gEditing];
    MWLayout(pg);
    [nw prime];
    MWSaveAll();
    MWRelayoutIcons(pg);
    MWLog([NSString stringWithFormat:@"widget ajoute: %@ (page %ld, col %ld, ligne %ld)", type, (long)pg.index, (long)fc, (long)fr]);
}

static void MWRemove(MWWidgetView *w) {
    MWPage *pg = w.page;
    [pg.widgets removeObject:w];
    MWSaveAll();
    [UIView animateWithDuration:0.2 animations:^{
        w.alpha = 0.0;
        w.transform = CGAffineTransformMakeScale(0.6, 0.6);
    } completion:^(BOOL f) {
        [w removeFromSuperview];
    }];
    if (pg) MWRelayoutIcons(pg);
    MWLog([NSString stringWithFormat:@"widget supprime: %@", w.type]);
}

// petite fenetre « Widgets » (bouton + du mode edition)
static void MWShowPicker(MWPage *pg) {
    UIView *lv = pg.host;
    if (!lv) return;
    MWDismissPicker();
    gPickerPage = pg;
    NSMutableArray *avail = [NSMutableArray array];
    for (NSString *t in MWAllTypes()) {
        BOOL used = NO;
        for (MWWidgetView *w in pg.widgets) { if ([w.type isEqualToString:t] && ![t isEqualToString:@"photo"]) used = YES; }
        if (!used) [avail addObject:t];
    }
    BOOL full = pg.widgets.count >= kMWMax;

    UIView *dim = [[UIView alloc] initWithFrame:lv.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:gMgr action:@selector(dismissPicker)];
    [dim addGestureRecognizer:tap];

    CGFloat footer = gPushAPI ? 48.0 : 0.0;
    NSUInteger rows = (full || avail.count == 0) ? 1 : avail.count;
    CGFloat listH = rows * 54.0;
    CGFloat maxH = MAX(260.0, lv.bounds.size.height - 180.0);
    CGFloat ph = MIN(maxH, 60.0 + listH + footer + 8.0);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 330, ph)];
    panel.center = CGPointMake(CGRectGetMidX(lv.bounds), CGRectGetMidY(lv.bounds));
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    panel.backgroundColor = [UIColor colorWithWhite:0.14 alpha:0.97];
    panel.layer.cornerRadius = 24.0;
    [dim addSubview:panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, 298, 30)];
    title.text = MWL(@"Widgets");
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:title];

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 54, 330, ph - 54 - footer - 6)];
    sc.contentSize = CGSizeMake(330, listH + 6);
    [panel addSubview:sc];

    if (full || avail.count == 0) {
        UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, 298, 54)];
        m.text = full ? MWL(@"5 widgets maximum sur cette page (mémoire de l'iPad 2). Supprime-en un d'abord.") : MWL(@"Tous les widgets sont déjà sur cette page.");
        m.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
        m.font = [UIFont systemFontOfSize:15];
        m.numberOfLines = 3;
        m.textAlignment = NSTextAlignmentCenter;
        [sc addSubview:m];
    } else {
        for (NSUInteger i = 0; i < avail.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.frame = CGRectMake(16, i * 54, 298, 46);
            b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.95];
            b.layer.cornerRadius = 13.0;
            [b setTitle:MWTypeTitle(avail[i]) forState:UIControlStateNormal];
            [b setTitleColor:[UIColor colorWithWhite:0.1 alpha:1.0] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:18];
            b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
            b.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 0);
            b.accessibilityIdentifier = avail[i];
            [b addTarget:gMgr action:@selector(pickTapped:) forControlEvents:UIControlEventTouchUpInside];
            [sc addSubview:b];
        }
    }
    if (gPushAPI) {
        CGFloat sy = ph - footer;
        UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(18, sy, 230, 36)];
        sl.text = MWL(@"Libérer la place (pousser les icônes)");
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

// ---------- galerie : choisir la photo d'un widget Photo ----------
static void MWDismissGallery(void) {
    [gGallery removeFromSuperview];
    gGallery = nil;
}

// photos les plus recentes de l'iPad (pellicule et captures d'ecran)
static NSArray *MWRecentPhotos(NSUInteger limit) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Media/DCIM";
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *sub in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir = [root stringByAppendingPathComponent:sub];
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            NSString *ext = [[f pathExtension] lowercaseString];
            if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"png"]) [names addObject:f];
        }
        [names sortUsingSelector:@selector(compare:)];
        NSUInteger from = names.count > limit ? names.count - limit : 0;
        for (NSUInteger i = from; i < names.count; i++) {
            NSString *full = [dir stringByAppendingPathComponent:names[i]];
            NSDate *d = [fm attributesOfItemAtPath:full error:nil][NSFileModificationDate] ?: [NSDate distantPast];
            [items addObject:@{@"p": full, @"d": d}];
        }
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"d"] compare:a[@"d"]]; }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *it in items) { if (out.count >= limit) break; [out addObject:it[@"p"]]; }
    return out;
}

static void MWShowGallery(MWWidgetView *w) {
    UIView *lv = w.page.host;
    if (!lv) return;
    MWDismissGallery();
    MWDismissPicker();
    gGalleryTarget = w;
    NSArray *paths = MWRecentPhotos(45);

    UIView *dim = [[UIView alloc] initWithFrame:lv.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:gMgr action:@selector(dismissGallery)]];

    CGFloat ph = MIN(MAX(300.0, lv.bounds.size.height - 160.0), 560.0);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 340, ph)];
    panel.center = CGPointMake(CGRectGetMidX(lv.bounds), CGRectGetMidY(lv.bounds));
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    panel.backgroundColor = [UIColor colorWithWhite:0.14 alpha:0.97];
    panel.layer.cornerRadius = 24.0;
    [dim addSubview:panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, 308, 30)];
    title.text = MWL(@"Photos");
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:title];

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 54, 340, ph - 62)];
    [panel addSubview:sc];
    NSMutableArray *btns = [NSMutableArray array];
    if (!paths.count) {
        UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, 308, 40)];
        m.text = MWL(@"Aucune photo trouvée");
        m.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
        m.font = [UIFont systemFontOfSize:15];
        m.textAlignment = NSTextAlignmentCenter;
        [sc addSubview:m];
    }
    for (NSUInteger i = 0; i < paths.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(10 + (i % 3) * 108, (i / 3) * 108, 100, 100);
        b.backgroundColor = [UIColor colorWithWhite:0.36 alpha:1.0];
        b.layer.cornerRadius = 10.0;
        b.clipsToBounds = YES;
        b.imageView.contentMode = UIViewContentModeScaleAspectFill;
        b.titleLabel.font = [UIFont systemFontOfSize:30];
        [b setTitle:@"🖼" forState:UIControlStateNormal];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
        b.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
        b.accessibilityIdentifier = paths[i];
        [b addTarget:gMgr action:@selector(photoTapped:) forControlEvents:UIControlEventTouchUpInside];
        [sc addSubview:b];
        [btns addObject:b];
    }
    sc.contentSize = CGSizeMake(340, ((paths.count + 2) / 3) * 108 + 8);
    [lv addSubview:dim];
    gGallery = dim;

    MWLog([NSString stringWithFormat:@"galerie: %lu photo(s)", (unsigned long)paths.count]);

    // les 9 premieres miniatures tout de suite (on voit quelque chose immediatement), les autres en arriere-plan
    NSUInteger firstN = MIN((NSUInteger)9, paths.count);
    for (NSUInteger i = 0; i < firstN; i++) {
        @autoreleasepool {
            UIImage *th = MWSquareThumb(MWLoadScaled(paths[i], 200), 100);
            UIButton *b = btns[i];
            if (th) { [b setImage:th forState:UIControlStateNormal]; [b setTitle:nil forState:UIControlStateNormal]; }
        }
    }
    __weak UIView *wd = dim;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        for (NSUInteger i = firstN; i < paths.count; i++) {
            @autoreleasepool {
                UIImage *th = MWSquareThumb(MWLoadScaled(paths[i], 200), 100);
                UIButton *b = btns[i];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (gGallery && gGallery == wd && th) { [b setImage:th forState:UIControlStateNormal]; [b setTitle:nil forState:UIControlStateNormal]; }
                });
            }
        }
    });
}

@implementation MWManager

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

// on ne deplace un widget qu'en mode edition, et pas quand on touche une poignee
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) return gEditing;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    if ([g.view isKindOfClass:[MWWidgetView class]] && t.view && t.view.tag >= 901) return NO;
    return YES;
}

- (void)widgetLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && !gEditing) MWEnterEditing();
}

- (void)widgetTap:(UITapGestureRecognizer *)g {
    if (gEditing) { MWExitEditing(); return; }
    MWWidgetView *w = (MWWidgetView *)g.view;
    if ([w isKindOfClass:[MWWidgetView class]] && [w.type isEqualToString:@"photo"]) MWShowGallery(w);
}

- (void)widgetPan:(UIPanGestureRecognizer *)g {
    MWWidgetView *w = (MWWidgetView *)g.view;
    if (![w isKindOfClass:[MWWidgetView class]]) return;
    MWPage *pg = w.page;
    UIView *lv = pg.host;
    if (!lv) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        w.dragStart = w.center;
        gDragging = YES;
        MWScrollLock(YES, lv);
        [lv bringSubviewToFront:w];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:lv];
        w.center = CGPointMake(w.dragStart.x + t.x, w.dragStart.y + t.y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) {
        MWScrollLock(NO, lv);
        gDragging = NO;
        CGFloat cw = MWCellW(lv), ch = 0, top0 = 0;
        MWRowGeometry(lv, &top0, &ch);
        CGFloat leftX = w.center.x - w.bounds.size.width / 2.0 - kMWInsetX;
        CGFloat topY = w.center.y - w.bounds.size.height / 2.0 - (top0 - kMWUpOff);
        NSInteger nc = w.left + w.right, nr = w.up + w.down;
        NSInteger c0 = MWCLAMP((NSInteger)lround(leftX / cw), 0, MWCols(lv) - 1 - nc);
        NSInteger r0 = MWCLAMP((NSInteger)lround(topY / ch), 0, MWMaxRows(lv) - 1 - nr);
        if (g.state == UIGestureRecognizerStateEnded && MWRectFree(pg, w, c0, r0, c0 + nc, r0 + nr)) {
            w.col = c0 + w.left;
            w.row = r0 + w.up;
            MWSaveAll();
        }
        [lv sendSubviewToBack:w];
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ MWLayout(pg); } completion:nil];
        MWRelayoutIcons(pg);
    }
}

// poignees d'angle : agrandir par cran (+1 place d'app, 2 max de chaque cote), avec ressort
- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *h = g.view;
    MWWidgetView *w = (MWWidgetView *)h.superview;
    if (![w isKindOfClass:[MWWidgetView class]]) return;
    MWPage *pg = w.page;
    UIView *lv = pg.host;
    if (!lv) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        w.i0up = w.up; w.i0down = w.down; w.i0left = w.left; w.i0right = w.right;
        gDragging = YES;
        MWScrollLock(YES, lv);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:lv];
        CGFloat cw = MWCellW(lv), ch = 0, top0 = 0;
        MWRowGeometry(lv, &top0, &ch);
        NSInteger dc = (NSInteger)lround(t.x / cw), dr = (NSInteger)lround(t.y / ch);
        NSInteger nu = w.up, nd = w.down, nl = w.left, nr = w.right;
        if (h.tag == 901) { nr = MWCLAMP(w.i0right + dc, 0, 2); nd = MWCLAMP(w.i0down + dr, 0, 2); }
        else { nl = MWCLAMP(w.i0left - dc, 0, 2); nu = MWCLAMP(w.i0up - dr, 0, 2); }
        if (nu != w.up || nd != w.down || nl != w.left || nr != w.right) {
            if (MWRectFree(pg, w, w.col - nl, w.row - nu, w.col + nr, w.row + nd)) {
                w.up = nu; w.down = nd; w.left = nl; w.right = nr;
                [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ MWLayout(pg); } completion:nil];
                MWRelayoutIcons(pg);
            }
        }
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) {
        gDragging = NO;
        MWScrollLock(NO, lv);
        MWSaveAll();
    }
}

- (void)deleteTapped:(UIButton *)b {
    UIView *v = b.superview;
    if ([v isKindOfClass:[MWWidgetView class]]) MWRemove((MWWidgetView *)v);
}

- (void)plusTapped:(UIButton *)b {
    for (MWPage *pg in [gPages allValues]) {
        if (pg.plusButton == b) { MWShowPicker(pg); return; }
    }
}

- (void)musicTapped:(UIButton *)b {
    if (!gMRSend) return;
    int cmd = b.tag == 1 ? 5 : (b.tag == 3 ? 4 : 2);   // precedent, suivant, lecture/pause
    gMRSend(cmd, nil);
    UIView *v = b.superview;
    if ([v isKindOfClass:[MWWidgetView class]]) {
        MWWidgetView *w = (MWWidgetView *)v;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [w refresh]; });
    }
}

- (void)pickTapped:(UIButton *)b {
    NSString *t = b.accessibilityIdentifier;
    MWPage *pg = gPickerPage;
    MWDismissPicker();
    if (t && pg) MWAddType(pg, t);
}

- (void)pushSwitched:(UISwitch *)sw {
    gPush = sw.on;
    @try { [@{@"push": @(gPush)} writeToFile:kMWOptions atomically:YES]; } @catch (...) {}
    for (MWPage *pg in [gPages allValues]) MWRelayoutIcons(pg);
}

- (void)photoTapped:(UIButton *)b {
    MWWidgetView *w = gGalleryTarget;
    NSString *p = b.accessibilityIdentifier;
    MWDismissGallery();
    if (w && p.length) {
        w.photoPath = p;
        [w applyPhoto];
        MWSaveAll();
    }
}

- (void)dismissGallery { MWDismissGallery(); }

- (void)dismissPicker { MWDismissPicker(); }

- (void)tick:(NSTimer *)t {
    gTicks++;
    __block BOOL hasWeather = NO;
    MWEachWidget(^(MWWidgetView *w) {
        if (MWIsWeatherType(w.type)) hasWeather = YES;
        else if (![w.type isEqualToString:@"musique"]) [w refresh];
    });
    if (hasWeather && gTicks % 60 == 0) MWFetch(0, nil);   // toutes les 30 minutes
}

- (void)musicTick:(NSTimer *)t {
    MWEachWidget(^(MWWidgetView *w) { if ([w.type isEqualToString:@"musique"] && w.window) [w refresh]; });
}

- (void)battChanged {
    MWEachWidget(^(MWWidgetView *w) { if ([w.type isEqualToString:@"batterie"]) [w refresh]; });
}

@end

// ---------- accrochage aux pages de l'ecran d'accueil ----------
static BOOL MWIsPageList(UIView *lv) {
    NSString *cn = NSStringFromClass([lv class]);
    return [cn isEqualToString:@"SBIconListView"] || [cn isEqualToString:@"SBRootIconListView"];
}

// numero de la page (0 = 1re page) ; si on ne sait pas, on le deduit de la position
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
    return MAX(0, (NSInteger)lround(lv.frame.origin.x / MAX(1.0, lv.bounds.size.width)));
}

// ---------- ville selon la region de l'iPad (fuseau horaire) ----------
static void MWApplyCityLabels(void) {
    MWEachWidget(^(MWWidgetView *w) {
        if ([w.type isEqualToString:@"meteo"]) w.cityLabel.text = gCity ?: kMWCity;
        else if ([w.type isEqualToString:@"previsions"]) w.cityLabel.text = [NSString stringWithFormat:@"%@ · %@", MWL(@"Prévisions"), gCity ?: kMWCity];
    });
}

static void MWPlaceDone(void) {
    gPlaceReady = YES;
    MWApplyCityLabels();
    MWFetch(0, nil);
}

static void MWGeocode(NSString *city, NSString *tz, NSUInteger attempt) {
    NSString *enc = [city stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *proto = attempt == 0 ? @"https" : @"http";
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"%@://geocoding-api.open-meteo.com/v1/search?name=%@&count=1", proto, enc]];
    if (!u) { MWPlaceDone(); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSDictionary *res = nil;
        @try {
            id j = (d && !e) ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            if ([j isKindOfClass:[NSDictionary class]]) {
                id r0 = MWAt(j[@"results"], 0);
                if ([r0 isKindOfClass:[NSDictionary class]] && MWNum(r0[@"latitude"]) && MWNum(r0[@"longitude"])) res = r0;
            }
        } @catch (...) {}
        dispatch_async(dispatch_get_main_queue(), ^{
            if (res) {
                gLat = [MWNum(res[@"latitude"]) doubleValue];
                gLon = [MWNum(res[@"longitude"]) doubleValue];
                gCity = ([res[@"name"] isKindOfClass:[NSString class]] && [res[@"name"] length]) ? res[@"name"] : city;
                @try { [@{@"lat": @(gLat), @"lon": @(gLon), @"city": gCity, @"tz": tz} writeToFile:kMWPlace atomically:YES]; } @catch (...) {}
                MWLog([NSString stringWithFormat:@"ville de la region (%@): %@ (%.3f, %.3f)", tz, gCity, gLat, gLon]);
                MWPlaceDone();
            } else if (attempt == 0) {
                MWGeocode(city, tz, 1);
            } else {
                MWLog(@"ville introuvable : ville par defaut");
                MWPlaceDone();
            }
        });
    }] resume];
}

static void MWRegionPlace(void) {
    NSString *tz = [NSTimeZone localTimeZone].name ?: @"";
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:kMWPlace];
    if ([pl isKindOfClass:[NSDictionary class]] && [pl[@"tz"] isEqualToString:tz] && pl[@"lat"] && pl[@"lon"]) {   // deja trouvee pour ce fuseau
        gLat = [pl[@"lat"] doubleValue];
        gLon = [pl[@"lon"] doubleValue];
        if ([pl[@"city"] isKindOfClass:[NSString class]]) gCity = pl[@"city"];
        return;
    }
    NSString *city = [[[tz componentsSeparatedByString:@"/"] lastObject] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    if (!city.length || [tz hasPrefix:@"GMT"] || [tz hasPrefix:@"Etc"] || [tz hasPrefix:@"UTC"]) return;   // pas de ville : valeurs par defaut
    gPlaceReady = NO;
    MWGeocode(city, tz, 0);
}

static void MWBoot(void) {
    gMgr = [[MWManager alloc] init];
    gPages = [NSMutableDictionary dictionary];
    gSaved = MWLoadSaved();
    MWRegionPlace();
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
    MWLoadMR();
    [NSTimer scheduledTimerWithTimeInterval:30.0 target:gMgr selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:3.0 target:gMgr selector:@selector(musicTick:) userInfo:nil repeats:YES];
    MWLog([NSString stringWithFormat:@"demarrage: %lu widget(s) sauvegardes, API edition SpringBoard: %d", (unsigned long)gSaved.count, (int)gSBEditAPI]);
}

static void MWBind(MWPage *pg, UIView *lv) {
    pg.host = lv;
    for (MWWidgetView *w in pg.widgets) [lv insertSubview:w atIndex:0];
    if (!pg.plusButton) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(18, 28, 40, 40);
        b.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.7];
        b.layer.cornerRadius = 20.0;
        [b setTitle:@"+" forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightLight];
        [b addTarget:gMgr action:@selector(plusTapped:) forControlEvents:UIControlEventTouchUpInside];
        pg.plusButton = b;
    }
    pg.plusButton.hidden = !gEditing;
    [lv addSubview:pg.plusButton];
    MWLayout(pg);
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
        if (!gPages) MWBoot();
        MWPage *pg = MWPageOf(lv);
        if (!pg) {
            NSInteger idx = MWPageIndex(lv);
            MWPage *ex = gPages[@(idx)];
            if (ex) {
                UIView *old = ex.host;
                if (old && old.superview && old.window) return;   // une autre liste vivante porte deja cette page
                pg = ex;
            } else {
                pg = [[MWPage alloc] init];
                pg.index = idx;
                pg.widgets = [NSMutableArray array];
                gPages[@(idx)] = pg;
                for (NSDictionary *d in gSaved) {
                    if ([d[@"page"] integerValue] != idx) continue;
                    MWWidgetView *w = [[MWWidgetView alloc] initWithType:d[@"type"] col:[d[@"col"] integerValue] row:[d[@"row"] integerValue]
                                                                      up:[d[@"up"] integerValue] down:[d[@"down"] integerValue]
                                                                    left:[d[@"left"] integerValue] right:[d[@"right"] integerValue]];
                    w.page = pg;
                    w.photoPath = d[@"photo"];
                    [w setEditing:gEditing];
                    [pg.widgets addObject:w];
                }
            }
            BOOL fresh = (pg.host == nil);
            MWBind(pg, lv);
            if (fresh) { for (MWWidgetView *w in pg.widgets) [w prime]; }
            MWLog([NSString stringWithFormat:@"page %ld accrochee (%@, x=%.0f, largeur=%.0f, hauteur=%.0f, %lu widget(s))", (long)idx, NSStringFromClass([lv class]), lv.frame.origin.x, lv.bounds.size.width, lv.bounds.size.height, (unsigned long)pg.widgets.count]);
            return;
        }
        if (!gDragging) MWLayout(pg);
        MWSyncEditing();
        if (gEditing && pg.plusButton && lv.subviews.lastObject != pg.plusButton) [lv bringSubviewToFront:pg.plusButton];
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
    if (gBypass || !gPush || !gPages) return %orig;
    MWPage *pg = MWPageOf((UIView *)self);
    if (!pg || !pg.widgets.count) return %orig;
    return %orig(MWMappedIndex(pg, index));
}
%end
%end

%group MWEditHook
%hook SBIconController
- (void)setIsEditing:(BOOL)editing {
    %orig;
    if (gPages) MWSetEditing(editing);
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
    MWLog([NSString stringWithFormat:@"MeteoWidget 5.0.0 charge (placement des icones: %d)", (int)gPushAPI]);
}
