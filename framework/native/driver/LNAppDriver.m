// LNAppDriver: the UI journeys' driver inside the app (Debug builds only). It answers the same commands as the
// test kit's LNDriver (framework/native/testkit/LNDriver.m) for the elements on screen, but from the app's own
// view tree on its main thread: no accessibility snapshot, no XCTest wait for the app to idle, no synthesized
// touch. A control is used the way its own touch would use it (a button's primary action, a switch's value
// change, a list row's selection, a menu's action, an alert action's handler, a tab bar delegate's choice), so
// the renderer's handlers send the same events. What it does not test: touches themselves, gestures and the
// system keyboard (an element covered by another one is still refused: see `hittable`).
//
// The host (LeanNative.Journey with LEANNATIVE_DRIVER=app) launches the app with LEANNATIVE_APP_DRIVER_PORT in
// its environment; the driver connects to 127.0.0.1 on that port and then reads one JSON command per line and
// writes one JSON answer per line, as LNDriver does. launch, terminate, activate and shot are the host's own
// (simctl); `home` is answered here, then the app suspends itself.
//
// Commands: exists, gone, tap {times?}, press {seconds}, type {text}, text, state, scroll, home, log, end (and
// describe: the element's class, label and frame and the views in it, for working out why a step fails), with
// `find` as LNDriver's: id, tab, alert, button, nav, back, text, and an id or button `in` another id. An id
// <stepper>-Increment or -Decrement is that stepper's half, as XCTest names them.
#if DEBUG
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

typedef NS_ENUM(NSInteger, LNTargetKind) { LNTargetView, LNTargetAlertAction, LNTargetMenuAction, LNTargetBarItem, LNTargetTab, LNTargetBack, LNTargetStepper };

/// An element found: a view, or what is not a view of its own (an alert's action, an open menu's action, a bar
/// button item, a tab, the back button, a stepper's half).
@interface LNTarget : NSObject
@property (nonatomic) LNTargetKind kind;
@property (nonatomic, strong, nullable) UIView *view;
@property (nonatomic, strong, nullable) id item;
@property (nonatomic, strong, nullable) id owner;
@property (nonatomic) BOOL increment;
@end
@implementation LNTarget
@end

static NSTimeInterval const LNAppearTimeout = 20, LNEnabledTimeout = 15, LNHittableTimeout = 5;

/// The menu a tap on a menu button opened: its actions are `button`s until the next tap.
static UIMenu *LNOpenMenu;
static __weak UIView *LNOpenMenuButton;

static NSString *LNStripped(NSString *text) { return [text stringByReplacingOccurrencesOfString:@"​" withString:@""]; }
static NSNumber *LNBool(BOOL b) { return b ? @YES : @NO; }

// -- what is on screen ----------------------------------------------------------------------------------

static NSArray<UIWindow *> *LNWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (!w.hidden) [windows addObject:w];
    }
    // the topmost first: an alert's or the keyboard's window over the app's
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : a.windowLevel < b.windowLevel ? NSOrderedDescending : NSOrderedSame;
    }];
    return windows;
}

