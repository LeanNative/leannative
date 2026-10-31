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
// Commands (`find` is an element, below; `timeout` in seconds):
//   launch {env}           the app, launched again with this environment (any running one is terminated)
//   terminate
//   exists {find, timeout} {"exists": bool}: whether it appears within the timeout (0: now)
//   gone {find, timeout}   {"gone": bool}: whether it is absent, or disappears within the timeout
//   tap {find, times?}     the kit's checks first (appears, scrolled into view, enabled), then a tap (a click on the
//                          Mac); `times` more than 1: then that many taps in all, without checking again
//   type {find, text}      the same checks, then the field's text replaced
//   text {find, timeout}   {"text": …}: its label or value, without zero-width spaces; an error if it never appears
//   state {find}           {"exists", "enabled", "hittable"}, now
//   scroll {find}          {"hittable": bool}: scrolled until it can be tapped
//   shot {name, directory?} a screenshot attached to the test as `name`, and written to <directory>/<name>.png
//   home, activate         (iOS) the Home button; the app brought back
//   log {message}          into the test's log
//   fail {message}         an XCTest failure with the host's message (the journey failed there), and a
//                          screenshot attached ("journey failure")
//   end
//
// An element (`find`): {"id": identifier} (any type), {"tab": title} (a tab bar button; with no tab bar, a
// sidebar's item), {"alert": button label}, {"button": label}, {"nav": title} (a navigation bar), {"back": true}
// (the navigation bar's first button, else a button BackButton or Back) or {"text": regular expression} (an
// element whose label, without zero-width spaces, matches). With "in": identifier, an "id" or "button" is looked
// for only inside that element.
#import <XCTest/XCTest.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#import "LNTest.h"

@interface LNDriver : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@end

static NSString *LNStripped(NSString *text) { return [text stringByReplacingOccurrencesOfString:@"​" withString:@""]; }
/// A JSON boolean: `@(a && b)` and `@(c ? x : y)` box C's int (`1`), which a JSON reader takes for a number.
static NSNumber *LNBool(BOOL b) { return b ? @YES : @NO; }

@implementation LNDriver

- (void)setUp {
    // a failed journey step is the host's to report (`fail`); the next journey still runs
    self.continueAfterFailure = YES;
    self.executionTimeAllowance = 4 * 3600;
    self.app = [XCUIApplication new];
}

- (void)tearDown {
    [self.app terminate];
}

