// native-demo's UI tests: the framework's XCTest kit (framework/native/testkit) against real ElmLean-rendered
// controls. Run them with the framework's runner (a throwaway simulator, a recording, device.json):
//
//   APP_DIR=examples/native-demo APP_ROOT=NativeDemo SCHEME=NativeDemo framework/native/ci/ui-tests
//
// The screenshots also go to $SCREENSHOTS when the runner passes it (UI_BEFORE writes SCREENSHOTS=… to
// test-env); otherwise to a temporary directory, so writing them is always tested.
#import <XCTest/XCTest.h>
#import "ELTest.h"

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
    ELAppearTimeout = 20;
    ELEnabledTimeout = 15;
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
    if (![tab waitForExistenceWithTimeout:ELAppearTimeout]) { ELFail(@__FILE__, __LINE__, [title stringByAppendingString:@" tab missing"]); return NO; }
#if TARGET_OS_MACCATALYST
    [tab click];
#else
    [tab tap];
#endif
    return YES;
}

- (void)testTapCountsInLean {
    if (!ELWait(self.app, @"count")) return;
    XCTAssertEqualObjects(ELText(ELElement(self.app, @"count")), @"Count: 0");
    if (!ELTap(self.app, @"inc") || !ELTap(self.app, @"inc")) return;
    XCTAssertTrue(ELPoll(5, 0.1, ^BOOL{ return [ELText(ELElement(self.app, @"count")) isEqualToString:@"Count: 2"]; }),
                  @"the count is %@", ELText(ELElement(self.app, @"count")));
}

- (void)testTypingReplacesText {
    if (!ELType(self.app, @"name", @"Ada")) return;
    XCTAssertTrue(ELPoll(5, 0.1, ^BOOL{ return [ELText(ELElement(self.app, @"greeting")) isEqualToString:@"Hello, Ada"]; }),
                  @"greeting: %@", ELText(ELElement(self.app, @"greeting")));
    // a second ELType replaces, it does not append
    if (!ELType(self.app, @"name", @"Grace Hopper")) return;
    XCTAssertTrue(ELPoll(5, 0.1, ^BOOL{ return [ELText(ELElement(self.app, @"greeting")) isEqualToString:@"Hello, Grace Hopper"]; }),
                  @"greeting: %@", ELText(ELElement(self.app, @"greeting")));
    // and an empty replacement clears it
    if (!ELType(self.app, @"name", @"")) return;
    XCTAssertTrue(ELPoll(5, 0.1, ^BOOL{ return [ELText(ELElement(self.app, @"greeting")) isEqualToString:@"Nobody yet"]; }),
                  @"greeting: %@", ELText(ELElement(self.app, @"greeting")));
}

- (void)testDisabledControl {
    // `Start` has an action until the ticker runs; then the view gives it none and the shell disables it
    if (!ELTap(self.app, @"startTicks")) return;
    XCTAssertTrue(ELPoll(5, 0.1, ^BOOL{ return !ELElement(self.app, @"startTicks").isEnabled; }), @"Start stays enabled");
    XCTAssertTrue(ELExpectDisabled(self.app, @"startTicks"));
}

