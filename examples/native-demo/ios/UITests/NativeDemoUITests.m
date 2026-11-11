// native-demo's UI tests: the framework's XCTest kit (framework/native/testkit) against real LeanNative-rendered
// controls. Run them with the framework's runner (a throwaway simulator, a recording, device.json):
//
//   APP_DIR=examples/native-demo APP_ROOT=NativeDemo SCHEME=NativeDemo framework/native/ci/ui-tests
//
// The screenshots also go to $SCREENSHOTS when the runner passes it (UI_BEFORE writes SCREENSHOTS=… to
// test-env); otherwise to a temporary directory, so writing them is always tested.
#import <XCTest/XCTest.h>
#import "LNTest.h"

@interface NativeDemoUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
/// Set by a test that must run to its last line (one with expected failures: an expected failure would
/// stop it early if it did not continue after failures); `tearDown` fails it if it did not get there.
@property (nonatomic) BOOL mustFinish;
@property (nonatomic) BOOL finished;
@end

@implementation NativeDemoUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    LNAppearTimeout = 20;
    LNEnabledTimeout = 15;
    self.app = [XCUIApplication new];
    [self.app launch];
}

- (void)tearDown {
    if (self.mustFinish) XCTAssertTrue(self.finished, @"the test did not run to its end");
}

/// A tab by its title: a tab bar button on iOS, the sidebar's item under Mac Catalyst.
- (BOOL)openTab:(NSString *)title {
    NSPredicate *named = [NSPredicate predicateWithFormat:@"label == %@ AND (elementType == %d OR elementType == %d)",
                          title, XCUIElementTypeButton, XCUIElementTypeCell];
    XCUIElement *tab = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:named].firstMatch;
    if (![tab waitForExistenceWithTimeout:LNAppearTimeout]) { LNFail(@__FILE__, __LINE__, [title stringByAppendingString:@" tab missing"]); return NO; }
#if TARGET_OS_MACCATALYST
    [tab click];
#else
    [tab tap];
#endif
    return YES;
}

- (void)testTapCountsInLean {
    if (!LNWait(self.app, @"count")) return;
    XCTAssertEqualObjects(LNText(LNElement(self.app, @"count")), @"Count: 0");
    if (!LNTap(self.app, @"inc") || !LNTap(self.app, @"inc")) return;
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(LNElement(self.app, @"count")) isEqualToString:@"Count: 2"]; }),
                  @"the count is %@", LNText(LNElement(self.app, @"count")));
}

- (void)testTypingReplacesText {
    if (!LNType(self.app, @"name", @"Ada")) return;
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(LNElement(self.app, @"greeting")) isEqualToString:@"Hello, Ada"]; }),
                  @"greeting: %@", LNText(LNElement(self.app, @"greeting")));
    // a second LNType replaces, it does not append
    if (!LNType(self.app, @"name", @"Grace Hopper")) return;
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(LNElement(self.app, @"greeting")) isEqualToString:@"Hello, Grace Hopper"]; }),
                  @"greeting: %@", LNText(LNElement(self.app, @"greeting")));
    // and an empty replacement clears it
    if (!LNType(self.app, @"name", @"")) return;
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(LNElement(self.app, @"greeting")) isEqualToString:@"Nobody yet"]; }),
                  @"greeting: %@", LNText(LNElement(self.app, @"greeting")));
}

- (void)testDisabledControl {
    // `Start` has an action until the ticker runs; then the view gives it none and the shell disables it
    if (!LNTap(self.app, @"startTicks")) return;
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return !LNElement(self.app, @"startTicks").isEnabled; }), @"Start stays enabled");
    XCTAssertTrue(LNExpectDisabled(self.app, @"startTicks"));
}

