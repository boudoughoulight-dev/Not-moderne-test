// NotificationCenterLite v2 - iOS 9.3.5 / armv7 (iPad 2)
// Deux petits blocs noirs (notifications a gauche, horloge a droite),
// fond d'ecran visible, bouton Camera en bas. Glisser depuis le haut.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface UIApplication (NCL)
- (BOOL)launchApplicationWithIdentifier:(NSString *)ident suspended:(BOOL)s;
@end

#pragma mark - Vue principale

@interface NCLView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, copy) void (^onClose)(void);
- (void)reloadRows;
- (void)tick;
@end

@implementation NCLView {
    UIView *_dim, *_notifBox, *_clockBox;
    UILabel *_head, *_time, *_date;
    UIButton *_clear, *_cam;
    UIScrollView *_scroll;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor clearColor];
        self.items = [NSMutableArray array];

        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
        _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_dim];

        _notifBox = [[UIView alloc] init];
        _notifBox.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
        _notifBox.layer.cornerRadius = 14;
        _notifBox.clipsToBounds = YES;
        [self addSubview:_notifBox];

        _head = [[UILabel alloc] init];
        _head.text = @"Notifications";
        _head.textColor = [UIColor whiteColor];
        _head.font = [UIFont boldSystemFontOfSize:15];
        [_notifBox addSubview:_head];

        _clear = [UIButton buttonWithType:UIButtonTypeSystem];
        [_clear setTitle:@"Tout effacer" forState:UIControlStateNormal];
        [_clear setTitleColor:[UIColor colorWithWhite:0.8 alpha:1] forState:UIControlStateNormal];
        _clear.titleLabel.font = [UIFont systemFontOfSize:13];
        [_clear addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
        [_notifBox addSubview:_clear];

        _scroll = [[UIScrollView alloc] init];
        _scroll.showsVerticalScrollIndicator = NO;
        [_notifBox addSubview:_scroll];

        _clockBox = [[UIView alloc] init];
        _clockBox.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
        _clockBox.layer.cornerRadius = 14;
        [self addSubview:_clockBox];

        _time = [[UILabel alloc] init];
        _time.textColor = [UIColor whiteColor];
        _time.font = [UIFont systemFontOfSize:46 weight:UIFontWeightUltraLight];
        _time.textAlignment = NSTextAlignmentCenter;
        _time.adjustsFontSizeToFitWidth = YES;
        [_clockBox addSubview:_time];

        _date = [[UILabel alloc] init];
        _date.textColor = [UIColor colorWithWhite:0.85 alpha:1];
        _date.font = [UIFont systemFontOfSize:14];
        _date.textAlignment = NSTextAlignmentCenter;
        _date.adjustsFontSizeToFitWidth = YES;
        [_clockBox addSubview:_date];

        _cam = [UIButton buttonWithType:UIButtonTypeCustom];
        _cam.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
        _cam.layer.cornerRadius = 30;
        _cam.titleLabel.font = [UIFont systemFontOfSize:28];
        [_cam setTitle:@"\U0001F4F7" forState:UIControlStateNormal];
        [_cam addTarget:self action:@selector(openCamera) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_cam];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
        tap.delegate = self;
        [self addGestureRecognizer:tap];
        UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
        sw.direction = UISwipeGestureRecognizerDirectionUp;
        sw.delegate = self;
        [self addGestureRecognizer:sw];

        [self tick];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return (t.view == self || t.view == _dim);
}

- (void)close { if (self.onClose) self.onClose(); }

- (void)openCamera {
    UIApplication *a = [UIApplication sharedApplication];
    if ([a respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)])
        [a launchApplicationWithIdentifier:@"com.apple.camera" suspended:NO];
    [self close];
}

- (void)clearAll {
    [self.items removeAllObjects];
    [self reloadRows];
}

