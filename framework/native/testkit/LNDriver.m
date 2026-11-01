// LNDriver: the UI journeys' driver. A journey is a Lean program on the host (LeanNative.Journey); this test
// carries out its steps in the app and answers each. It is the same for every app: framework/native/ci/ui-tests
// runs it alone (`-only-testing:<target>/LNDriver/testDrive`) when the app has a journey (UI_JOURNEY).
//
// The host listens on 127.0.0.1 (the simulator shares the Mac's network) and passes its port as
// LEANNATIVE_DRIVER_PORT (TEST_RUNNER_LEANNATIVE_DRIVER_PORT for xcodebuild). The driver connects, then reads one
// JSON command per line and writes one JSON answer per line, `{"ok":true,…}` or `{"ok":false,"error":…}`,
// until `end` or the host closes. Without the port the test is skipped, so an app's own Objective-C tests run
// as before.
//
// One snapshot per look. Every XCUIElementQuery makes the app walk its whole accessibility tree, fetching each
// element's attributes, on its main thread; a step that asks `exists`, `hittable`, `isEnabled` and then taps
// pays that four to six times, and a journey's time is mostly those walks. This driver instead takes one
// snapshot of the whole app (`-snapshotWithError:`, the same walk, once) and finds the element in it: its
// identifier, label, frame, type, whether it is enabled, and what is over it. A tap is then a touch at the
// middle of the element's visible part (`XCUICoordinate`), with no element to resolve again. What stays
// XCTest's: the touch itself, typing, and its wait for the app to go idle before each event.
//
// Commands (`find` is an element, below; `timeout` in seconds):
//   launch {env}           the app, launched again with this environment (any running one is terminated)
//   terminate
//   exists {find, timeout} {"exists": bool}: whether it appears within the timeout (0: now)
//   gone {find, timeout}   {"gone": bool}: whether it is absent, or disappears within the timeout
//   tap {find, times?}     the checks first (appears, scrolled into view, enabled, nothing over it, still), then a
//                          tap (a click on the Mac); `times` more than 1: then that many taps in all, without
//                          checking again
//   press {find, seconds}  the same checks, then the element held down for `seconds` (a stepper's autorepeat)
//   type {find, text}      the same checks, then the field's text replaced and the keyboard closed
//   text {find, timeout}   {"text": …}: its label or value, without zero-width spaces; an error if it never appears
//   state {find}           {"exists", "enabled", "hittable"}, now
//   scroll {find}          {"hittable": bool}: scrolled until it can be tapped
//   describe {find}        {"exists", "type", "label", "value", "frame", "children": […]} for working out a step
//   shot {name, directory?} a screenshot attached to the test as `name`, and written to <directory>/<name>.png
//   home, activate         (iOS) the Home button; the app brought back
//   log {message}          into the test's log
//   fail {message}         an XCTest failure with the host's message (the journey failed there), and a
//                          screenshot attached ("journey failure")
//   end
//
// An element (`find`): {"id": identifier} (any type), {"tab": title} (a tab bar button; with no tab bar, a
// button or row with that label), {"alert": button label}, {"button": label}, {"nav": title} (a navigation bar),
// {"back": true} (the navigation bar's first button, else a button BackButton or Back) or {"text": regular
// expression} (an element whose label, without zero-width spaces, matches). With "in": identifier, an "id" or
// "button" is looked for only inside that element.
//
// A refusal names what is on screen (the identifiers and labels the snapshot holds), so a journey's author sees
// what the step could have named.
#import <XCTest/XCTest.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#import "LNTest.h"

typedef id<XCUIElementSnapshot> LNNode;

// XCTest's waits for the app to go idle before and after each event stay: skipping them (XCUIApplication's
// private `_performWithInteractionOptions:block:`, tried 2026-11-01 with either bit) had touches land during a
// screen's transition, which UIKit drops, and Winnow's journeys lost taps on Receive and the member picker.

static NSTimeInterval const LNPollInterval = 0.15;
static NSTimeInterval const LNStillTimeout = 5;

static NSString *LNStripped(NSString *text) { return [text stringByReplacingOccurrencesOfString:@"​" withString:@""]; }
/// A JSON boolean: `@(a && b)` and `@(c ? x : y)` box C's int (`1`), which a JSON reader takes for a number.
static NSNumber *LNBool(BOOL b) { return b ? @YES : @NO; }

/// An element of one snapshot: the node, those above it (outermost first) and its place in the walk.
@interface LNHit : NSObject
@property (nonatomic, strong) LNNode node;
@property (nonatomic, strong) NSArray<LNNode> *ancestors;
@property (nonatomic) NSUInteger order;
@end
@implementation LNHit
@end