- (void)testFailedPreconditionsStopTheAction {
    // expected failures are failures: without this the first would end the test
    self.continueAfterFailure = YES;
    self.mustFinish = YES;
    ELAppearTimeout = 1; ELEnabledTimeout = 1;
    // a missing control: a failure, NO, and nothing tapped
    __block BOOL tapped = YES;
    XCTExpectFailureInBlock(@"there is no such control", ^{ tapped = ELTap(self.app, @"noSuchControl"); });
    XCTAssertFalse(tapped);
    __block BOOL typed = YES;
    XCTExpectFailureInBlock(@"there is no such field", ^{ typed = ELType(self.app, @"noSuchField", @"x"); });
    XCTAssertFalse(typed);
    XCTAssertTrue(ELExpectMissing(self.app, @"noSuchControl", 1));
    // a disabled control: a failure, NO, and the tap does not happen (the count would not change anyway, so
    // check the kit's answer and that the control is still the disabled one)
    if (!ELTap(self.app, @"startTicks")) return;
    XCTAssertTrue(ELPoll(5, 0.1, ^BOOL{ return !ELElement(self.app, @"startTicks").isEnabled; }));
    XCTExpectFailureInBlock(@"Start is disabled while ticking", ^{ tapped = ELTap(self.app, @"startTicks"); });
    XCTAssertFalse(tapped);
    // expecting an enabled control to be disabled is a failure too
    __block BOOL disabled = YES;
    XCTExpectFailureInBlock(@"+1 is enabled", ^{ disabled = ELExpectDisabled(self.app, @"inc"); });
    XCTAssertFalse(disabled);
    // the count never moved: no failed action tapped something else
    XCTAssertEqualObjects(ELText(ELElement(self.app, @"count")), @"Count: 0");
    self.finished = YES;
}

- (void)testScrollingToTheLastProbe {
    if (![self openTab:@"Probes"]) return;
    // the last capability button (13 probes: probe-12) is below the fold on a phone: ELTap scrolls to it first
    if (!ELTap(self.app, @"probe-12")) return;
    NSPredicate *asked = [NSPredicate predicateWithFormat:@"label BEGINSWITH 'asking: HTTP bad proxy' OR label BEGINSWITH 'HTTP bad proxy:'"];
    XCUIElement *logged = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:asked].firstMatch;
    XCTAssertTrue([logged waitForExistenceWithTimeout:10], @"the probe's answer is not logged");
}

- (void)testScrollingToTheEndOfTheLog {
    // the Probes list made longer than any window (13 probes, then 10 log rows), its oldest row looked for from
    // the top: ELScrollTo drags on iOS and turns the scroll wheel under Mac Catalyst. That row starts out of
    // view, so this always scrolls; then back up to the first probe.
    if (![self openTab:@"Probes"]) return;
    if (!ELTap(self.app, @"probe-12")) return;
    for (int i = 0; i < 4; i++) if (!ELTap(self.app, @"probe-0")) return;
    NSPredicate *oldest = [NSPredicate predicateWithFormat:@"label BEGINSWITH 'asking: HTTP bad proxy'"];
    XCUIElement *row = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:oldest].firstMatch;
    XCTAssertFalse(row.exists && row.hittable, @"the oldest log row is in view before scrolling: nothing to scroll");
    XCTAssertTrue(ELScrollTo(self.app, row), @"the oldest log row was not scrolled into view");
    XCUIElement *first = ELElement(self.app, @"probe-0");
    NSLog(@"after scrolling down, probe-0 is %@", first.exists && first.hittable ? @"still in view" : @"out of view");
    XCTAssertTrue(ELScrollTo(self.app, first), @"the first probe was not scrolled back into view");
}

/// The selftest (`NATIVEDEMO_SELFTEST=1`): BackgroundRun, an EffectScope drain and the typed clients, run by the
/// real shell on this platform, its lines shown on the Demo tab. Each line is logged, so the run's
/// xcodebuild.log keeps what this platform answered.
- (void)testSelftestThroughTheShell {
    [self.app terminate];
    self.app.launchEnvironment = @{@"NATIVEDEMO_SELFTEST": @"1"};
    [self.app launch];
    if (!ELWait(self.app, @"selftest-0")) return;
    // its lines are selftest-0, selftest-1, …; the last is "done"
    NSArray<NSString *> *(^lines)(void) = ^{
        NSMutableArray<NSString *> *all = [NSMutableArray array];
        for (NSUInteger i = 0; ELElement(self.app, [NSString stringWithFormat:@"selftest-%lu", (unsigned long)i]).exists; i++)
            [all addObject:ELText(ELElement(self.app, [NSString stringWithFormat:@"selftest-%lu", (unsigned long)i]))];
        return all;
    };
    XCTAssertTrue(ELPoll(90, 1, ^BOOL{ return [lines().lastObject isEqualToString:@"done"]; }), @"the selftest did not finish: %@", lines());
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
#if TARGET_OS_MACCATALYST
    // an ad-hoc Mac app has no keychain access group: the data protection keychain refuses it (errSecMissingEntitlement)
    XCTAssertEqualObjects(said[@"typed keychain.add"], @"unsupported status (-34018)");
#else
    XCTAssertEqualObjects(said[@"typed keychain.add"], @"ok added");
    XCTAssertEqualObjects(said[@"typed keychain.add again"], @"ok alreadyExists");
    XCTAssertEqualObjects(said[@"typed keychain.get"], @"ok 010203");
    XCTAssertTrue([said[@"typed keychain.delete"] hasPrefix:@"ok"], @"delete: %@", said[@"typed keychain.delete"]);
    XCTAssertEqualObjects(said[@"typed keychain.get after delete"], @"ok none");
#endif
}