static UIViewController *LNTopController(UIWindow *w) {
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

/// The app's window: the one with the shell's root controller.
static UIWindow *LNAppWindow(void) {
    for (UIWindow *w in LNWindows()) if (w.rootViewController && !w.rootViewController.presentingViewController) {
        if ([NSStringFromClass(w.class) containsString:@"Keyboard"] || [NSStringFromClass(w.class) containsString:@"TextEffects"]) continue;
        return w;
    }
    return nil;
}

/// Where elements are looked for: what is presented on top (a sheet, an alert) shuts out what is under it, as
/// it does for VoiceOver and XCTest; the keyboard's window (its Done bar) besides.
static NSArray<UIView *> *LNRoots(void) {
    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    UIWindow *app = LNAppWindow();
    for (UIWindow *w in LNWindows()) {
        if (w == app) {
            UIViewController *top = LNTopController(w);
            [roots addObject:top == w.rootViewController ? w : top.view];
        } else if ([NSStringFromClass(w.class) containsString:@"Keyboard"] || [NSStringFromClass(w.class) containsString:@"TextEffects"]) {
            [roots addObject:w];
        }
    }
    return roots;
}

/// On screen: in a window, neither it nor anything around it hidden or transparent.
static BOOL LNVisible(UIView *v) {
    if (!v.window) return NO;
    for (UIView *u = v; u; u = u.superview) if (u.hidden || u.alpha < 0.01) return NO;
    return YES;
}

/// What XCTest reads as the element's label, else its value (LNText).
static NSString *LNLabel(UIView *v) {
    if ([v isKindOfClass:UITextField.class]) {
        UITextField *f = (UITextField *)v;
        return f.text.length ? f.text : f.placeholder ?: @"";
    }
    if ([v isKindOfClass:UITextView.class]) return ((UITextView *)v).text ?: @"";
    if ([v isKindOfClass:UIButton.class]) {
        UIButton *b = (UIButton *)v;
        NSString *t = b.configuration.title ?: b.currentTitle;
        if (t.length) return t;
    }
    if (v.accessibilityLabel.length) return v.accessibilityLabel;
    if ([v isKindOfClass:UILabel.class]) return ((UILabel *)v).text ?: ((UILabel *)v).attributedText.string ?: @"";
    // a box around its text (an identified wrapper): the labels in it, as XCTest reads such an element
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (UIView *s in v.subviews) {
        NSString *t = [s isKindOfClass:UIControl.class] ? @"" : LNLabel(s);
        if (t.length) [texts addObject:t];
    }
    return [texts componentsJoinedByString:@" "];
}

/// Each visible view under `root`, depth first, until `visit` says stop; then the rows of its lists that are
/// out of view (the shell builds every row: LNList), each scrolled to before it is visited.
static BOOL LNEach(UIView *root, BOOL (^visit)(UIView *v)) {
    if (!LNVisible(root) && root.window) return NO;
    if (visit(root)) return YES;
    for (UIView *s in root.subviews.reverseObjectEnumerator) if (LNEach(s, visit)) return YES;
    return NO;
}

static BOOL LNEachOffscreenRow(UIView *root, BOOL (^visit)(UIView *v)) {
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    LNEach(root, ^BOOL(UIView *v) {
        if ([v isKindOfClass:UITableView.class]) [tables addObject:(UITableView *)v];
        return NO;
    });
    for (UITableView *t in tables) {
        if (!t.dataSource) continue;
        NSInteger sections = [t.dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)] ? [t.dataSource numberOfSectionsInTableView:t] : 1;
        for (NSInteger s = 0; s < sections; s++) {
            NSInteger rows = [t.dataSource tableView:t numberOfRowsInSection:s];
            for (NSInteger r = 0; r < rows; r++) {
                NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
                if ([t.indexPathsForVisibleRows containsObject:ip]) continue;
                UITableViewCell *cell = [t.dataSource tableView:t cellForRowAtIndexPath:ip];
                __block BOOL hit = NO;
                LNEach(cell, ^BOOL(UIView *v) { return hit = visit(v); });
                if (hit) {
                    [t scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                    [t layoutIfNeeded];
                    return YES;
                }
            }
        }
    }
    return NO;
}

/// The first visible view under `roots` that `match` takes, the out-of-view list rows last.
static UIView *LNFindView(NSArray<UIView *> *roots, BOOL (^match)(UIView *v)) {
    __block UIView *found = nil;
    for (UIView *root in roots) if (LNEach(root, ^BOOL(UIView *v) { if (match(v)) { found = v; return YES; } return NO; })) return found;
    // a row out of view: matched on its cell's views, then found again where scrolling put it
    for (UIView *root in roots) if (LNEachOffscreenRow(root, ^BOOL(UIView *v) { return match(v); })) break;
    for (UIView *root in roots) if (LNEach(root, ^BOOL(UIView *v) { if (match(v)) { found = v; return YES; } return NO; })) return found;
    return nil;
}

/// The navigation controllers on screen, the innermost (a sheet's, the selected tab's) first.
static NSArray<UINavigationController *> *LNNavigations(void) {
    NSMutableArray<UINavigationController *> *navs = [NSMutableArray array];
    for (UIView *root in LNRoots()) LNEach(root, ^BOOL(UIView *v) {
        if ([v isKindOfClass:UINavigationBar.class] && [v.superview isKindOfClass:UIView.class]) {
            UIResponder *r = v;
            while (r && ![r isKindOfClass:UINavigationController.class]) r = r.nextResponder;
            if (r && ![navs containsObject:(id)r]) [navs insertObject:(UINavigationController *)r atIndex:0];
        }
        return NO;
    });
    return navs;
}

static NSArray<UIBarButtonItem *> *LNBarItems(void) {
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    for (UINavigationController *nav in LNNavigations()) {
        UINavigationItem *top = nav.topViewController.navigationItem;
        [items addObjectsFromArray:top.leftBarButtonItems ?: @[]];
        [items addObjectsFromArray:top.rightBarButtonItems ?: @[]];
        if (!nav.toolbarHidden) [items addObjectsFromArray:nav.topViewController.toolbarItems ?: @[]];
    }
    return items;
}

static NSString *LNItemTitle(UIBarButtonItem *item) {
    return item.title.length ? item.title : item.accessibilityLabel.length ? item.accessibilityLabel : item.primaryAction.title ?: @"";
}

static UITabBarController *LNTabs(void) {
    __block UITabBarController *tabs = nil;
    UIWindow *w = LNAppWindow();
    if (!w || LNTopController(w) != w.rootViewController) return nil;
    LNEach(w, ^BOOL(UIView *v) {
        UIResponder *r = v.nextResponder;
        if ([r isKindOfClass:UITabBarController.class]) { tabs = (UITabBarController *)r; return YES; }
        return NO;
    });
    return tabs;
}

static UIAlertController *LNAlert(void) {
    UIWindow *w = LNAppWindow();
    UIViewController *top = w ? LNTopController(w) : nil;
    return [top isKindOfClass:UIAlertController.class] ? (UIAlertController *)top : nil;
}

static LNTarget *LNMake(LNTargetKind kind, UIView *view, id item, id owner) {
    LNTarget *t = [LNTarget new];
    t.kind = kind;
    t.view = view;
    t.item = item;
    t.owner = owner;
    return t;
}

static LNTarget *LNFindIn(NSArray<UIView *> *roots, NSDictionary *find);

/// The element `find` names now, or nil; `name` for errors. Main thread.
static LNTarget *LNFind(NSDictionary *find, NSString **name) {
    if ([find[@"in"] isKindOfClass:NSString.class]) {
        NSString *what = find[@"id"] ?: find[@"button"] ? [NSString stringWithFormat:@"the button %@", find[@"button"]] : find.description;
        *name = [NSString stringWithFormat:@"%@ in %@", what, find[@"in"]];
        LNTarget *parent = LNFindIn(LNRoots(), @{@"id": find[@"in"]});
        if (!parent.view) return nil;
        NSMutableDictionary *inner = [find mutableCopy];
        [inner removeObjectForKey:@"in"];
        return LNFindIn(@[parent.view], inner);
    }
    if ([find[@"id"] isKindOfClass:NSString.class]) *name = find[@"id"];
    else if ([find[@"tab"] isKindOfClass:NSString.class]) *name = [NSString stringWithFormat:@"the %@ tab", find[@"tab"]];
    else if ([find[@"alert"] isKindOfClass:NSString.class]) *name = [NSString stringWithFormat:@"the alert's %@", find[@"alert"]];
    else if ([find[@"button"] isKindOfClass:NSString.class]) *name = [NSString stringWithFormat:@"the button %@", find[@"button"]];
    else if ([find[@"nav"] isKindOfClass:NSString.class]) *name = [NSString stringWithFormat:@"the %@ navigation bar", find[@"nav"]];
    else if ([find[@"back"] isEqual:@YES]) *name = @"the back button";
    else if ([find[@"text"] isKindOfClass:NSString.class]) *name = [NSString stringWithFormat:@"a text matching %@", find[@"text"]];
    else *name = find.description;
    return LNFindIn(LNRoots(), find);
}

static LNTarget *LNFindIn(NSArray<UIView *> *roots, NSDictionary *find) {
    NSString *ident = [find[@"id"] isKindOfClass:NSString.class] ? find[@"id"] : nil;
    if (ident) {
        // a bar button item first: UIKit puts its identifier on a private view of the bar too, which takes no
        // sent actions
        for (UIBarButtonItem *item in LNBarItems())
            if ([item.accessibilityIdentifier isEqualToString:ident]) return LNMake(LNTargetBarItem, nil, item, nil);
        UIView *v = LNFindView(roots, ^BOOL(UIView *u) { return [u.accessibilityIdentifier isEqualToString:ident]; });
        if (v) return LNMake(LNTargetView, v, nil, nil);
        // a stepper's half: <stepper>-Increment, <stepper>-Decrement
        for (NSString *half in @[@"-Increment", @"-Decrement"]) {
            if (![ident hasSuffix:half]) continue;
            NSString *stepperID = [ident substringToIndex:ident.length - half.length];
            UIView *s = LNFindView(roots, ^BOOL(UIView *u) { return [u isKindOfClass:UIStepper.class] && [u.accessibilityIdentifier isEqualToString:stepperID]; });
            if (s) {
                LNTarget *t = LNMake(LNTargetStepper, s, nil, nil);
                t.increment = [half isEqualToString:@"-Increment"];
                return t;
            }
        }
        return nil;
    }
    if ([find[@"button"] isKindOfClass:NSString.class]) {
        NSString *label = find[@"button"];
        UIView *menuButton = LNOpenMenuButton;
        if (LNOpenMenu && menuButton.window) {
            for (UIMenuElement *e in LNOpenMenu.children)
                if ([e isKindOfClass:UIAction.class] && [e.title isEqualToString:label]) return LNMake(LNTargetMenuAction, menuButton, e, nil);
        }
        UIView *v = LNFindView(roots, ^BOOL(UIView *u) { return [u isKindOfClass:UIButton.class] && [LNLabel(u) isEqualToString:label]; });
        if (v) return LNMake(LNTargetView, v, nil, nil);
        for (UIBarButtonItem *item in LNBarItems()) if ([LNItemTitle(item) isEqualToString:label]) return LNMake(LNTargetBarItem, nil, item, nil);
        return nil;
    }
    if ([find[@"alert"] isKindOfClass:NSString.class]) {
        UIAlertController *alert = LNAlert();
        for (UIAlertAction *a in alert.actions) if ([a.title isEqualToString:find[@"alert"]]) return LNMake(LNTargetAlertAction, alert.view, a, alert);
        return nil;
    }
    if ([find[@"tab"] isKindOfClass:NSString.class]) {
        UITabBarController *tabs = LNTabs();
        if (!tabs) return nil;
        if (@available(iOS 18.0, *)) {
            for (UITab *tab in tabs.tabs) if ([tab.title isEqualToString:find[@"tab"]]) return LNMake(LNTargetTab, nil, tab, tabs);
        } else {
            for (UIViewController *vc in tabs.viewControllers) if ([vc.tabBarItem.title isEqualToString:find[@"tab"]]) return LNMake(LNTargetTab, nil, vc, tabs);
        }
        return nil;
    }
    if ([find[@"nav"] isKindOfClass:NSString.class]) {
        for (UINavigationController *nav in LNNavigations()) {
            NSString *title = nav.topViewController.navigationItem.title ?: nav.topViewController.title;
            if (!nav.navigationBarHidden && [title isEqualToString:find[@"nav"]]) return LNMake(LNTargetView, nav.navigationBar, nil, nil);
        }
        return nil;
    }
    if ([find[@"back"] isEqual:@YES]) {
        // the navigation bar's first button: the screen's own back item, else the system's back
        UINavigationController *nav = LNNavigations().firstObject;
        UINavigationItem *top = nav.topViewController.navigationItem;
        if (top.leftBarButtonItems.count) return LNMake(LNTargetBarItem, nil, top.leftBarButtonItems.firstObject, nil);
        if (nav.viewControllers.count > 1 && !top.hidesBackButton) return LNMake(LNTargetBack, nav.navigationBar, nil, nav);
        return nil;
    }
    if ([find[@"text"] isKindOfClass:NSString.class]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:find[@"text"] options:0 error:nil];
        if (!re) return nil;
        UIView *v = LNFindView(roots, ^BOOL(UIView *u) {
            if (![u isKindOfClass:UILabel.class] && ![u isKindOfClass:UIButton.class] && !u.isAccessibilityElement) return NO;
            NSString *label = LNStripped(LNLabel(u));
            return label.length && [re firstMatchInString:label options:0 range:NSMakeRange(0, label.length)] != nil;
        });
        return v ? LNMake(LNTargetView, v, nil, nil) : nil;
    }
    return nil;
}

