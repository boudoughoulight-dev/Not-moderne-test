#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---- Réglages du look (modifie-les à ta guise) ----
static const CGFloat kTopInset       = 4.0;   // marge haute du fond
static const CGFloat kBottomInset    = 6.0;   // le dock "flotte" au-dessus du bas
static const CGFloat kRadius         = 30.0;  // arrondi du fond
static const CGFloat kIconSpacing    = 26.0;  // espace entre deux icônes
static const CGFloat kSidePadding    = 22.0;  // marge entre les icônes et le bord du fond
static const NSUInteger kRecentCount = 1;     // nb d'icônes à droite de la ligne (0 = ligne à la fin)
static const CGFloat kSepHeightRatio = 0.60;  // hauteur de la ligne par rapport à une icône
static const NSInteger kSepTag       = 0x5E9A;
static const NSUInteger kMaxDockIcons = 10;  // nombre max d'apps dans le dock (6 par défaut sur iPad)

@interface SBDockView : UIView
@end

static UIView *DockBackground(UIView *dock) {
    const char *names[] = { "_backgroundView", "backgroundView" };
    for (int i = 0; i < 2; i++) {
        Ivar iv = class_getInstanceVariable([dock class], names[i]);
        if (!iv) continue;
        id v = object_getIvar(dock, iv);
        if ([v isKindOfClass:[UIView class]]) return v;
    }
    return nil;
}

static BOOL NameHas(UIView *v, NSString *part) {
    return [NSStringFromClass([v class]) containsString:part];
}

%hook SBDockView

- (void)layoutSubviews {
    %orig;

    UIView *bg = DockBackground(self);
    if (!bg) return;

    UIView *list = nil;
    for (UIView *v in self.subviews) {
        if (NameHas(v, @"IconListView")) { list = v; break; }
    }
    if (!list) return;

    // 1) Icônes du dock, triées de gauche à droite
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    for (UIView *sub in list.subviews) {
        if (!sub.hidden && NameHas(sub, @"IconView")) [icons addObject:sub];
    }
    if (icons.count == 0) return;
    [icons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];

    // 2) On resserre la liste d'icônes au centre du dock (dock compact, pas pleine largeur)
    CGFloat iconW = icons[0].bounds.size.width;
    CGFloat n = (CGFloat)icons.count;
    CGRect dockB = self.bounds;
    // Beaucoup d'icônes : on réduit l'espace entre elles pour que tout tienne
    CGFloat avail = dockB.size.width - 2.0 * (kSidePadding + 8.0);
    CGFloat spacing = kIconSpacing;
    if (n > 1 && n * iconW + (n - 1) * spacing > avail) {
        spacing = MAX((avail - n * iconW) / (n - 1), 2.0);
    }
    CGFloat listW = n * iconW + (n - 1) * spacing;
    if (listW < dockB.size.width) {
        CGRect lf = list.frame;
        list.frame = CGRectMake(round((dockB.size.width - listW) / 2.0), lf.origin.y, listW, lf.size.height);
        SEL sel = NSSelectorFromString(@"layoutIconsNow");
        #pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
if ([list respondsToSelector:sel]) [list performSelector:sel];
#pragma clang diagnostic pop
    }

    // 3) Le fond épouse les icônes réellement placées
    CGRect first = [self convertRect:icons.firstObject.frame fromView:list];
    CGRect last  = [self convertRect:icons.lastObject.frame  fromView:list];
    CGFloat x0 = CGRectGetMinX(first) - kSidePadding;
    CGFloat x1 = CGRectGetMaxX(last)  + kSidePadding;
    bg.frame = CGRectMake(x0, kTopInset, x1 - x0, dockB.size.height - kTopInset - kBottomInset);
    bg.layer.cornerRadius = kRadius;
    bg.layer.masksToBounds = YES;
    bg.layer.borderWidth = 0.5;
    bg.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

    // 4) Petite ligne de séparation entre les apps et la/les dernière(s)
    UIView *sep = [self viewWithTag:kSepTag];
    if (icons.count <= kRecentCount) { sep.hidden = YES; return; }

    UIView *leftV  = icons[icons.count - kRecentCount - 1];
    UIView *rightV = icons[icons.count - kRecentCount];
    CGRect lr = [self convertRect:leftV.frame  fromView:list];
    CGRect rr = [self convertRect:rightV.frame fromView:list];
    CGFloat w = 1.0;
    CGFloat h = round(iconW * kSepHeightRatio);
    CGFloat cx = (CGRectGetMaxX(lr) + CGRectGetMinX(rr)) / 2.0;
    CGFloat cy = lr.origin.y + iconW / 2.0;

    if (!sep) {
        sep = [[UIView alloc] init];
        sep.tag = kSepTag;
        sep.userInteractionEnabled = NO;
        sep.layer.cornerRadius = 0.5;
        sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.40];
        [self addSubview:sep];
    }
    sep.hidden = NO;
    sep.frame = CGRectMake(round(cx - w / 2.0), round(cy - h / 2.0), w, h);
    [self bringSubviewToFront:sep];
}

%end

// ---- Plus d'apps dans le dock ----
@interface SBDockIconListView : UIView
@end
@interface SBDockIconListModel : NSObject
@end

%hook SBDockIconListModel
- (NSUInteger)maxNumberOfIcons { return kMaxDockIcons; }
%end

%hook SBDockIconListView
+ (NSUInteger)maxIcons { return kMaxDockIcons; }
+ (NSUInteger)iconColumnsForInterfaceOrientation:(NSInteger)orientation { return kMaxDockIcons; }
%end
