// NotificationCenterLite
// Centre de notifications style iOS 18 pour appareils armv7 (iOS 9.x)
// - sans bordure, plein largeur, flou sombre
// - s'ouvre en glissant depuis le haut de l'écran, se ferme en glissant vers le haut
// - tuiles arrondies : luminosité + volume
// - liste de notifications reçues (cartes arrondies, glisser pour effacer)

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>

#define NCL_STRIP_HEIGHT 24.0
#define NCL_MAX_ITEMS 60

static NSString *const NCLChangedNotification = @"NCLBulletinsChanged";

#pragma mark - Déclarations privées

@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, strong) NSDate *date;
@end

@interface BBServer : NSObject
@end

@interface SBNotificationCenterController : NSObject
@end

@interface SpringBoard : UIApplication
@end

#pragma mark - Données

static NSMutableArray *NCLItems(void) {
    static NSMutableArray *items;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ items = [NSMutableArray array]; });
    return items;
}

static NSString *NCLAppName(NSString *sid) {
    if (sid.length == 0) return @"NOTIFICATION";
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"com.apple.mobilesms": @"Messages",
            @"com.apple.mobilemail": @"Mail",
            @"com.apple.mobilecal": @"Calendrier",
            @"com.apple.mobilephone": @"Téléphone",
            @"com.apple.reminders": @"Rappels",
            @"com.apple.facetime": @"FaceTime",
            @"com.apple.preferences": @"Réglages",
            @"com.apple.appstore": @"App Store",
            @"com.apple.mobilenotes": @"Notes",
            @"com.apple.mobilesafari": @"Safari"
        };
    });
    NSString *n = map[sid.lowercaseString];
    if (n) return n;
    NSString *last = [sid componentsSeparatedByString:@"."].lastObject;
    return last.length ? last.capitalizedString : sid;
}

static void NCLAddBulletin(BBBulletin *b) {
    if (!b) return;
    NSString *title = nil, *msg = nil, *sid = nil;
    NSDate *date = nil;
    @try {
        title = b.title;
        msg = b.message;
        sid = b.sectionID;
        date = b.date;
    } @catch (NSException *e) {
        return;
    }
    if (title.length == 0 && msg.length == 0) return;

    NSDictionary *item = @{
        @"app": NCLAppName(sid),
        @"title": title ?: @"",
        @"message": msg ?: @"",
        @"date": date ?: [NSDate date]
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *items = NCLItems();
        NSDictionary *first = items.firstObject;
        if (first &&
            [first[@"title"] isEqualToString:item[@"title"]] &&
            [first[@"message"] isEqualToString:item[@"message"]] &&
            [first[@"app"] isEqualToString:item[@"app"]] &&
            fabs([first[@"date"] timeIntervalSinceDate:item[@"date"]]) < 2.0) {
            return; // doublon (deux variantes de la méthode hookée)
        }
        [items insertObject:item atIndex:0];
        while (items.count > NCL_MAX_ITEMS) [items removeLastObject];
        [[NSNotificationCenter defaultCenter] postNotificationName:NCLChangedNotification object:nil];
    });
}

#pragma mark - Contrôleur

@interface NCLController : UIViewController <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate> {
    UIView *_dim;
    UIVisualEffectView *_panel;
    UILabel *_timeLabel;
    UILabel *_dateLabel;
    UILabel *_emptyLabel;
    UIButton *_clearButton;
    UIView *_brightTile;
    UIView *_volTile;
    UISlider *_brightness;
    MPVolumeView *_volume;
    UITableView *_table;
    UIView *_handle;
    NSTimer *_timer;
    NSDateFormatter *_timeFmt;
    NSDateFormatter *_dateFmt;
    NSDateFormatter *_rowFmt;
    CGFloat _progress;
    CGFloat _startProgress;
    CGFloat _panelHeight;
    CGFloat _lastWidth;
    BOOL _animating;
    BOOL _dragging;
}
@property (nonatomic, readonly) BOOL active;
+ (instancetype)shared;
@end