// -- state ----------------------------------------------------------------------------------------------

/// No sheet, alert or screen is coming or going. UIKit ignores a presentation or dismissal asked for while
/// another one runs (a sheet closed while the one over it is still going away stays), and a touch in the
/// meantime could not have happened: XCTest's wait for the app to idle covered this, and this is the part of
/// it that matters here.
static BOOL LNSettled(void) {
    UIWindow *w = LNAppWindow();
    for (UIViewController *vc = w.rootViewController; vc; vc = vc.presentedViewController) {
        if (vc.isBeingPresented || vc.isBeingDismissed || vc.transitionCoordinator) return NO;
    }
    for (UINavigationController *nav in LNNavigations()) if (nav.transitionCoordinator) return NO;
    return YES;
}

static BOOL LNEnabled(LNTarget *t) {
    switch (t.kind) {
        case LNTargetAlertAction: return ((UIAlertAction *)t.item).enabled;
        case LNTargetMenuAction: return !(((UIAction *)t.item).attributes & UIMenuElementAttributesDisabled);
        case LNTargetBarItem: return ((UIBarButtonItem *)t.item).enabled;
        case LNTargetStepper: {
            UIStepper *s = (UIStepper *)t.view;
            return s.enabled && (s.wraps || (t.increment ? s.value < s.maximumValue : s.value > s.minimumValue));
        }
        case LNTargetView:
            for (UIView *v = t.view; v; v = v.superview) if ([v isKindOfClass:UIControl.class]) return ((UIControl *)v).enabled;
            return YES;
        default: return YES;
    }
}