/// The whole snapshot as a list, in walk order (a parent before its children).
static NSArray<LNHit *> *LNFlatten(LNNode root) {
    NSMutableArray<LNHit *> *hits = [NSMutableArray array];
    NSMutableArray<LNNode> *ancestors = [NSMutableArray array];
    void (^__block walk)(LNNode) = nil;
    void (^w)(LNNode) = ^(LNNode n) {
        LNHit *h = [LNHit new];
        h.node = n;
        h.ancestors = [ancestors copy];
        h.order = hits.count;
        [hits addObject:h];
        [ancestors addObject:n];
        for (LNNode c in n.children) walk(c);
        [ancestors removeLastObject];
    };
    walk = w;
    w(root);
    return hits;
}

static NSString *LNLabelOf(LNNode n) { return LNStripped(n.label ?: @""); }
static NSString *LNTextOf(LNNode n) {
    NSString *label = LNLabelOf(n);
    if (label.length) return label;
    return [n.value isKindOfClass:NSString.class] ? LNStripped(n.value) : @"";
}
static BOOL LNIsIn(LNHit *h, LNNode container) { return [h.ancestors containsObject:container]; }

@interface LNDriver : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
/// The snapshot the current command is working from, and the elements of it.
@property (nonatomic, strong) LNNode root;
@property (nonatomic, strong) NSArray<LNHit *> *hits;
@property (nonatomic) NSUInteger snapshots;
@end

@implementation LNDriver

- (void)setUp {
    // a failed journey step is the host's to report (`fail`); the next journey still runs
    self.continueAfterFailure = YES;
    self.executionTimeAllowance = 4 * 3600;
    self.app = [XCUIApplication new];
}

/// One synthesized event (a touch, a drag, typing), with XCTest's idle waits around it.
- (void)event:(void (^)(void))block { block(); }

- (void)tearDown {
    [self.app terminate];
}

// -- looking ---------------------------------------------------------------------------------------------

/// One snapshot of the whole app; NO when there is none (the app not running).
- (BOOL)look {
    NSError *error = nil;
    LNNode root = [self.app snapshotWithError:&error];
    self.snapshots++;
    if (!root) { self.root = nil; self.hits = @[]; return NO; }
    self.root = root;
    self.hits = LNFlatten(root);
    return YES;
}

- (LNHit *)first:(BOOL (^)(LNHit *h))match {
    for (LNHit *h in self.hits) if (match(h)) return h;
    return nil;
}

- (LNHit *)firstIn:(LNNode)container matching:(BOOL (^)(LNHit *h))match {
    for (LNHit *h in self.hits) if (h.node != container && LNIsIn(h, container) && match(h)) return h;
    return nil;
}

- (LNHit *)byIdentifier:(NSString *)identifier {
    return [self first:^BOOL(LNHit *h) { return [h.node.identifier isEqualToString:identifier]; }];
}