@implementation NCLController

+ (instancetype)shared {
    static NCLController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[NCLController alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _timeFmt = [[NSDateFormatter alloc] init];
        _timeFmt.dateFormat = @"HH:mm";
        _dateFmt = [[NSDateFormatter alloc] init];
        _dateFmt.dateFormat = @"EEEE d MMMM";
        _rowFmt = [[NSDateFormatter alloc] init];
        _rowFmt.dateFormat = @"HH:mm";
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemsChanged)
                                                     name:NCLChangedNotification
                                                   object:nil];
    }
    return self;
}

- (BOOL)active {
    return _progress > 0.001 || _animating || _dragging;
}

- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)shouldAutorotate { return YES; }

- (UIView *)makeTileWithIcon:(NSString *)icon {
    UIView *t = [[UIView alloc] init];
    t.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    t.layer.cornerRadius = 20;
    t.layer.masksToBounds = YES;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 120, 26)];
    l.text = icon;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    l.tag = 99;
    [t addSubview:l];
    return t;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    _dim = [[UIView alloc] init];
    _dim.backgroundColor = [UIColor blackColor];
    _dim.alpha = 0;
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    [self.view addSubview:_dim];

    _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _panel.layer.borderWidth = 0;   // aucune bordure
    _panel.clipsToBounds = YES;
    _panel.hidden = YES;
    [self.view addSubview:_panel];
    UIView *c = _panel.contentView;

    _timeLabel = [[UILabel alloc] init];
    _timeLabel.textColor = [UIColor whiteColor];
    _timeLabel.font = [UIFont systemFontOfSize:56 weight:UIFontWeightThin];
    [c addSubview:_timeLabel];

    _dateLabel = [[UILabel alloc] init];
    _dateLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    _dateLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [c addSubview:_dateLabel];

    _clearButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_clearButton setTitle:@"Tout effacer" forState:UIControlStateNormal];
    [_clearButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _clearButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _clearButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    _clearButton.layer.cornerRadius = 17;
    [_clearButton addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
    [c addSubview:_clearButton];

    _brightTile = [self makeTileWithIcon:@"☀︎  Luminosité"];
    _brightness = [[UISlider alloc] init];
    _brightness.minimumTrackTintColor = [UIColor whiteColor];
    _brightness.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.3];
    [_brightness addTarget:self action:@selector(brightnessChanged:) forControlEvents:UIControlEventValueChanged];
    [_brightTile addSubview:_brightness];
    [c addSubview:_brightTile];

    _volTile = [self makeTileWithIcon:@"♪  Volume"];
    _volume = [[MPVolumeView alloc] init];
    [_volTile addSubview:_volume];
    [c addSubview:_volTile];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = 82;
    [c addSubview:_table];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.text = @"Aucune notification";
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    _emptyLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    [c addSubview:_emptyLabel];

    _handle = [[UIView alloc] init];
    _handle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.5];
    _handle.layer.cornerRadius = 2.5;
    [c addSubview:_handle];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    [self.view addGestureRecognizer:pan];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat w = b.size.width, m = 16, y = 30;
    _dim.frame = b;
    _panelHeight = MIN(b.size.height * 0.82, 740);
    [self setProgress:_progress];

    _timeLabel.frame = CGRectMake(m, y, w / 2, 66);
    _dateLabel.frame = CGRectMake(m + 2, y + 64, w / 2, 22);
    _clearButton.frame = CGRectMake(w - m - 120, y + 24, 120, 34);
    y += 102;

    CGFloat tw = (w - 3 * m) / 2;
    _brightTile.frame = CGRectMake(m, y, tw, 84);
    _volTile.frame = CGRectMake(2 * m + tw, y, tw, 84);
    _brightness.frame = CGRectMake(14, 44, tw - 28, 28);
    _volume.frame = CGRectMake(14, 44, tw - 28, 28);
    y += 84 + 14;

    _table.frame = CGRectMake(0, y, w, MAX(0, _panelHeight - y - 28));
    _emptyLabel.frame = CGRectMake(0, y + 30, w, 30);
    _handle.frame = CGRectMake((w - 44) / 2, _panelHeight - 16, 44, 5);

    if (fabs(w - _lastWidth) > 1) {
        _lastWidth = w;
        [_table reloadData];
    }
}