/// The element `find` names, and a name for it in errors; nil for a find this driver does not know.
- (XCUIElement *)element:(NSDictionary *)find name:(NSString **)name {
    XCUIApplication *app = self.app;
    if ([find[@"in"] isKindOfClass:NSString.class]) {
        // inside the element with that identifier: an id, a button or a text there
        XCUIElement *root = LNElement(app, find[@"in"]);
        NSString *what = nil;
        XCUIElement *e = nil;
        if ([find[@"id"] isKindOfClass:NSString.class]) {
            what = find[@"id"];
            e = [[root descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:find[@"id"]].firstMatch;
        } else if ([find[@"button"] isKindOfClass:NSString.class]) {
            what = [NSString stringWithFormat:@"the button %@", find[@"button"]];
            e = root.buttons[find[@"button"]];
        }
        *name = [NSString stringWithFormat:@"%@ in %@", what ?: find, find[@"in"]];
        return e;
    }
    if ([find[@"id"] isKindOfClass:NSString.class]) { *name = find[@"id"]; return LNElement(app, find[@"id"]); }
    if ([find[@"tab"] isKindOfClass:NSString.class]) {
        *name = [NSString stringWithFormat:@"the %@ tab", find[@"tab"]];
        NSPredicate *named = [NSPredicate predicateWithFormat:@"label == %@ AND (elementType == %d OR elementType == %d)",
                              find[@"tab"], XCUIElementTypeButton, XCUIElementTypeCell];
        XCUIElement *anywhere = [[app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:named].firstMatch;
#if TARGET_OS_MACCATALYST
        return anywhere;
#else
        // the tab bar's button (a screen may also have a button with the tab's title, and a screen over the
        // tabs hides the bar for a while); only an app with no tab bar at all (a sidebar, a custom bar) gets
        // the one anywhere
        XCUIElement *bar = [app.tabBars.buttons matchingPredicate:named].firstMatch;
        XCUIElement *anyBar = app.tabBars.firstMatch;
        LNPoll(LNAppearTimeout, 0.25, ^BOOL{ return bar.exists || (anywhere.exists && !anyBar.exists); });
        return bar.exists || anyBar.exists ? bar : anywhere;
#endif
    }
    if ([find[@"alert"] isKindOfClass:NSString.class]) {
        *name = [NSString stringWithFormat:@"the alert's %@", find[@"alert"]];
        return app.alerts.buttons[find[@"alert"]];
    }
    if ([find[@"button"] isKindOfClass:NSString.class]) {
        *name = [NSString stringWithFormat:@"the button %@", find[@"button"]];
        return app.buttons[find[@"button"]];
    }
    if ([find[@"nav"] isKindOfClass:NSString.class]) {
        *name = [NSString stringWithFormat:@"the %@ navigation bar", find[@"nav"]];
        return app.navigationBars[find[@"nav"]];
    }
    if ([find[@"back"] isEqual:@YES]) {
        // the navigation bar's first button; where a layout floats back outside any bar (iOS 27's iPhone Duo,
        // its tabs in a sidebar), the system's back button wherever it is
        *name = @"the back button";
        XCUIElement *bar = app.navigationBars.buttons.firstMatch;
        if (bar.exists) return bar;
        NSPredicate *back = [NSPredicate predicateWithFormat:@"identifier == 'BackButton' OR label == 'Back'"];
        return [app.buttons matchingPredicate:back].firstMatch;
    }
    if ([find[@"text"] isKindOfClass:NSString.class]) {
        *name = [NSString stringWithFormat:@"a text matching %@", find[@"text"]];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:find[@"text"] options:0 error:nil];
        if (!re) return nil;
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(id<XCUIElementAttributes> e, NSDictionary *bindings) {
            NSString *label = LNStripped(e.label ?: @"");
            return [re firstMatchInString:label options:0 range:NSMakeRange(0, label.length)] != nil;
        }];
        return [[app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:p].firstMatch;
    }
    *name = [NSString stringWithFormat:@"%@", find];
    return nil;
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
    NSString *name = nil;
    XCUIElement *e = [command[@"find"] isKindOfClass:NSDictionary.class] ? [self element:command[@"find"] name:&name] : nil;
    if (!e) return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: no such element (%@)", op, name ?: command[@"find"]]};
    if ([op isEqualToString:@"exists"]) return @{@"ok": @YES, @"exists": LNBool(LNAppears(e, timeout))};
    if ([op isEqualToString:@"gone"]) {
        BOOL gone = LNPoll(timeout, 0.25, ^BOOL{ return !e.exists; });
        return @{@"ok": @YES, @"gone": LNBool(gone)};
    }
    if ([op isEqualToString:@"tap"]) {
        NSString *why = LNTapElement(self.app, e, name);
        if (why) return @{@"ok": @NO, @"error": why};
        // `times`: the checks once, then plain taps (a stepper's many steps)
        NSInteger times = [command[@"times"] respondsToSelector:@selector(integerValue)] ? [command[@"times"] integerValue] : 1;
        for (NSInteger i = 1; i < times; i++) {
#if TARGET_OS_MACCATALYST
            [e click];
#else
            [e tap];
#endif
        }
        return @{@"ok": @YES};
    }
    if ([op isEqualToString:@"press"]) {
        // held down for `seconds` (a stepper's autorepeat), with tap's checks first
        NSTimeInterval seconds = [command[@"seconds"] respondsToSelector:@selector(doubleValue)] ? [command[@"seconds"] doubleValue] : 1;
        NSString *why = LNPressElement(self.app, e, name, seconds);
        return why ? @{@"ok": @NO, @"error": why} : @{@"ok": @YES};
    }
    if ([op isEqualToString:@"type"]) {
        NSString *text = [command[@"text"] isKindOfClass:NSString.class] ? command[@"text"] : @"";
        NSString *why = LNTypeElement(self.app, e, name, text);
        return why ? @{@"ok": @NO, @"error": why} : @{@"ok": @YES};
    }
    if ([op isEqualToString:@"text"]) {
        if (!LNAppears(e, timeout))
            return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@ does not appear within %.0f s", name, timeout]};
        return @{@"ok": @YES, @"text": LNText(e)};
    }
    if ([op isEqualToString:@"state"]) {
        BOOL exists = e.exists;
        return @{@"ok": @YES, @"exists": LNBool(exists), @"enabled": LNBool(exists && e.isEnabled), @"hittable": LNBool(exists && e.hittable)};
    }
    if ([op isEqualToString:@"scroll"]) return @{@"ok": @YES, @"hittable": LNBool(LNScrollTo(self.app, e))};
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
        @try {
            answer = [command isKindOfClass:NSDictionary.class] ? [self answer:command ended:&ended]
                                                                 : @{@"ok": @NO, @"error": @"not a JSON object"};
        } @catch (NSException *exception) {
            answer = @{@"ok": @NO, @"error": [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]};
        }
        NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:answer options:0 error:nil] mutableCopy];
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