/// Where a finger would touch it (XCTest's hit point): the middle of the part of it on screen, inside the
/// window and every scroll view around it, less the bars over their edges (their adjusted insets). A block
/// taller than the screen is touched in its visible part, not at its own middle. Null when none of it shows.
static CGPoint LNHitPoint(UIView *v) {
    if (!v.window) return CGPointMake(NAN, NAN);
    CGRect visible = CGRectIntersection([v convertRect:v.bounds toView:nil], v.window.bounds);
    for (UIView *s = v.superview; s && !CGRectIsNull(visible); s = s.superview) {
        if (![s isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (UIScrollView *)s;
        CGRect shown = UIEdgeInsetsInsetRect(scroll.bounds, scroll.adjustedContentInset);
        visible = CGRectIntersection(visible, [scroll convertRect:shown toView:nil]);
    }
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return CGPointMake(NAN, NAN);
    return CGPointMake(CGRectGetMidX(visible), CGRectGetMidY(visible));
}

/// Whether a touch at its hit point would reach it: on screen and not under something else (a sheet's
/// dimming, another view). A view that takes no touches (a label) only needs to be in the window.
static BOOL LNHittable(LNTarget *t) {
    if (t.kind != LNTargetView && t.kind != LNTargetStepper) return YES;
    UIView *v = t.view;
    if (!LNVisible(v)) return NO;
    CGPoint mid = LNHitPoint(v);
    if (isnan(mid.x)) return NO;
    UIView *hit = [v.window hitTest:mid withEvent:nil];
    if (!hit) return NO;
    return hit == v || [hit isDescendantOfView:v] || [v isDescendantOfView:hit];
}

/// Why LNHittable says no: where it is, where a touch would go and what that touch reaches.
static NSString *LNWhyNotHittable(LNTarget *t) {
    UIView *v = t.view;
    if (!v.window) return @"it is in no window";
    if (!LNVisible(v)) return @"it or a view around it is hidden";
    CGRect frame = [v convertRect:v.bounds toView:nil];
    CGPoint mid = LNHitPoint(v);
    if (isnan(mid.x))
        return [NSString stringWithFormat:@"none of it is on screen (frame %@, window %@)", NSStringFromCGRect(frame), NSStringFromCGRect(v.window.bounds)];
    UIView *hit = [v.window hitTest:mid withEvent:nil];
    return [NSString stringWithFormat:@"a touch at %@ (frame %@, window %@) reaches %@ id=%@", NSStringFromCGPoint(mid), NSStringFromCGRect(frame),
            NSStringFromCGRect(v.window.bounds), hit ? NSStringFromClass(hit.class) : @"nothing", hit.accessibilityIdentifier ?: @""];
}

/// Scrolls every scroll view around it so that it is in view.
static void LNScrollIntoView(LNTarget *t) {
    UIView *v = t.view;
    if (!v || t.kind == LNTargetAlertAction || t.kind == LNTargetMenuAction) return;
    for (UIView *s = v.superview; s; s = s.superview) {
        if (![s isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (UIScrollView *)s;
        [scroll scrollRectToVisible:CGRectInset([v convertRect:v.bounds toView:scroll], 0, -24) animated:NO];
    }
    [v.window layoutIfNeeded];
}

// -- actions --------------------------------------------------------------------------------------------

/// A touch's effect on this view: its control's, else its list row's.
static void LNActivateView(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:UISwitch.class]) {
            UISwitch *sw = (UISwitch *)v;
            [sw setOn:!sw.on animated:YES];
            [sw sendActionsForControlEvents:UIControlEventValueChanged];
            return;
        }
        if ([v isKindOfClass:UIButton.class] && ((UIButton *)v).showsMenuAsPrimaryAction && ((UIButton *)v).menu) {
            LNOpenMenu = ((UIButton *)v).menu;
            LNOpenMenuButton = v;
            return;
        }
        if ([v isKindOfClass:UITextField.class] || [v isKindOfClass:UITextView.class]) {
            [v becomeFirstResponder];
            return;
        }
        if ([v isKindOfClass:UIControl.class] && ![v isKindOfClass:UIStepper.class]) {
            // one of the two: a button's touch-up also sends its primary action, so both would act twice
            UIControl *c = (UIControl *)v;
            BOOL primary = [c isKindOfClass:UIButton.class] || (c.allControlEvents & UIControlEventPrimaryActionTriggered);
            [c sendActionsForControlEvents:primary ? UIControlEventPrimaryActionTriggered : UIControlEventTouchUpInside];
            return;
        }
        if ([v isKindOfClass:UITableViewCell.class]) {
            UIView *table = v.superview;
            while (table && ![table isKindOfClass:UITableView.class]) table = table.superview;
            UITableView *t = (UITableView *)table;
            NSIndexPath *ip = [t indexPathForCell:(UITableViewCell *)v];
            if (!ip || !t.delegate) return;
            if ([t.delegate respondsToSelector:@selector(tableView:willSelectRowAtIndexPath:)])
                ip = [t.delegate tableView:t willSelectRowAtIndexPath:ip];
            if (ip && [t.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)])
                [t.delegate tableView:t didSelectRowAtIndexPath:ip];
            return;
        }
    }
}