- (void)tick {
    NSDate *now = [NSDate date];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm";
    _time.text = [f stringFromDate:now];
    NSDateFormatter *d = [[NSDateFormatter alloc] init];
    d.dateFormat = @"EEEE d MMMM";
    _date.text = [d stringFromDate:now];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat m = 14, top = 30;

    CGFloat nw = MIN(360, w * 0.46);
    CGFloat nh = MIN(h * 0.62, 440);
    _notifBox.frame = CGRectMake(m, top, nw, nh);
    _head.frame = CGRectMake(14, 8, nw - 120, 24);
    _clear.frame = CGRectMake(nw - 110, 6, 100, 28);
    _scroll.frame = CGRectMake(0, 38, nw, nh - 38);

    CGFloat cw = MIN(230, w * 0.32);
    _clockBox.frame = CGRectMake(w - m - cw, top, cw, 112);
    _time.frame = CGRectMake(8, 10, cw - 16, 60);
    _date.frame = CGRectMake(8, 72, cw - 16, 24);

    _cam.frame = CGRectMake((w - 60) / 2, h - 60 - 26, 60, 60);
    [self reloadRows];
}

- (void)reloadRows {
    for (UIView *v in [_scroll.subviews copy]) [v removeFromSuperview];
    CGFloat w = _scroll.bounds.size.width, y = 0;
    if (self.items.count == 0) {
        UILabel *e = [[UILabel alloc] initWithFrame:CGRectMake(0, 20, w, 24)];
        e.text = @"Aucune notification";
        e.textColor = [UIColor colorWithWhite:0.7 alpha:1];
        e.font = [UIFont systemFontOfSize:14];
        e.textAlignment = NSTextAlignmentCenter;
        [_scroll addSubview:e];
        _scroll.contentSize = CGSizeMake(w, 60);
        return;
    }
    NSDateFormatter *tf = [[NSDateFormatter alloc] init];
    tf.dateFormat = @"HH:mm";
    for (NSDictionary *it in self.items) {
        UILabel *app = [[UILabel alloc] initWithFrame:CGRectMake(14, y + 8, w - 70, 14)];
        app.text = [it[@"app"] uppercaseString];
        app.textColor = [UIColor colorWithWhite:0.65 alpha:1];
        app.font = [UIFont boldSystemFontOfSize:11];
        [_scroll addSubview:app];

        UILabel *tm = [[UILabel alloc] initWithFrame:CGRectMake(w - 60, y + 8, 48, 14)];
        tm.text = [tf stringFromDate:(it[@"date"] ?: [NSDate date])];
        tm.textColor = [UIColor colorWithWhite:0.65 alpha:1];
        tm.font = [UIFont systemFontOfSize:11];
        tm.textAlignment = NSTextAlignmentRight;
        [_scroll addSubview:tm];
        y += 24;

        NSString *title = it[@"title"];
        if (title.length) {
            UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, y, w - 28, 18)];
            t.text = title;
            t.textColor = [UIColor whiteColor];
            t.font = [UIFont boldSystemFontOfSize:14];
            [_scroll addSubview:t];
            y += 19;
        }
        NSString *msg = it[@"message"];
        if (msg.length) {
            UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(14, y, w - 28, 10)];
            m.numberOfLines = 3;
            m.text = msg;
            m.textColor = [UIColor colorWithWhite:0.92 alpha:1];
            m.font = [UIFont systemFontOfSize:13];
            CGSize s = [m sizeThatFits:CGSizeMake(w - 28, 200)];
            m.frame = CGRectMake(14, y, w - 28, s.height);
            [_scroll addSubview:m];
            y += s.height + 2;
        }
        y += 8;
        UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(14, y, w - 14, 0.5)];
        sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        [_scroll addSubview:sep];
        y += 1;
    }
    _scroll.contentSize = CGSizeMake(w, y + 8);
}

@end

#pragma mark - Controleur

@interface NCLVC : UIViewController @end
@implementation NCLVC
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

@interface NCLController : NSObject
+ (instancetype)shared;
- (void)setup;
- (void)addItem:(NSDictionary *)d;
@end

@implementation NCLController {
    UIWindow *_edge, *_win;
    NCLView *_view;
    NSTimer *_timer;
    BOOL _shown, _triggered;
    NSMutableArray *_items;
    NSMutableSet *_ids;
}

+ (instancetype)shared {
    static NCLController *c; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [[NCLController alloc] init]; });
    return c;
}