/// The element `find` names in the current snapshot, and a name for it in errors; nil when it is not there.
/// `*known` is NO for a find this driver does not understand.
- (LNHit *)find:(NSDictionary *)find name:(NSString **)name known:(BOOL *)known {
    *known = YES;
    if ([find[@"in"] isKindOfClass:NSString.class]) {
        NSString *what = [find[@"id"] isKindOfClass:NSString.class] ? find[@"id"]
                       : [find[@"button"] isKindOfClass:NSString.class] ? [NSString stringWithFormat:@"the button %@", find[@"button"]] : find.description;
        *name = [NSString stringWithFormat:@"%@ in %@", what, find[@"in"]];
        LNHit *parent = [self byIdentifier:find[@"in"]];
        if (!parent) return nil;
        if ([find[@"id"] isKindOfClass:NSString.class])
            return [self firstIn:parent.node matching:^BOOL(LNHit *h) { return [h.node.identifier isEqualToString:find[@"id"]]; }];
        if ([find[@"button"] isKindOfClass:NSString.class])
            return [self firstIn:parent.node matching:^BOOL(LNHit *h) {
                return h.node.elementType == XCUIElementTypeButton && [LNLabelOf(h.node) isEqualToString:find[@"button"]]; }];
        *known = NO;
        return nil;
    }
    if ([find[@"id"] isKindOfClass:NSString.class]) { *name = find[@"id"]; return [self byIdentifier:find[@"id"]]; }
    if ([find[@"tab"] isKindOfClass:NSString.class]) {
        NSString *title = find[@"tab"];
        *name = [NSString stringWithFormat:@"the %@ tab", title];
        BOOL (^titled)(LNHit *) = ^BOOL(LNHit *h) {
            return (h.node.elementType == XCUIElementTypeButton || h.node.elementType == XCUIElementTypeCell) && [LNLabelOf(h.node) isEqualToString:title];
        };
        // the tab bar's button (a screen may also have a button with the tab's title); only an app with no tab
        // bar at all (a sidebar, a custom bar) gets the one anywhere
        LNHit *bar = [self first:^BOOL(LNHit *h) { return h.node.elementType == XCUIElementTypeTabBar; }];
        if (bar) return [self firstIn:bar.node matching:titled];
        return [self first:titled];
    }
    if ([find[@"alert"] isKindOfClass:NSString.class]) {
        *name = [NSString stringWithFormat:@"the alert's %@", find[@"alert"]];
        LNHit *alert = [self first:^BOOL(LNHit *h) { return h.node.elementType == XCUIElementTypeAlert; }];
        if (!alert) return nil;
        return [self firstIn:alert.node matching:^BOOL(LNHit *h) {
            return h.node.elementType == XCUIElementTypeButton && [LNLabelOf(h.node) isEqualToString:find[@"alert"]]; }];
    }
    if ([find[@"button"] isKindOfClass:NSString.class]) {
        *name = [NSString stringWithFormat:@"the button %@", find[@"button"]];
        return [self first:^BOOL(LNHit *h) {
            return h.node.elementType == XCUIElementTypeButton && [LNLabelOf(h.node) isEqualToString:find[@"button"]]; }];
    }
    if ([find[@"nav"] isKindOfClass:NSString.class]) {
        NSString *title = find[@"nav"];
        *name = [NSString stringWithFormat:@"the %@ navigation bar", title];
        return [self first:^BOOL(LNHit *h) {
            return h.node.elementType == XCUIElementTypeNavigationBar &&
                   ([h.node.identifier isEqualToString:title] || [LNLabelOf(h.node) isEqualToString:title]); }];
    }
    if ([find[@"back"] isEqual:@YES]) {
        // the navigation bar's first button; where a layout floats back outside any bar (iOS 27's iPhone Duo,
        // its tabs in a sidebar), the system's back button wherever it is
        *name = @"the back button";
        LNHit *bar = [self first:^BOOL(LNHit *h) { return h.node.elementType == XCUIElementTypeNavigationBar; }];
        LNHit *inBar = bar ? [self firstIn:bar.node matching:^BOOL(LNHit *h) { return h.node.elementType == XCUIElementTypeButton; }] : nil;
        if (inBar) return inBar;
        return [self first:^BOOL(LNHit *h) {
            return h.node.elementType == XCUIElementTypeButton &&
                   ([h.node.identifier isEqualToString:@"BackButton"] || [LNLabelOf(h.node) isEqualToString:@"Back"]); }];
    }
    if ([find[@"text"] isKindOfClass:NSString.class]) {
        *name = [NSString stringWithFormat:@"a text matching %@", find[@"text"]];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:find[@"text"] options:0 error:nil];
        if (!re) { *known = NO; return nil; }
        return [self first:^BOOL(LNHit *h) {
            NSString *label = LNLabelOf(h.node);
            return label.length && [re firstMatchInString:label options:0 range:NSMakeRange(0, label.length)] != nil; }];
    }
    *name = [NSString stringWithFormat:@"%@", find];
    *known = NO;
    return nil;
}

// -- geometry ---------------------------------------------------------------------------------------------

/// The part of the element on screen: its frame cut to the app's and to every scroll view, table and collection
/// view around it (a scroll view's frame can be its content's, far taller than the screen), and then to what the
/// bars leave: content scrolls under the translucent navigation bar, tab bar and toolbars (the scroll view's
/// adjusted content inset), and a touch there reaches the bar, not the content. A bar around the element itself
/// (its own toolbar button) does not cut it.
- (CGRect)visibleRectOf:(LNHit *)h {
    CGRect r = CGRectIntersection(h.node.frame, self.root.frame);
    for (LNNode a in h.ancestors) {
        XCUIElementType t = a.elementType;
        if (t == XCUIElementTypeScrollView || t == XCUIElementTypeTable || t == XCUIElementTypeCollectionView || t == XCUIElementTypeWindow)
            r = CGRectIntersection(r, a.frame);
    }
    for (LNHit *bar in self.hits) {
        XCUIElementType t = bar.node.elementType;
        if (t != XCUIElementTypeNavigationBar && t != XCUIElementTypeTabBar && t != XCUIElementTypeToolbar) continue;
        if (bar.node == h.node || LNIsIn(h, bar.node) || CGRectIsNull(r) || !CGRectIntersectsRect(r, bar.node.frame)) continue;
        CGRect b = bar.node.frame;
        // a bar along the top or the bottom: short, and wide unless it is the tab bar (iOS 26's floats as a
        // capsule narrower than the screen); a sidebar or a toolbar laid over the content is not one
        if (b.size.height > self.root.frame.size.height * 0.25) continue;
        if (t != XCUIElementTypeTabBar && b.size.width < self.root.frame.size.width * 0.5) continue;
        // the bar takes the top or the bottom of what is left, whichever side it is on
        if (CGRectGetMidY(b) < CGRectGetMidY(r)) {
            CGFloat top = MAX(CGRectGetMinY(r), CGRectGetMaxY(b));
            r = CGRectMake(r.origin.x, top, r.size.width, MAX(0, CGRectGetMaxY(r) - top));
        } else {
            CGFloat bottom = MIN(CGRectGetMaxY(r), CGRectGetMinY(b));
            r = CGRectMake(r.origin.x, r.origin.y, r.size.width, MAX(0, bottom - r.origin.y));
        }
    }
    return r;
}