static void LNActivate(LNTarget *t) {
    UIMenu *menu = LNOpenMenu;
    LNOpenMenu = nil;
    switch (t.kind) {
        case LNTargetView: {
            // where a finger at its hit point lands (a row's button, the row itself), if that is in it
            UIView *v = t.view;
            CGPoint mid = LNHitPoint(v);
            UIView *hit = isnan(mid.x) ? nil : [v.window hitTest:mid withEvent:nil];
            LNActivateView(hit && [hit isDescendantOfView:v] ? hit : v);
            break;
        }
        case LNTargetMenuAction:
            if (menu) [(UIAction *)t.item performWithSender:t.view target:nil];
            break;
        case LNTargetAlertAction: {
            // the action's handler (the renderer's: the event); the alert goes when the view drops it
            void (^handler)(UIAlertAction *) = [t.item valueForKey:@"handler"];
            if (handler) handler(t.item);
            break;
        }
        case LNTargetBarItem: {
            UIBarButtonItem *item = t.item;
            if (item.primaryAction) [item.primaryAction performWithSender:item target:nil];
            else if (item.target && item.action) [UIApplication.sharedApplication sendAction:item.action to:item.target from:item forEvent:nil];
            break;
        }
        case LNTargetTab: {
            UITabBarController *tabs = t.owner;
            if (@available(iOS 18.0, *)) {
                if ([tabs.delegate respondsToSelector:@selector(tabBarController:shouldSelectTab:)] && [tabs.delegate tabBarController:tabs shouldSelectTab:t.item])
                    tabs.selectedTab = t.item;
            } else if ([tabs.delegate tabBarController:tabs shouldSelectViewController:t.item]) {
                tabs.selectedViewController = t.item;
            }
            break;
        }
        case LNTargetBack: [(UINavigationController *)t.owner popViewControllerAnimated:YES]; break;
        case LNTargetStepper: {
            UIStepper *s = (UIStepper *)t.view;
            double v = s.value + (t.increment ? s.stepValue : -s.stepValue);
            s.value = MAX(s.minimumValue, MIN(s.maximumValue, v));
            [s sendActionsForControlEvents:UIControlEventValueChanged];
            break;
        }
    }
}