- (void)setup {
    if (_edge) return;
    _items = [NSMutableArray array];
    _ids = [NSMutableSet set];
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat big = MAX(b.size.width, b.size.height);

    // Fenetre du panneau
    _win = [[UIWindow alloc] initWithFrame:b];
    _win.windowLevel = UIWindowLevelStatusBar + 99;
    _win.backgroundColor = [UIColor clearColor];
    NCLVC *vc = [[NCLVC alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    _win.rootViewController = vc;
    _view = [[NCLView alloc] initWithFrame:vc.view.bounds];
    _view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _view.items = _items;
    __weak NCLController *ws = self;
    _view.onClose = ^{ [ws hide]; };
    [vc.view addSubview:_view];
    _win.hidden = YES;

    // Fine bande invisible en haut pour detecter le glissement
    _edge = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, big, 12)];
    _edge.windowLevel = UIWindowLevelStatusBar + 100;
    _edge.backgroundColor = [UIColor clearColor];
    NCLVC *evc = [[NCLVC alloc] init];
    evc.view.backgroundColor = [UIColor clearColor];
    _edge.rootViewController = evc;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(edgePan:)];
    [evc.view addGestureRecognizer:pan];
    _edge.hidden = NO;
}

- (void)edgePan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _triggered = NO; return;
    }
    if (!_triggered && !_shown && [g translationInView:g.view].y > 25) {
        _triggered = YES;
        [self show];
    }
}

- (void)show {
    if (_shown) return;
    _shown = YES;
    [_view reloadRows];
    [_view tick];
    _win.hidden = NO;
    CGFloat h = _win.bounds.size.height;
    _view.transform = CGAffineTransformMakeTranslation(0, -h);
    _view.alpha = 0;
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        _view.transform = CGAffineTransformIdentity;
        _view.alpha = 1;
    } completion:nil];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1 target:_view selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)hide {
    if (!_shown) return;
    _shown = NO;
    [_timer invalidate]; _timer = nil;
    CGFloat h = _win.bounds.size.height;
    [UIView animateWithDuration:0.22 animations:^{
        _view.transform = CGAffineTransformMakeTranslation(0, -h);
        _view.alpha = 0;
    } completion:^(BOOL f) {
        _win.hidden = YES;
        _view.transform = CGAffineTransformIdentity;
    }];
}

- (void)addItem:(NSDictionary *)d {
    if (!_items) return;
    NSString *bid = d[@"id"];
    if (bid.length) {
        if ([_ids containsObject:bid]) return;
        [_ids addObject:bid];
    }
    [_items insertObject:d atIndex:0];
    while (_items.count > 30) [_items removeLastObject];
    if (_shown) [_view reloadRows];
}

@end

#pragma mark - Hooks

static NSString *NCLStr(id o, NSString *k) {
    id v = nil;
    @try { v = [o valueForKey:k]; } @catch (NSException *e) {}
    return [v isKindOfClass:[NSString class]] ? v : @"";
}

static NSString *NCLAppName(NSString *sid) {
    NSString *fallback = sid.length ? [[sid componentsSeparatedByString:@"."] lastObject] : @"";
    @try {
        Class c = NSClassFromString(@"SBApplicationController");
        id ctl = [c respondsToSelector:@selector(sharedInstance)] ? [c performSelector:@selector(sharedInstance)] : nil;
        SEL s = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        id app = (ctl && [ctl respondsToSelector:s]) ? [ctl performSelector:s withObject:sid] : nil;
        id n = (app && [app respondsToSelector:@selector(displayName)]) ? [app performSelector:@selector(displayName)] : nil;
        if ([n isKindOfClass:[NSString class]] && [n length]) return n;
    } @catch (NSException *e) {}
    return fallback;
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [[NCLController shared] setup]; } @catch (NSException *e) {}
    });
}
%end

%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)dest alwaysToLockScreen:(BOOL)lock {
    %orig;
    @try {
        NSString *sid = NCLStr(bulletin, @"sectionID");
        NSString *title = NCLStr(bulletin, @"title");
        NSString *msg = NCLStr(bulletin, @"message");
        NSString *bid = NCLStr(bulletin, @"bulletinID");
        id date = nil;
        @try { date = [bulletin valueForKey:@"date"]; } @catch (NSException *e) {}
        NSDictionary *d = @{ @"id": bid ?: @"",
                             @"app": NCLAppName(sid) ?: @"",
                             @"title": title ?: @"",
                             @"message": msg ?: @"",
                             @"date": [date isKindOfClass:[NSDate class]] ? date : [NSDate date] };
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NCLController shared] addItem:d];
        });
    } @catch (NSException *e) {}
}
%end