/// Where a finger lands: the middle of the visible part; CGPointZero with NO when nothing of it is on screen.
- (BOOL)hitPointOf:(LNHit *)h point:(CGPoint *)point {
    CGRect r = [self visibleRectOf:h];
    if (CGRectIsNull(r) || CGRectIsEmpty(r) || r.size.width < 1 || r.size.height < 1) return NO;
    *point = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    return YES;
}

/// Whether the node shows something at the point: a control, a text, an image or a list there (a window that
/// holds nothing, iOS's text-effects window for one, covers nothing).
static BOOL LNShowsAt(LNNode n, CGPoint point) {
    for (LNNode c in n.children) {
        XCUIElementType t = c.elementType;
        BOOL shows = t == XCUIElementTypeButton || t == XCUIElementTypeStaticText || t == XCUIElementTypeTextField ||
                     t == XCUIElementTypeTextView || t == XCUIElementTypeSecureTextField || t == XCUIElementTypeImage ||
                     t == XCUIElementTypeCell || t == XCUIElementTypeTable || t == XCUIElementTypeScrollView ||
                     t == XCUIElementTypeCollectionView || t == XCUIElementTypeAlert || t == XCUIElementTypeSheet ||
                     t == XCUIElementTypeKeyboard || t == XCUIElementTypeSwitch || t == XCUIElementTypeStepper;
        if (shows && CGRectContainsPoint(c.frame, point)) return YES;
        if (LNShowsAt(c, point)) return YES;
    }
    return NO;
}

/// What is over the point: an alert, a sheet, the keyboard, or a later window showing something there, drawn
/// after the element (later in the walk) and not around it. Approximates XCTest's hit-test from the snapshot alone.
- (LNHit *)coverOf:(LNHit *)h at:(CGPoint)point {
    for (LNHit *c in self.hits) {
        if (c.order <= h.order || LNIsIn(h, c.node)) continue;
        XCUIElementType t = c.node.elementType;
        if (!CGRectContainsPoint(c.node.frame, point)) continue;
        if (t == XCUIElementTypeAlert || t == XCUIElementTypeSheet || t == XCUIElementTypeKeyboard) return c;
        if (t == XCUIElementTypeWindow && LNShowsAt(c.node, point)) return c;
    }
    return nil;
}

- (XCUICoordinate *)coordinateAt:(CGPoint)point {
    CGPoint origin = self.root.frame.origin;
    return [[self.app coordinateWithNormalizedOffset:CGVectorMake(0, 0)] coordinateWithOffset:CGVectorMake(point.x - origin.x, point.y - origin.y)];
}

- (void)touch:(CGPoint)point {
    XCUICoordinate *c = [self coordinateAt:point];
#if TARGET_OS_MACCATALYST
    [self event:^{ [c click]; }];
#else
    [self event:^{ [c tap]; }];
#endif
}

/// One scroll of the content, down (towards the end) or up: a drag in the middle of the screen (the bottom edge
/// belongs to the home indicator); the scroll wheel on the Mac.
- (void)scrollStep:(BOOL)down {
    CGRect f = self.root.frame;
#if TARGET_OS_MACCATALYST
    [[self coordinateAt:CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f))] scrollByDeltaX:0 deltaY:down ? -200 : 200];
#else
    CGFloat x = CGRectGetMidX(f);
    XCUICoordinate *from = [self coordinateAt:CGPointMake(x, CGRectGetMinY(f) + f.size.height * (down ? 0.7 : 0.35))];
    XCUICoordinate *to = [self coordinateAt:CGPointMake(x, CGRectGetMinY(f) + f.size.height * (down ? 0.35 : 0.7))];
    [self event:^{ [from pressForDuration:0.05 thenDragToCoordinate:to]; }];