static void LNReplaceText(LNTarget *t, NSString *text) {
    __block UIView *field = nil;
    if ([t.view isKindOfClass:UITextField.class] || [t.view isKindOfClass:UITextView.class]) field = t.view;
    else LNEach(t.view, ^BOOL(UIView *v) {
        if ([v isKindOfClass:UITextField.class] || [v isKindOfClass:UITextView.class]) { field = v; return YES; }
        return NO;
    });
    // the text set and its change sent, without the keyboard (closed again at once after typing, as LNTest does)
    if ([field isKindOfClass:UITextField.class]) {
        ((UITextField *)field).text = text;
        [(UITextField *)field sendActionsForControlEvents:UIControlEventEditingChanged];
    } else if ([field isKindOfClass:UITextView.class]) {
        UITextView *view = (UITextView *)field;
        view.text = text;
        if ([view.delegate respondsToSelector:@selector(textViewDidChange:)]) [view.delegate textViewDidChange:view];
    }
    [field resignFirstResponder];
}

// -- the commands ---------------------------------------------------------------------------------------

static id LNOnMain(id (^work)(void)) {
    if (NSThread.isMainThread) return work();
    __block id result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = work(); });
    return result;
}

/// Polls `condition` on the main thread every 50 ms until it holds or `timeout` passes (the main thread runs
/// the app in between).
static BOOL LNPoll(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        if ([LNOnMain(^id { return LNBool(condition()); }) boolValue]) return YES;
        if (end.timeIntervalSinceNow <= 0) return NO;
        usleep(50000);
    }
}