#pragma mark Progression / animation

- (void)setProgress:(CGFloat)p {
    _progress = MAX(0, MIN(1, p));
    CGFloat w = self.view.bounds.size.width;
    if (_progress > 0.001) _panel.hidden = NO;
    _panel.frame = CGRectMake(0, -_panelHeight + _panelHeight * _progress, w, _panelHeight);
    _dim.alpha = 0.45 * _progress;
}

- (void)animateTo:(CGFloat)target {
    _animating = YES;
    if (target > 0) [self refresh];
    [self startTimer];
    [UIView animateWithDuration:0.30
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ [self setProgress:target]; }
                     completion:^(BOOL finished) {
                         _animating = NO;
                         if (_progress <= 0.001) {
                             _panel.hidden = YES;
                             [self stopTimer];
                         }
                     }];
}

- (void)open { [self animateTo:1]; }
- (void)close { [self animateTo:0]; }

#pragma mark Geste

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (![g isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    UIPanGestureRecognizer *p = (UIPanGestureRecognizer *)g;
    CGPoint v = [p velocityInView:self.view];
    if (fabs(v.y) < fabs(v.x)) return NO;

    if (_progress <= 0.001 && !_animating) return v.y > 0;   // fermé : seulement vers le bas
    if (v.y > 0 && _progress >= 0.999) return NO;            // ouvert : seulement vers le haut

    CGPoint lt = [p locationInView:_table];
    if (!_table.hidden && CGRectContainsPoint(_table.bounds, lt)) {
        CGFloat maxY = _table.contentSize.height - _table.bounds.size.height;
        if (maxY > 0 && _table.contentOffset.y < maxY - 1 && v.y < 0) return NO; // laisser défiler la liste
    }
    return YES;
}

- (void)pan:(UIPanGestureRecognizer *)p {
    CGFloat h = MAX(_panelHeight, 1);
    switch (p.state) {
        case UIGestureRecognizerStateBegan:
            _dragging = YES;
            _startProgress = _progress;
            [self refresh];
            [self startTimer];
            break;
        case UIGestureRecognizerStateChanged:
            [self setProgress:_startProgress + [p translationInView:self.view].y / h];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!_dragging) break;
            _dragging = NO;
            CGFloat vy = [p velocityInView:self.view].y;
            BOOL open = (vy > 400) ? YES : ((vy < -400) ? NO : (_progress > 0.5));
            [self animateTo:open ? 1 : 0];
            break;
        }
        default:
            break;
    }
}

#pragma mark Contenu

- (void)startTimer {
    if (_timer) return;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)stopTimer {
    [_timer invalidate];
    _timer = nil;
}

- (void)tick {
    NSDate *now = [NSDate date];
    _timeLabel.text = [_timeFmt stringFromDate:now];
    _dateLabel.text = [_dateFmt stringFromDate:now].capitalizedString;
}

- (void)refresh {
    [self tick];
    _brightness.value = [UIScreen mainScreen].brightness;
    [_table reloadData];
    [self updateEmpty];
}

- (void)updateEmpty {
    BOOL empty = NCLItems().count == 0;
    _emptyLabel.hidden = !empty;
    _clearButton.hidden = empty;
}

- (void)itemsChanged {
    if (!self.isViewLoaded) return;
    [_table reloadData];
    [self updateEmpty];
}

- (void)clearAll {
    [NCLItems() removeAllObjects];
    [_table reloadData];
    [self updateEmpty];
}