- (void)testFailedPreconditionsStopTheAction {
    // expected failures are failures: without this the first would end the test
    self.continueAfterFailure = YES;
    self.mustFinish = YES;
    LNAppearTimeout = 1; LNEnabledTimeout = 1;
    // a missing control: a failure, NO, and nothing tapped
    __block BOOL tapped = YES;
    XCTExpectFailureInBlock(@"there is no such control", ^{ tapped = LNTap(self.app, @"noSuchControl"); });
    XCTAssertFalse(tapped);
    __block BOOL typed = YES;
    XCTExpectFailureInBlock(@"there is no such field", ^{ typed = LNType(self.app, @"noSuchField", @"x"); });
    XCTAssertFalse(typed);
    XCTAssertTrue(LNExpectMissing(self.app, @"noSuchControl", 1));
    // a disabled control: a failure, NO, and the tap does not happen (the count would not change anyway, so
    // check the kit's answer and that the control is still the disabled one)
    if (!LNTap(self.app, @"startTicks")) return;
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return !LNElement(self.app, @"startTicks").isEnabled; }));
    XCTExpectFailureInBlock(@"Start is disabled while ticking", ^{ tapped = LNTap(self.app, @"startTicks"); });
    XCTAssertFalse(tapped);
    // expecting an enabled control to be disabled is a failure too
    __block BOOL disabled = YES;
    XCTExpectFailureInBlock(@"+1 is enabled", ^{ disabled = LNExpectDisabled(self.app, @"inc"); });
    XCTAssertFalse(disabled);
    // the count never moved: no failed action tapped something else
    XCTAssertEqualObjects(LNText(LNElement(self.app, @"count")), @"Count: 0");
    self.finished = YES;
}

// Not on a Mac: a row is swiped there with two fingers on a trackpad, which XCTest does not have. Left out and
// not skipped: the evidence of a run counts a skipped test as one that did not pass.
#if !TARGET_OS_MACCATALYST
- (void)testSwipingARowDoesItsAction {
    if (![self openTab:@"Widgets"]) return;
    XCUIElement *row = LNElement(self.app, @"swipeRow"), *value = LNElement(self.app, @"swipedValue");
    XCTAssertTrue(LNScrollTo(self.app, row), @"the swipe row cannot be scrolled into view");
    XCTAssertEqualObjects(LNText(value), @"Nothing yet");
    // a swipe action is not drawn in its row
    XCTAssertFalse(LNElement(self.app, @"swipe-archive").exists, @"the Archive button is drawn in the row");
    XCTAssertFalse(LNElement(self.app, @"swipe-flag").exists, @"the Flag button is drawn in the row");
    // from the trailing edge: Archive and Delete, and not the disabled one
    NSString *why = LNSwipeAction(self.app, row, @"the swipe row", YES, @"Delete");
    XCTAssertNil(why, @"%@", why);
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(value) isEqualToString:@"Deleted"]; }), @"after Delete: %@", LNText(value));
    XCTAssertFalse(self.app.buttons[@"Never"].exists, @"a disabled button is offered as a swipe action");
    why = LNSwipeAction(self.app, row, @"the swipe row", YES, @"Archive");
    XCTAssertNil(why, @"%@", why);
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(value) isEqualToString:@"Archived"]; }), @"after Archive: %@", LNText(value));
    // and from the leading edge
    why = LNSwipeAction(self.app, row, @"the swipe row", NO, @"Flag");
    XCTAssertNil(why, @"%@", why);
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(value) isEqualToString:@"Flagged"]; }), @"after Flag: %@", LNText(value));
}
#endif