/// The element, present, scrolled into view, reachable and enabled; nil with why not.
static LNTarget *LNReady(NSDictionary *find, NSString **name, NSString **why) {
    __block LNTarget *t = nil;
    __block NSString *n = nil;
    if (!LNPoll(LNAppearTimeout, ^BOOL { NSString *s; t = LNFind(find, &s); n = s; return t != nil; })) {
        *name = n;
        *why = [NSString stringWithFormat:@"%@ does not appear within %.0f s", n, LNAppearTimeout];
        return nil;
    }
    *name = n;
    // found again on each look: the view a new tree put there
    BOOL inView = LNPoll(LNHittableTimeout, ^BOOL {
        NSString *s;
        LNTarget *now = LNFind(find, &s);
        if (!now) return NO;
        LNScrollIntoView(now);
        t = now;
        return LNHittable(now);
    });
    if (!inView) {
        NSString *detail = LNOnMain(^id { NSString *s; LNTarget *now = LNFind(find, &s); return now ? LNWhyNotHittable(now) : @"it went"; });
        *why = [NSString stringWithFormat:@"%@ cannot be brought into view: %@", n, detail];
        return nil;
    }
    if (!LNPoll(LNEnabledTimeout, ^BOOL { NSString *s; LNTarget *now = LNFind(find, &s); if (now) t = now; return now && LNEnabled(now); })) {
        *why = [NSString stringWithFormat:@"%@ stays disabled for %.0f s", n, LNEnabledTimeout];
        return nil;
    }
    if (!LNPoll(LNHittableTimeout, ^BOOL { return LNSettled(); })) {
        *why = [NSString stringWithFormat:@"the screen is still changing after %.0f s (a sheet or screen coming or going)", LNHittableTimeout];
        return nil;
    }
    return t;
}

static NSDictionary *LNOK(NSDictionary *more) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObject:@YES forKey:@"ok"];
    if (more) [d addEntriesFromDictionary:more];
    return d;
}
static NSDictionary *LNRefuse(NSString *why) { return @{@"ok": @NO, @"error": why}; }

static NSDictionary *LNAnswer(NSDictionary *command, BOOL *ended) {
    NSString *op = command[@"op"];
    NSTimeInterval timeout = [command[@"timeout"] respondsToSelector:@selector(doubleValue)] ? [command[@"timeout"] doubleValue] : LNAppearTimeout;
    if ([op isEqualToString:@"end"]) { *ended = YES; return LNOK(nil); }
    if ([op isEqualToString:@"log"]) { NSLog(@"journey: %@", command[@"message"]); return LNOK(nil); }
    if ([op isEqualToString:@"home"]) {
        // answered first: the app is suspended once it is in the background
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIApplication.sharedApplication performSelector:NSSelectorFromString(@"suspend")];
        });
        return LNOK(nil);
    }
    NSDictionary *find = [command[@"find"] isKindOfClass:NSDictionary.class] ? command[@"find"] : nil;
    if (!find) return LNRefuse([NSString stringWithFormat:@"%@: no find", op]);
    __block NSString *name = nil;
    if ([op isEqualToString:@"exists"])
        return LNOK(@{@"exists": LNBool(LNPoll(MAX(timeout, 0), ^BOOL { NSString *s; BOOL f = LNFind(find, &s) != nil; name = s; return f; }))});
    if ([op isEqualToString:@"gone"])
        return LNOK(@{@"gone": LNBool(LNPoll(MAX(timeout, 0), ^BOOL { NSString *s; return LNFind(find, &s) == nil; }))});
    if ([op isEqualToString:@"text"]) {
        __block NSString *text = nil;
        if (!LNPoll(MAX(timeout, 0), ^BOOL {
                NSString *s;
                LNTarget *t = LNFind(find, &s);
                name = s;
                if (!t) return NO;
                text = t.kind == LNTargetView ? LNLabel(t.view) : t.kind == LNTargetBarItem ? LNItemTitle(t.item)
                     : [t.item respondsToSelector:@selector(title)] ? [t.item title] : @"";
                return YES;
            }))
            return LNRefuse([NSString stringWithFormat:@"%@ does not appear within %.0f s", name, timeout]);
        return LNOK(@{@"text": LNStripped(text ?: @"")});
    }
    if ([op isEqualToString:@"state"]) {
        return LNOnMain(^id {
            NSString *s;
            LNTarget *t = LNFind(find, &s);
            return LNOK(@{@"exists": LNBool(t != nil), @"enabled": LNBool(t && LNEnabled(t)), @"hittable": LNBool(t && LNHittable(t))});
        });
    }
    if ([op isEqualToString:@"describe"]) {
        // what was found, for a journey's failure: its class, label, frame and the views in it
        return LNOnMain(^id {
            NSString *s;
            LNTarget *t = LNFind(find, &s);
            if (!t) return LNOK(@{@"exists": @NO});
            NSMutableArray *tree = [NSMutableArray array];
            void (^__block walk)(UIView *, NSInteger) = nil;
            void (^w)(UIView *, NSInteger) = ^(UIView *v, NSInteger depth) {
                if (depth > 6 || tree.count > 60) return;
                [tree addObject:[NSString stringWithFormat:@"%@%@ id=%@ label=%@ hidden=%d frame=%@", [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
                                 NSStringFromClass(v.class), v.accessibilityIdentifier ?: @"", LNLabel(v), v.hidden, NSStringFromCGRect(v.frame)]];
                for (UIView *c in v.subviews) walk(c, depth + 1);
            };
            walk = w;
            if (t.view) w(t.view, 0);
            return LNOK(@{@"exists": @YES, @"kind": @(t.kind), @"tree": tree});
        });
    }
    if ([op isEqualToString:@"scroll"]) {
        // as long as a tap waits for its element to come into view; the answer says why not when it does not
        BOOL hittable = LNPoll(LNHittableTimeout, ^BOOL {
            NSString *s;
            LNTarget *t = LNFind(find, &s);
            if (!t) return NO;
            LNScrollIntoView(t);
            return LNHittable(t);
        });
        if (hittable) return LNOK(@{@"hittable": @YES});
        return LNOK(@{@"hittable": @NO, @"why": LNOnMain(^id {
            NSString *s;
            LNTarget *t = LNFind(find, &s);
            return t ? LNWhyNotHittable(t) : @"it is not there";
        })});
    }
    if ([op isEqualToString:@"tap"] || [op isEqualToString:@"press"] || [op isEqualToString:@"type"]) {
        NSString *why = nil, *n = nil;
        LNTarget *t = LNReady(find, &n, &why);
        if (!t) return LNRefuse(why);
        if ([op isEqualToString:@"type"]) {
            NSString *text = [command[@"text"] isKindOfClass:NSString.class] ? command[@"text"] : @"";
            LNOnMain(^id { LNReplaceText(t, text); return nil; });
            return LNOK(nil);
        }
        NSInteger times = [command[@"times"] respondsToSelector:@selector(integerValue)] ? MAX(1, [command[@"times"] integerValue]) : 1;
        if ([op isEqualToString:@"press"]) {
            // held down: a stepper's half repeats to its end (what a long hold does, without waiting for it);
            // anything else is one tap
            times = t.kind == LNTargetStepper ? 100000 : 1;
        }
        for (NSInteger i = 0; i < times; i++) {
            BOOL acted = [LNOnMain(^id {
                NSString *s;
                // found again after the wait for a still screen: a sheet that went may have taken it
                LNTarget *now = LNFind(find, &s);
                if (!now || !LNEnabled(now)) return @NO;
                LNActivate(now);
                return @YES;
            }) boolValue];
            if (!acted) break;
            if (times > 1) usleep(10000);
        }
        return LNOK(nil);
    }
    return LNRefuse([NSString stringWithFormat:@"unknown command %@", op]);
}