- (void)brightnessChanged:(UISlider *)s {
    [UIScreen mainScreen].brightness = s.value;
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)NCLItems().count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *rid = @"nclcell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:rid];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UIView *card = [[UIView alloc] init];
        card.tag = 1;
        card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        card.layer.cornerRadius = 20;
        card.layer.masksToBounds = YES;
        [cell.contentView addSubview:card];

        UILabel *app = [[UILabel alloc] init];
        app.tag = 2;
        app.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        app.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        [card addSubview:app];

        UILabel *time = [[UILabel alloc] init];
        time.tag = 3;
        time.font = [UIFont systemFontOfSize:11];
        time.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        time.textAlignment = NSTextAlignmentRight;
        [card addSubview:time];

        UILabel *title = [[UILabel alloc] init];
        title.tag = 4;
        title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        title.textColor = [UIColor whiteColor];
        [card addSubview:title];

        UILabel *msg = [[UILabel alloc] init];
        msg.tag = 5;
        msg.font = [UIFont systemFontOfSize:13];
        msg.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        msg.numberOfLines = 2;
        [card addSubview:msg];
    }

    NSDictionary *item = NCLItems()[ip.row];
    CGFloat w = tv.bounds.size.width;
    UIView *card = [cell.contentView viewWithTag:1];
    card.frame = CGRectMake(16, 4, w - 32, 74);
    CGFloat cw = card.bounds.size.width;

    UILabel *app = (UILabel *)[card viewWithTag:2];
    UILabel *time = (UILabel *)[card viewWithTag:3];
    UILabel *title = (UILabel *)[card viewWithTag:4];
    UILabel *msg = (UILabel *)[card viewWithTag:5];
    app.frame = CGRectMake(14, 8, cw - 100, 14);
    time.frame = CGRectMake(cw - 14 - 70, 8, 70, 14);
    title.frame = CGRectMake(14, 23, cw - 28, 20);
    msg.frame = CGRectMake(14, 43, cw - 28, 28);

    app.text = [item[@"app"] uppercaseString];
    time.text = [_rowFmt stringFromDate:item[@"date"]];
    title.text = item[@"title"];
    msg.text = item[@"message"];
    return cell;
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return YES; }

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Effacer";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style != UITableViewCellEditingStyleDelete) return;
    if ((NSUInteger)ip.row >= NCLItems().count) return;
    [NCLItems() removeObjectAtIndex:ip.row];
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
    [self updateEmpty];
}

@end

#pragma mark - Fenêtre

@interface NCLWindow : UIWindow
@end

@implementation NCLWindow
// Fermé : seule la bande du haut capte le toucher, tout le reste traverse vers SpringBoard.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if ([NCLController shared].active || point.y <= NCL_STRIP_HEIGHT) {
        return [super hitTest:point withEvent:event];
    }
    return nil;
}
@end

static NCLWindow *gWindow;

static void NCLSetupWindow(void) {
    if (gWindow) return;
    gWindow = [[NCLWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gWindow.windowLevel = UIWindowLevelStatusBar + 1000;
    gWindow.backgroundColor = [UIColor clearColor];
    gWindow.rootViewController = [NCLController shared];
    gWindow.hidden = NO;
}

#pragma mark - Hooks

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ NCLSetupWindow(); });
}
%end

// Récupère chaque notification publiée (selon la version d'iOS, l'une ou l'autre signature existe)
%hook BBServer
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations alwaysToLockScreen:(BOOL)lock {
    NCLAddBulletin(bulletin);
    %orig;
}
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations {
    NCLAddBulletin(bulletin);
    %orig;
}
%end

// Neutralise le centre de notifications d'origine
%hook SBNotificationCenterController
- (void)presentAnimated:(BOOL)animated {
}
- (void)presentAnimated:(BOOL)animated completion:(id)completion {
}
%end