#endif
}

// -- what is on screen, for a refusal ------------------------------------------------------------------------

- (NSString *)onScreen {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (LNHit *h in self.hits) {
        if (items.count >= 40) { [items addObject:@"…"]; break; }
        NSString *ident = h.node.identifier;
        if (ident.length) { [items addObject:ident]; continue; }
        XCUIElementType t = h.node.elementType;
        if (t == XCUIElementTypeButton || t == XCUIElementTypeNavigationBar || t == XCUIElementTypeAlert || t == XCUIElementTypeSheet) {
            NSString *label = LNLabelOf(h.node);
            if (label.length) [items addObject:[NSString stringWithFormat:@"\"%@\"", [label length] > 40 ? [[label substringToIndex:40] stringByAppendingString:@"…"] : label]];
        }
    }
    return items.count ? [items componentsJoinedByString:@", "] : @"nothing identified";
}

- (NSDictionary *)refuse:(NSString *)why {
    return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@ — on screen: %@", why, [self onScreen]]};
}

// -- readiness ---------------------------------------------------------------------------------------------

static void LNSleep(NSTimeInterval s) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }

/// Snapshots until `find` names an element or the deadline passes; the hit, in the current snapshot.
- (LNHit *)appear:(NSDictionary *)find name:(NSString **)name known:(BOOL *)known until:(NSDate *)deadline {
    while (YES) {
        if ([self look]) {
            LNHit *h = [self find:find name:name known:known];
            if (h || !*known) return h;
        }
        if (deadline.timeIntervalSinceNow <= 0) return nil;
        LNSleep(LNPollInterval);
    }
}

/// Scrolls until the element has a part on screen (or exists, for one a list makes as it scrolls in); the hit
/// in the current snapshot, or nil. An element in view already is returned at once.
- (LNHit *)intoView:(NSDictionary *)find name:(NSString **)name until:(NSDate *)deadline {
    BOOL known = YES;
    int searched = 0;
    BOOL turned = NO;
    CGFloat last = NAN;
    for (int step = 0; step < 24; step++) {
        if (![self look]) return nil;
        LNHit *h = [self find:find name:name known:&known];
        CGPoint p;
        if (h && [self hitPointOf:h point:&p]) return h;
        if (deadline.timeIntervalSinceNow <= 0) return nil;
        BOOL down;
        if (h) {
            // towards it: down while its middle is below the middle of what shows it, and the other way once a
            // step leaves it where it was (the content's end, or something over it)
            CGRect around = self.root.frame;
            for (LNNode a in h.ancestors) {
                XCUIElementType t = a.elementType;
                if (t == XCUIElementTypeScrollView || t == XCUIElementTypeTable || t == XCUIElementTypeCollectionView)
                    around = CGRectIntersection(a.frame, self.root.frame);
            }
            CGFloat y = CGRectGetMidY(h.node.frame);
            if (y == last) turned = !turned;
            last = y;
            down = (y > CGRectGetMidY(around)) != turned;
        } else {
            // not there: a list makes its rows as they come into view; 8 steps down, then up past the start
            down = searched++ < 8;
        }
        [self scrollStep:down];
    }
    return nil;
}