/// A row's context menu (`decor.menu`): a long press on a phone, a right click on a Mac. Its items are the row's
/// buttons, which are not drawn in the row; a disabled one is there and greyed.
- (void)testARowsMenuDoesItsActions {
    if (![self openTab:@"Widgets"]) return;
    XCUIElement *row = LNElement(self.app, @"swipeRow"), *value = LNElement(self.app, @"swipedValue");
    XCTAssertTrue(LNScrollTo(self.app, row), @"the row cannot be scrolled into view");
    XCTAssertEqualObjects(LNText(value), @"Nothing yet");
    // a menu's item is not drawn in its row
    XCTAssertFalse(LNElement(self.app, @"menu-unread").exists, @"Mark unread is drawn in the row");
    NSString *why = LNOpenMenu(self.app, row, @"the row", @"Mark unread");
    XCTAssertNil(why, @"%@", why);
    if (why) return;
    // the swipe actions that are in the menu too, the one that is only a swipe action not, and the disabled one greyed
    XCTAssertTrue(LNMenuItem(self.app, @"Archive").exists && LNMenuItem(self.app, @"Delete").exists, @"the menu lacks Archive or Delete");
    XCTAssertFalse(LNMenuItem(self.app, @"Flag").exists, @"a swipe action that is no menu item is in the menu");
    XCTAssertTrue(LNMenuItem(self.app, @"Locked").exists, @"the disabled item is not in the menu");
    XCTAssertFalse(LNMenuItem(self.app, @"Locked").enabled, @"the disabled item is enabled");
#if TARGET_OS_MACCATALYST
    [LNMenuItem(self.app, @"Mark unread") click];
#else
    [LNMenuItem(self.app, @"Mark unread") tap];
#endif
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(value) isEqualToString:@"Marked unread"]; }), @"after Mark unread: %@", LNText(value));
    why = LNMenuAction(self.app, row, @"the row", @"Delete");
    XCTAssertNil(why, @"%@", why);
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(value) isEqualToString:@"Deleted"]; }), @"after Delete: %@", LNText(value));
}

/// Keys (`decor.key`): a button's key is its click, in the page or in a bar, an input's puts the cursor in it
/// (here cmd-F, the system's Find), and cmd-[ goes back from a screen.
- (void)testKeysDoWhatTheirNodesDo {
    if (!LNWait(self.app, @"inc")) return;
    XCUIElement *count = LNElement(self.app, @"count");
    LNPressKey(self.app, @"k", XCUIKeyModifierCommand);
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(count) isEqualToString:@"Count: 1"]; }), @"after cmd-K: %@", LNText(count));
    // the field has the cursor: what is typed next is its text
    LNPressKey(self.app, @"f", XCUIKeyModifierCommand);
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [[LNElement(self.app, @"name") valueForKey:@"hasKeyboardFocus"] boolValue]; }),
                  @"cmd-F did not put the cursor in the field");
    [self.app typeText:@"Ada"];
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(LNElement(self.app, @"greeting")) isEqualToString:@"Hello, Ada"]; }),
                  @"typed after cmd-F: %@", LNText(LNElement(self.app, @"greeting")));
    // a key with command is a key while a field is being typed in, and pressed once it counts once
    LNPressKey(self.app, @"k", XCUIKeyModifierCommand);
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(count) isEqualToString:@"Count: 2"]; }), @"after cmd-K in the field: %@", LNText(count));
    XCTAssertFalse(LNPoll(1, 0.1, ^BOOL{ return ![LNText(count) isEqualToString:@"Count: 2"]; }), @"one press counted twice: %@", LNText(count));
    // in the columns: a bar's button has its key, and cmd-[ is the screen's back
    if (!LNTap(self.app, @"openColumns") || !LNWait(self.app, @"box-1")) return;
    BOOL wide = LNAppears(LNElement(self.app, @"columnItem"), 2);
    if (!LNTap(self.app, @"box-1") || !LNWait(self.app, @"item-2")) return;
    if (!LNTap(self.app, @"item-2") || !LNWait(self.app, @"columnItem")) return;
    LNPressKey(self.app, @"k", XCUIKeyModifierCommand);
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(LNElement(self.app, @"columnCount")) isEqualToString:@"Count: 3"]; }),
                  @"after cmd-K in the column: %@", LNText(LNElement(self.app, @"columnCount")));
    if (!wide) {
        LNPressKey(self.app, @"[", XCUIKeyModifierCommand);
        XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return !LNElement(self.app, @"columnItem").exists; }), @"cmd-[ did not go back from the item");
        if (!LNWait(self.app, @"item-0")) return;
        LNPressKey(self.app, @"[", XCUIKeyModifierCommand);
        XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return !LNElement(self.app, @"item-0").exists; }), @"cmd-[ did not go back from the list");
    }
    if (!LNTap(self.app, @"closeColumns") || !LNWait(self.app, @"count")) return;
    XCTAssertEqualObjects(LNText(count), @"Count: 3");
}