static void LNServe(uint16_t port) {
    int fd = -1;
    // the host is listening already; a few tries cover a slow start
    for (int attempt = 0; attempt < 50; attempt++) {
        fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in host = {.sin_family = AF_INET, .sin_port = htons(port)};
        host.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (fd >= 0 && connect(fd, (struct sockaddr *)&host, sizeof host) == 0) break;
        if (fd >= 0) close(fd);
        fd = -1;
        usleep(100000);
    }
    if (fd < 0) { NSLog(@"LNAppDriver: cannot reach the journey host on 127.0.0.1:%u", port); return; }
    FILE *in = fdopen(dup(fd), "r");
    char *line = NULL;
    size_t capacity = 0;
    BOOL ended = NO;
    while (!ended && getline(&line, &capacity, in) > 0) {
        @autoreleasepool {
            NSData *data = [NSData dataWithBytes:line length:strlen(line)];
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *answer;
            @try {
                answer = [command isKindOfClass:NSDictionary.class] ? LNAnswer(command, &ended) : LNRefuse(@"not a JSON object");
            } @catch (NSException *exception) {
                answer = LNRefuse([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
            }
            NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:answer options:0 error:nil] mutableCopy];
            [out appendBytes:"\n" length:1];
            for (NSUInteger sent = 0; sent < out.length;) {
                ssize_t n = send(fd, (const char *)out.bytes + sent, out.length - sent, 0);
                if (n <= 0) { ended = YES; break; }
                sent += (NSUInteger)n;
            }
        }
    }
    free(line);
    fclose(in);
    close(fd);
}

__attribute__((constructor)) static void LNAppDriverStart(void) {
    const char *port = getenv("LEANNATIVE_APP_DRIVER_PORT");
    if (!port || !*port) return;
    uint16_t p = (uint16_t)atoi(port);
    NSThread *thread = [[NSThread alloc] initWithBlock:^{ LNServe(p); }];
    thread.name = @"LNAppDriver";
    [thread start];
}
#endif