/// The element: appeared, in view, enabled, nothing over it, and still (its frame the same on two looks: no
/// sheet or screen is carrying it). The hit and its touch point, or nil with why not.
- (LNHit *)ready:(NSDictionary *)find name:(NSString **)name point:(CGPoint *)point why:(NSString **)why {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:LNAppearTimeout];
    BOOL known = YES;
    LNHit *h = [self appear:find name:name known:&known until:[NSDate dateWithTimeIntervalSinceNow:MIN(2, LNAppearTimeout)]];
    if (!known) { *why = [NSString stringWithFormat:@"%@: no such element", *name]; return nil; }
    CGPoint p;
    if (!h || ![self hitPointOf:h point:&p]) {
        // not there after a moment, or out of view: looked for by scrolling, then waited for the rest of the time
        h = [self intoView:find name:name until:deadline];
        if (!h) h = [self appear:find name:name known:&known until:deadline];
        if (!h) { *why = [NSString stringWithFormat:@"%@ does not appear within %.0f s, nor by scrolling", *name, LNAppearTimeout]; return nil; }
        if (![self hitPointOf:h point:&p]) { *why = [NSString stringWithFormat:@"%@ cannot be scrolled into view", *name]; return nil; }
    }
    // enabled: a control the view gives no action to stays disabled
    NSDate *enabledBy = [NSDate dateWithTimeIntervalSinceNow:LNEnabledTimeout];
    while (!h.node.isEnabled) {
        if (enabledBy.timeIntervalSinceNow <= 0) { *why = [NSString stringWithFormat:@"%@ stays disabled for %.0f s", *name, LNEnabledTimeout]; return nil; }
        LNSleep(LNPollInterval);
        if (![self look] || !(h = [self find:find name:name known:&known])) { *why = [NSString stringWithFormat:@"%@ went away while disabled", *name]; return nil; }
    }
    // still, and uncovered: the same frame on the next look (a presentation or push in flight moves it), and
    // nothing drawn over its middle
    NSDate *stillBy = [NSDate dateWithTimeIntervalSinceNow:LNStillTimeout];
    while (YES) {
        CGRect before = h.node.frame;
        LNSleep(0.05);
        if (![self look] || !(h = [self find:find name:name known:&known])) { *why = [NSString stringWithFormat:@"%@ went away", *name]; return nil; }
        if (![self hitPointOf:h point:&p]) { *why = [NSString stringWithFormat:@"%@ moved off screen", *name]; return nil; }
        LNHit *cover = [self coverOf:h at:p];
        if (CGRectEqualToRect(before, h.node.frame) && !cover) break;
        if (stillBy.timeIntervalSinceNow <= 0) {
            *why = cover ? [NSString stringWithFormat:@"%@ is under %@ (type %ld%@) after %.0f s", *name,
                            cover.node.elementType == XCUIElementTypeKeyboard ? @"the keyboard" : LNLabelOf(cover.node).length ? LNLabelOf(cover.node) : @"another view",
                            (long)cover.node.elementType, cover.node.identifier.length ? [@", " stringByAppendingString:cover.node.identifier] : @"", LNStillTimeout]
                         : [NSString stringWithFormat:@"%@ is still moving after %.0f s", *name, LNStillTimeout];
            return nil;
        }
    }
    *point = p;
    return h;
}

// -- the commands -----------------------------------------------------------------------------------------

- (void)replaceText:(LNHit *)field at:(CGPoint)point with:(NSString *)text {
    [self touch:point];
#if TARGET_OS_MACCATALYST
    // whatever is there, selected, is replaced by what is typed
    [self event:^{ [self.app typeKey:@"a" modifierFlags:XCUIKeyModifierCommand]; }];
    if (text.length) [self event:^{ [self.app typeText:text]; }];
    else [self event:^{ [self.app typeKey:XCUIKeyboardKeyDelete modifierFlags:XCUIKeyModifierNone]; }];
#else
    NSString *current = [field.node.value isKindOfClass:NSString.class] ? field.node.value : @"";
    if (current.length && ![current isEqualToString:field.node.placeholderValue]) {
        NSMutableString *delete = [NSMutableString string];
        for (NSUInteger i = 0; i < current.length; i++) [delete appendString:XCUIKeyboardKeyDelete];
        [self event:^{ [self.app typeText:delete]; }];
    }
    if (text.length) [self event:^{ [self.app typeText:text]; }];
    // the keyboard closed: the shell's Done bar, else return
    if ([self look]) {
        LNHit *done = [self byIdentifier:@"keyboardDone"];
        CGPoint p;
        if (done && [self hitPointOf:done point:&p]) { [self touch:p]; return; }
        LNHit *keyboard = [self first:^BOOL(LNHit *h) { return h.node.elementType == XCUIElementTypeKeyboard; }];
        LNHit *ret = keyboard ? [self firstIn:keyboard.node matching:^BOOL(LNHit *h) {
            return h.node.elementType == XCUIElementTypeButton && ([LNLabelOf(h.node) isEqualToString:@"return"] || [LNLabelOf(h.node) isEqualToString:@"Return"] || [LNLabelOf(h.node) isEqualToString:@"Done"]); }] : nil;
        if (ret && [self hitPointOf:ret point:&p]) [self touch:p];
    }
#endif
}

- (NSDictionary *)describe:(LNHit *)h {
    NSMutableArray *children = [NSMutableArray array];
    for (LNNode c in h.node.children) {
        if (children.count >= 30) break;
        [children addObject:@{@"type": @(c.elementType), @"id": c.identifier ?: @"", @"label": LNLabelOf(c), @"frame": NSStringFromCGRect(c.frame)}];
    }
    return @{@"ok": @YES, @"exists": @YES, @"type": @(h.node.elementType), @"id": h.node.identifier ?: @"", @"label": LNLabelOf(h.node),
             @"value": [h.node.value isKindOfClass:NSString.class] ? h.node.value : @"", @"frame": NSStringFromCGRect(h.node.frame),
             @"enabled": LNBool(h.node.isEnabled), @"children": children};
}