/// The columns (`Html.split`): side by side in a wide window (a Mac, an iPad), one at a time in a narrow one (a
/// phone), where a choice shows the next column and going back from one is its screen's own `onBack`.
- (void)testColumnsSideBySideOrOneAtATime {
    if (!LNTap(self.app, @"openColumns") || !LNWait(self.app, @"box-1")) return;
    // a wide window has the sidebar, the list and the item at once; a narrow one has the sidebar alone
    BOOL wide = LNAppears(LNElement(self.app, @"columnItem"), 2);
    if (!wide) XCTAssertFalse(LNElement(self.app, @"item-0").exists, @"a narrow window shows the list beside the sidebar");
    if (!LNTap(self.app, @"box-1") || !LNWait(self.app, @"item-2")) return;
    if (!LNTap(self.app, @"item-2") || !LNWait(self.app, @"columnItem")) return;
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(LNElement(self.app, @"columnItem")) isEqualToString:@"Archive item 3"]; }),
                  @"the item's column: %@", LNText(LNElement(self.app, @"columnItem")));
    // a button in a column's bar is that screen's
    if (!LNTap(self.app, @"columnInc")) return;
    XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return [LNText(LNElement(self.app, @"columnCount")) isEqualToString:@"Count: 1"]; }),
                  @"the count in the column: %@", LNText(LNElement(self.app, @"columnCount")));
    if (wide) {
        XCTAssertTrue(LNElement(self.app, @"box-1").exists && LNElement(self.app, @"item-0").exists, @"a wide window lost a column");
        // the chosen rows read as selected
        XCTAssertTrue(LNElement(self.app, @"box-1").selected, @"the chosen box is not selected");
        XCTAssertFalse(LNElement(self.app, @"box-0").selected, @"the other box is selected");
        XCTAssertTrue(LNElement(self.app, @"item-2").selected, @"the chosen item is not selected");
    } else {
        // back from the item is the list, and back from the list is the sidebar
        XCTAssertNil(LNTapElement(self.app, self.app.navigationBars.buttons.firstMatch, @"Back (from the item)"));
        if (!LNWait(self.app, @"item-0")) return;
        XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return !LNElement(self.app, @"columnItem").exists; }), @"the item is still up after going back");
        XCTAssertNil(LNTapElement(self.app, self.app.navigationBars.buttons.firstMatch, @"Back (from the list)"));
        if (!LNWait(self.app, @"box-0")) return;
        XCTAssertTrue(LNPoll(5, 0.1, ^BOOL{ return !LNElement(self.app, @"item-0").exists; }), @"the list is still up after going back");
    }
    // and the tabs again, with what the column's button counted
    if (!LNTap(self.app, @"closeColumns") || !LNWait(self.app, @"count")) return;
    XCTAssertEqualObjects(LNText(LNElement(self.app, @"count")), @"Count: 1");
}

- (void)testScrollingToTheLastProbe {
    if (![self openTab:@"Probes"]) return;
    // the last capability button (16 probes: probe-15) is below the fold on a phone: LNTap scrolls to it first
    if (!LNTap(self.app, @"probe-15")) return;
    NSPredicate *asked = [NSPredicate predicateWithFormat:@"label BEGINSWITH 'asking: HTTP bad proxy' OR label BEGINSWITH 'HTTP bad proxy:'"];
    XCUIElement *logged = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:asked].firstMatch;
    XCTAssertTrue([logged waitForExistenceWithTimeout:10], @"the probe's answer is not logged");
}

- (void)testScrollingToTheEndOfTheLog {
    // the Probes list made longer than any window (16 probes, then 10 log rows), its oldest row looked for from
    // the top: LNScrollTo drags on iOS and turns the scroll wheel under Mac Catalyst. That row starts out of
    // view, so this always scrolls; then back up to the first probe.
    if (![self openTab:@"Probes"]) return;
    if (!LNTap(self.app, @"probe-15")) return;
    for (int i = 0; i < 4; i++) if (!LNTap(self.app, @"probe-0")) return;
    NSPredicate *oldest = [NSPredicate predicateWithFormat:@"label BEGINSWITH 'asking: HTTP bad proxy'"];
    XCUIElement *row = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:oldest].firstMatch;
    XCTAssertFalse(row.exists && row.hittable, @"the oldest log row is in view before scrolling: nothing to scroll");
    XCTAssertTrue(LNScrollTo(self.app, row), @"the oldest log row was not scrolled into view");
    XCUIElement *first = LNElement(self.app, @"probe-0");
    NSLog(@"after scrolling down, probe-0 is %@", first.exists && first.hittable ? @"still in view" : @"out of view");
    XCTAssertTrue(LNScrollTo(self.app, first), @"the first probe was not scrolled back into view");
}