#if !TARGET_OS_MACCATALYST
// Not under Mac Catalyst: there the passcode is the Mac's password, asked by a system sheet of another
// process that going to the background does not dismiss, and a CI Mac has no Touch ID.
- (void)testScopedAuthenticationEndsWithTheSession {
    // Face ID or the passcode runs in the session's EffectScope. The system's sheet is another process's;
    // going to the background dismisses it (a cancellation) and ends the session. Whichever comes first,
    // the answer is a cancellation delivered while the session lived, or a stale answer dropped: never a
    // success, and never reported as the person's denial.
    if (!ELTap(self.app, @"faceID")) return;
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
    [XCUIDevice.sharedDevice pressButton:XCUIDeviceButtonHome];
    [self.app activate];
    NSPredicate *ended = [NSPredicate predicateWithFormat:
        @"label BEGINSWITH 'not authenticated: cancelled' OR label BEGINSWITH 'dropped a stale answer'"];
    XCUIElement *logged = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:ended].firstMatch;
    XCTAssertTrue([logged waitForExistenceWithTimeout:15], @"neither a cancellation nor a dropped answer was logged");
    NSPredicate *wrong = [NSPredicate predicateWithFormat:@"label BEGINSWITH 'authenticated' OR label BEGINSWITH 'not authenticated: denied'"];
    XCTAssertFalse([[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:wrong].firstMatch.exists);
    NSLog(@"scoped authentication ended as: %@", ELText(logged));
}
#endif

- (void)testScreenshots {
    self.continueAfterFailure = YES;
    self.mustFinish = YES;
    NSString *dir = NSProcessInfo.processInfo.environment[@"SCREENSHOTS"];
    if (!dir.length) dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    ELScreenshots *shots = [ELScreenshots inDirectory:dir];
    if (!ELWait(self.app, @"count")) return;
    XCTAssertTrue(ELShot(self, self.app, @"demo", shots));
    if (![self openTab:@"Widgets"]) return;
    XCTAssertTrue(ELShot(self, self.app, @"widgets", shots));
    for (NSString *name in @[@"demo", @"widgets"]) {
        NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]];
        NSData *png = [NSData dataWithContentsOfFile:path];
        XCTAssertTrue(png.length > 8 && memcmp(png.bytes, "\x89PNG", 4) == 0, @"%@ is not a PNG", path);
    }
    // attachments only: nothing written
    XCTAssertTrue(ELShot(self, self.app, @"attached-only", [ELScreenshots attachmentsOnly]));
    // a directory that cannot be made is a failure, not a silent loss
    __block BOOL written = YES;
    XCTExpectFailureInBlock(@"a file is in the way", ^{
        NSString *blocked = [dir stringByAppendingPathComponent:@"demo.png/below"];
        written = ELShot(self, self.app, @"blocked", [ELScreenshots inDirectory:blocked]);
    });
    XCTAssertFalse(written);
    self.finished = YES;
}

@end