/// The answer to one command.
- (NSDictionary *)answer:(NSDictionary *)command ended:(BOOL *)ended {
    NSString *op = command[@"op"];
    NSTimeInterval timeout = [command[@"timeout"] respondsToSelector:@selector(doubleValue)] ? [command[@"timeout"] doubleValue] : LNAppearTimeout;
    if ([op isEqualToString:@"end"]) { *ended = YES; return @{@"ok": @YES}; }
    if ([op isEqualToString:@"launch"]) {
        [self.app terminate];
        self.app = [XCUIApplication new];
        if ([command[@"env"] isKindOfClass:NSDictionary.class]) self.app.launchEnvironment = command[@"env"];
        [self.app launch];
        return @{@"ok": @YES};
    }
    if ([op isEqualToString:@"terminate"]) { [self.app terminate]; return @{@"ok": @YES}; }
    if ([op isEqualToString:@"log"]) { NSLog(@"journey: %@", command[@"message"]); return @{@"ok": @YES}; }
    if ([op isEqualToString:@"fail"]) {
        // the screen as the journey failed, beside the failure
        XCTAttachment *screen = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
        screen.name = @"journey failure";
        screen.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:screen];
        XCTFail(@"%@", command[@"message"]);
        return @{@"ok": @YES};
    }
#if !TARGET_OS_MACCATALYST
    if ([op isEqualToString:@"home"]) { [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome]; return @{@"ok": @YES}; }
#endif
    if ([op isEqualToString:@"activate"]) { [self.app activate]; return @{@"ok": @YES}; }
    if ([op isEqualToString:@"shot"]) {
        NSString *dir = [command[@"directory"] isKindOfClass:NSString.class] ? command[@"directory"] : nil;
        LNScreenshots *shots = dir.length ? [LNScreenshots inDirectory:dir] : [LNScreenshots attachmentsOnly];
        __block BOOL written = YES;
        // a PNG that cannot be written is the journey's failure to report, not one recorded here
        XCTExpectFailureWithOptionsInBlock(@"the host reports it", XCTExpectedFailureOptions.nonStrictOptions, ^{
            written = LNShot(self, self.app, command[@"name"], shots);
        });
        return written ? @{@"ok": @YES} : @{@"ok": @NO, @"error": [NSString stringWithFormat:@"screenshot %@ not written to %@", command[@"name"], dir]};
    }
    NSDictionary *find = [command[@"find"] isKindOfClass:NSDictionary.class] ? command[@"find"] : nil;
    if (!find) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: no find", op]};
    NSString *name = nil;
    BOOL known = YES;
    if ([op isEqualToString:@"exists"]) {
        LNHit *h = [self appear:find name:&name known:&known until:[NSDate dateWithTimeIntervalSinceNow:MAX(0, timeout)]];
        if (!known) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: no such element (%@)", op, name]};
        return @{@"ok": @YES, @"exists": LNBool(h != nil)};
    }
    if ([op isEqualToString:@"gone"]) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(0, timeout)];
        while (YES) {
            LNHit *h = [self look] ? [self find:find name:&name known:&known] : nil;
            if (!known) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: no such element (%@)", op, name]};
            if (!h) return @{@"ok": @YES, @"gone": @YES};
            if (deadline.timeIntervalSinceNow <= 0) return @{@"ok": @YES, @"gone": @NO};
            LNSleep(LNPollInterval);
        }
    }
    if ([op isEqualToString:@"text"]) {
        LNHit *h = [self appear:find name:&name known:&known until:[NSDate dateWithTimeIntervalSinceNow:MAX(0, timeout)]];
        if (!known) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: no such element (%@)", op, name]};
        if (!h) return [self refuse:[NSString stringWithFormat:@"%@ does not appear within %.0f s", name, timeout]];
        return @{@"ok": @YES, @"text": LNTextOf(h.node)};
    }
    if ([op isEqualToString:@"state"]) {
        LNHit *h = [self look] ? [self find:find name:&name known:&known] : nil;
        if (!known) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: no such element (%@)", op, name]};
        CGPoint p;
        BOOL hittable = h && [self hitPointOf:h point:&p] && ![self coverOf:h at:p];
        return @{@"ok": @YES, @"exists": LNBool(h != nil), @"enabled": LNBool(h && h.node.isEnabled), @"hittable": LNBool(hittable)};
    }
    if ([op isEqualToString:@"describe"]) {
        LNHit *h = [self look] ? [self find:find name:&name known:&known] : nil;
        if (!known) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: no such element (%@)", op, name]};
        if (!h) return @{@"ok": @YES, @"exists": @NO, @"onScreen": [self onScreen]};
        return [self describe:h];
    }
    if ([op isEqualToString:@"scroll"]) {
        LNHit *h = [self intoView:find name:&name until:[NSDate dateWithTimeIntervalSinceNow:LNAppearTimeout]];
        CGPoint p;
        return @{@"ok": @YES, @"hittable": LNBool(h && [self hitPointOf:h point:&p] && ![self coverOf:h at:p])};
    }
    if ([op isEqualToString:@"tap"] || [op isEqualToString:@"press"] || [op isEqualToString:@"type"]) {
        NSString *why = nil;
        CGPoint p;
        LNHit *h = [self ready:find name:&name point:&p why:&why];
        if (!h) return [self refuse:why];
        if ([op isEqualToString:@"type"]) {
            NSString *text = [command[@"text"] isKindOfClass:NSString.class] ? command[@"text"] : @"";
            [self replaceText:h at:p with:text];
            return @{@"ok": @YES};
        }
        if ([op isEqualToString:@"press"]) {
            // held down for `seconds` (a stepper's autorepeat, which speeds up as the hold goes on: one hold, not
            // several short ones, which would each start at the slow rate)
            NSTimeInterval seconds = [command[@"seconds"] respondsToSelector:@selector(doubleValue)] ? [command[@"seconds"] doubleValue] : 1;
            NSLog(@"journey press: %@ at (%.0f, %.0f) for %.1f s, frame %@", name, p.x, p.y, seconds, NSStringFromCGRect(h.node.frame));
            XCUICoordinate *c = [self coordinateAt:p];
#if TARGET_OS_MACCATALYST
            [self event:^{ [c clickForDuration:seconds thenDragToCoordinate:c]; }];
#else
            [self event:^{ [c pressForDuration:seconds]; }];
#endif
            return @{@"ok": @YES};
        }
        NSLog(@"journey tap: %@ at (%.0f, %.0f), frame %@", name, p.x, p.y, NSStringFromCGRect(h.node.frame));
        [self touch:p];
        // `times`: the checks once, then plain taps where the element now is (a stepper's many steps)
        NSInteger times = [command[@"times"] respondsToSelector:@selector(integerValue)] ? [command[@"times"] integerValue] : 1;
        for (NSInteger i = 1; i < times; i++) {
            if ([self look]) {
                LNHit *again = [self find:find name:&name known:&known];
                CGPoint q;
                if (again && [self hitPointOf:again point:&q]) p = q;
            }
            [self touch:p];
        }
        return @{@"ok": @YES};
    }
    return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"unknown command %@", op]};
}