/// The selftest (`NATIVEDEMO_SELFTEST=1`): BackgroundRun, an EffectScope drain and the typed clients, run by the
/// real shell on this platform, its lines shown on the Demo tab. Each line is logged, so the run's
/// xcodebuild.log keeps what this platform answered.
- (void)testSelftestThroughTheShell {
    [self.app terminate];
    self.app.launchEnvironment = @{@"NATIVEDEMO_SELFTEST": @"1"};
    [self.app launch];
    if (!LNWait(self.app, @"selftest-0")) return;
    // its lines are selftest-0, selftest-1, …; the last is "done"
    NSArray<NSString *> *(^lines)(void) = ^{
        NSMutableArray<NSString *> *all = [NSMutableArray array];
        for (NSUInteger i = 0; LNElement(self.app, [NSString stringWithFormat:@"selftest-%lu", (unsigned long)i]).exists; i++)
            [all addObject:LNText(LNElement(self.app, [NSString stringWithFormat:@"selftest-%lu", (unsigned long)i]))];
        return all;
    };
    XCTAssertTrue(LNPoll(90, 1, ^BOOL{ return [lines().lastObject isEqualToString:@"done"]; }), @"the selftest did not finish: %@", lines());
    NSMutableDictionary<NSString *, NSString *> *said = [NSMutableDictionary dictionary];
    for (NSString *line in lines()) {
        NSLog(@"selftest: %@", line);
        NSRange colon = [line rangeOfString:@": "];
        if (colon.location != NSNotFound) said[[line substringToIndex:colon.location]] = [line substringFromIndex:NSMaxRange(colon)];
    }
    XCTAssertEqualObjects(said[@"TCP echo"], @"echo: selftest");
    // BackgroundRun: one run completes, one that never stops is expired at its deadline
    XCTAssertEqualObjects(said[@"background run"], @"completed, work started, success true");
    XCTAssertEqualObjects(said[@"background run past its deadline"], @"expired, work started, success false");
    // EffectScope: the invalidation cancelled and drained the task, and its late result was not delivered
    XCTAssertEqualObjects(said[@"effect scope"], @"started, drained true, late result delivered false, now 0 tasks");
    // the device's time zone, asked of the shell
    XCTAssertEqualObjects(said[@"timezone"], @"an identifier and an offset");
    // and what kind of machine this is
    XCTAssertEqualObjects(said[@"device"], @"an idiom");
    // the typed clients: every answer decoded (ok, or a classified error; never malformed)
    NSRegularExpression *decoded = [NSRegularExpression regularExpressionWithPattern:@"^(ok|denied|cancelled|unsupported|failed)( .*)?$" options:0 error:nil];
    for (NSString *key in said) {
        if (![key hasPrefix:@"typed "]) continue;
        NSString *answer = said[key];
        XCTAssertNotNil([decoded firstMatchInString:answer options:0 range:NSMakeRange(0, answer.length)], @"%@: %@", key, answer);
    }
    XCTAssertEqualObjects(said[@"typed http.get ftp"], @"failed bad-url");
    XCTAssertTrue([said[@"typed http.get unreachable"] hasPrefix:@"failed system"], @"unreachable: %@", said[@"typed http.get unreachable"]);
    // an ad-hoc build has no iCloud entitlement
    XCTAssertEqualObjects(said[@"typed cloudkit.account"], @"unsupported missingEntitlement");
    // the Keychain: an iOS app (the simulator's ad-hoc signature included) and a team-signed Mac app have an
    // access group; an ad-hoc Mac app has none, and the data protection keychain refuses it
    // (errSecMissingEntitlement). A team-signed Mac run says so: NATIVEDEMO_KEYCHAIN=access-group in the
    // tests' environment (TEST_RUNNER_NATIVEDEMO_KEYCHAIN for xcodebuild; framework/native/README.md).
    BOOL accessGroup = !TARGET_OS_MACCATALYST
        || [NSProcessInfo.processInfo.environment[@"NATIVEDEMO_KEYCHAIN"] isEqualToString:@"access-group"];
    NSLog(@"keychain: %@", accessGroup ? @"an access group" : @"none (ad-hoc Mac app)");
    if (accessGroup) {
        XCTAssertEqualObjects(said[@"typed keychain.add"], @"ok added");
        XCTAssertEqualObjects(said[@"typed keychain.add again"], @"ok alreadyExists");
        XCTAssertEqualObjects(said[@"typed keychain.get"], @"ok 010203");
        XCTAssertTrue([said[@"typed keychain.delete"] hasPrefix:@"ok"], @"delete: %@", said[@"typed keychain.delete"]);
        XCTAssertEqualObjects(said[@"typed keychain.get after delete"], @"ok none");
    } else {
        XCTAssertEqualObjects(said[@"typed keychain.add"], @"unsupported status -34018 (-34018)");
    }
}

