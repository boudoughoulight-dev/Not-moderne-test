#import <UIKit/UIKit.h>

// Réglages du look (modifie-les à ta guise)
static const CGFloat kSideInset   = 10.0; // marge gauche/droite
static const CGFloat kBottomInset = 6.0;  // le dock "flotte" au-dessus du bas
static const CGFloat kTopInset    = 4.0;
static const CGFloat kRadius      = 30.0; // arrondi du fond
static const CGFloat kSepGap      = 14.0; // espace de secours si le dock n'a qu'une app
static const CGFloat kSepHeightRatio = 0.85; // hauteur de la ligne par rapport à une icône
static const NSInteger kSepTag    = 0x5E9A; // repère pour ne créer la ligne qu'une fois

@interface SBDockView : UIView
@end

static UIView *DockBackground(UIView *dock) {
    // Le nom de l'ivar varie selon la version d'iOS : on essaie les deux.
    for (NSString *key in @[@"backgroundView", @"_backgroundView"]) {
        @try {
            id v = [dock valueForKey:key];
            if ([v isKindOfClass:[UIView class]]) return v;
        } @catch (NSException *e) {}
    }
    return nil;
}

%hook SBDockView

- (void)layoutSubviews {
    %orig;

    UIView *bg = DockBackground(self);
    if (!bg) return;

    CGRect b = self.bounds;
    bg.frame = CGRectMake(kSideInset,
                          kTopInset,
                          b.size.width - 2 * kSideInset,
                          b.size.height - kTopInset - kBottomInset);
    bg.layer.cornerRadius = kRadius;
    bg.layer.masksToBounds = YES;
    bg.layer.borderWidth = 0.5;
    bg.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

    // --- Ligne de séparation après la dernière app du dock ---
    UIView *list = nil;
    for (UIView *v in self.subviews) {
        if ([NSStringFromClass([v class]) containsString:@"IconListView"]) { list = v; break; }
    }
    if (!list) return;

    CGRect last = CGRectNull, prev = CGRectNull;
    for (UIView *sub in list.subviews) {
        if (sub.hidden || ![NSStringFromClass([sub class]) containsString:@"IconView"]) continue;
        CGRect r = [self convertRect:sub.frame fromView:list];
        if (CGRectIsNull(last) || CGRectGetMaxX(r) > CGRectGetMaxX(last)) {
            prev = last;
            last = r;
        } else if (CGRectIsNull(prev) || CGRectGetMaxX(r) > CGRectGetMaxX(prev)) {
            prev = r;
        }
    }
    if (CGRectIsNull(last)) return;

    // Comme sur iOS 12 : la ligne est centrée entre deux icônes,
    // donc l'espace est le même que celui qui sépare les apps entre elles.
    CGFloat gap = CGRectIsNull(prev) ? kSepGap
                                     : MAX(CGRectGetMinX(last) - CGRectGetMaxX(prev), 8.0);
    CGFloat h = round(last.size.height * kSepHeightRatio);

    UIView *sep = [self viewWithTag:kSepTag];
    if (!sep) {
        sep = [[UIView alloc] init];
        sep.tag = kSepTag;
        sep.userInteractionEnabled = NO;
        sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        [self addSubview:sep];
    }
    CGFloat w = 1.0 / [UIScreen mainScreen].scale;
    sep.frame = CGRectMake(CGRectGetMaxX(last) + gap / 2.0 - w / 2.0,
                           CGRectGetMidY(last) - h / 2.0,
                           w, h);
    [self bringSubviewToFront:sep];
}

%end