- (void)testDrive {
    NSString *port = NSProcessInfo.processInfo.environment[@"LEANNATIVE_DRIVER_PORT"];
    if (!port.length) {
        XCTSkip(@"no journey host (LEANNATIVE_DRIVER_PORT): this app's journeys run through framework/native/ci/ui-tests");
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in host = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port.integerValue)};
    host.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (fd < 0 || connect(fd, (struct sockaddr *)&host, sizeof host) != 0) {
        XCTFail(@"cannot reach the journey host on 127.0.0.1:%@ (errno %d)", port, errno);
        if (fd >= 0) close(fd);
        return;
    }
    FILE *in = fdopen(dup(fd), "r");
    char *line = NULL;
    size_t capacity = 0;
    BOOL ended = NO;
    while (!ended && getline(&line, &capacity, in) > 0) {
        NSData *data = [NSData dataWithBytes:line length:strlen(line)];
        NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *answer;
        NSUInteger before = self.snapshots;
        @try {
            answer = [command isKindOfClass:NSDictionary.class] ? [self answer:command ended:&ended]
                                                                 : @{@"ok": @NO, @"error": @"not a JSON object"};
        } @catch (NSException *exception) {
            answer = @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]};
        }
        // how many looks the command took, for the host's timing
        NSMutableDictionary *full = [answer mutableCopy];
        full[@"snapshots"] = @(self.snapshots - before);
        NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:full options:0 error:nil] mutableCopy];
        [out appendBytes:"\n" length:1];
        for (NSUInteger sent = 0; sent < out.length;) {
            ssize_t n = send(fd, (const char *)out.bytes + sent, out.length - sent, 0);
            if (n <= 0) { ended = YES; break; }
            sent += (NSUInteger)n;
        }
    }
    free(line);
    fclose(in);
    close(fd);
    XCTAssertTrue(ended, @"the journey host closed the connection without `end`");
}

@end