#if !TARGET_OS_MACCATALYST
// Not under Mac Catalyst: there the passcode is the Mac's password, asked by a system sheet of another
// process that going to the background does not dismiss, and a CI Mac has no Touch ID.
- (void)testScopedAuthenticationEndsWithTheSession {
    // Face ID or the passcode runs in the session's EffectScope. The system's sheet is another process's;
    // going to the background dismisses it and ends the session. Whichever comes first, the answer is the
    // system's dismissal delivered while the session lived (a cancellation, or on some simulators an error the
    // shell names `unknown`: CI's iOS 26.5 gave one; the log keeps its code and domain), or a stale answer
    // dropped: never a success, and never reported as the person's denial.
    if (!LNTap(self.app, @"faceID")) return;
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
    [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
    [self.app activate];
    NSPredicate *ended = [NSPredicate predicateWithFormat:
        @"label BEGINSWITH 'not authenticated: cancelled' OR label BEGINSWITH 'not authenticated: failed' OR label BEGINSWITH 'dropped a stale answer'"];
    XCUIElement *logged = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:ended].firstMatch;
    XCTAssertTrue([logged waitForExistenceWithTimeout:15], @"neither the dismissal nor a dropped answer was logged");
    NSPredicate *wrong = [NSPredicate predicateWithFormat:@"label BEGINSWITH 'authenticated' OR label BEGINSWITH 'not authenticated: denied'"];
    XCTAssertFalse([[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:wrong].firstMatch.exists);
    NSLog(@"scoped authentication ended as: %@", LNText(logged));
}
#endif

- (void)testScreenshots {
    self.continueAfterFailure = YES;
    self.mustFinish = YES;
    NSString *dir = NSProcessInfo.processInfo.environment[@"SCREENSHOTS"];
    if (!dir.length) dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    LNScreenshots *shots = [LNScreenshots inDirectory:dir];
    if (!LNWait(self.app, @"count")) return;
    XCTAssertTrue(LNShot(self, self.app, @"demo", shots));
    if (![self openTab:@"Widgets"]) return;
    XCTAssertTrue(LNShot(self, self.app, @"widgets", shots));
    for (NSString *name in @[@"demo", @"widgets"]) {
        NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
        NSData *png = [NSData dataWithContentsOfFile:path];
        XCTAssertTrue(png.length > 8 && memcmp(png.bytes, "\x89PNG", 4) == 0, @"%@ is not a PNG", path);
    }
    // attachments only: nothing written
    XCTAssertTrue(LNShot(self, self.app, @"attached-only", [LNScreenshots attachmentsOnly]));
    // a directory that cannot be made is a failure, not a silent loss
    __block BOOL written = YES;
    XCTExpectFailureInBlock(@"a file is in the way", ^{
        NSString *blocked = [dir stringByAppendingPathComponent:@"demo.png/below"];
        written = LNShot(self, self.app, @"blocked", [LNScreenshots inDirectory:blocked]);
    });
    XCTAssertFalse(written);
    self.finished = YES;
}

@end
