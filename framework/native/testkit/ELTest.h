// ELTest: XCUITest helpers for any ElmLean native app (test-only Objective-C; never part of an app target).
//
// Add this directory to the app's UI-test target only (project.yml: `sources: [UITests, <framework>/native/testkit]`
// on the `bundle.ui-testing` target). Nothing here knows the app: elements are found by the accessibility
// identifiers the app gives its nodes (`Html.identified`), and screenshots go where the test says.
//
// Every action checks its preconditions first (the element appears, can be brought into view, is enabled)
// and, when one fails, records an XCTest failure at the caller's line and returns NO without acting: no
// tap or keystroke lands on whatever else is on screen. A test that cannot go on checks the result:
//
//     if (!ELTap(app, @"send")) return;
//
// Platforms. Under Mac Catalyst a "tap" is a click and scrolling is the scroll wheel (there is no touch
// screen to drag); on iOS (device or simulator) scrolling drags in the middle of the screen. Typing
// replaces a field's text on both: Command-A then the new text on the Mac, deletes then the new text on iOS.
// Helpers marked "iOS only" are not compiled for Mac Catalyst. Coverage on one platform says nothing about
// the other: run the tests on each.
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

/// Where screenshots go, passed explicitly to `ELShot`. Attachments always; PNG files only when `directory`
/// is set (nothing is read from the environment unless the test asks with `fromEnvironment:`).
@interface ELScreenshots : NSObject
/// Also write each screenshot as `<directory>/<name>.png` (created when needed); nil: attachments only.
@property (nonatomic, copy, nullable) NSString *directory;
/// The attachments' lifetime (default `XCTAttachmentLifetimeKeepAlways`, so a passing run keeps them).
@property (nonatomic) XCTAttachmentLifetime lifetime;
+ (instancetype)attachmentsOnly;
+ (instancetype)inDirectory:(NSString *)directory;
/// The directory named by the environment variable `name` (e.g. one the runner passes as `TEST_RUNNER_<name>`),
/// or attachments only when it is unset or empty.
+ (instancetype)fromEnvironment:(NSString *)name;
@end

/// The element with this accessibility identifier, of any type (a node's control, label or image).
XCUIElement *ELElement(XCUIApplication *app, NSString *identifier);

/// Polls `condition` every `interval` seconds until it holds or `timeout` passes; the last check is after the timeout.
BOOL ELPoll(NSTimeInterval timeout, NSTimeInterval interval, BOOL (^condition)(void));

/// A label's (or value's) text without the zero-width spaces the shell puts into long words so they can wrap.
NSString *ELText(XCUIElement *element);

/// Scrolls (down, then up past where it started) until the element is hittable; NO if it never is. Records
/// nothing: the actions below turn a NO into a failure.
BOOL ELScrollTo(XCUIApplication *app, XCUIElement *element);

/// How long the actions wait for an element to appear and to become enabled (20 s and 15 s by default).
extern NSTimeInterval ELAppearTimeout;
extern NSTimeInterval ELEnabledTimeout;

/// Waits for the element with this identifier; a failure at the caller's line and NO if it never appears.
#define ELWait(app, identifier) ELWaitAt((app), (identifier), @__FILE__, __LINE__)
/// Waits for, scrolls to and taps (clicks, on the Mac) the element, which must become enabled. An element not
/// there after two seconds is looked for by scrolling (a list makes its rows as they come into view).
#define ELTap(app, identifier) ELTapAt((app), (identifier), @__FILE__, __LINE__)
/// Replaces the text of the input with this identifier, then closes the keyboard (iOS: the shell's Done bar,
/// or return). On the Mac the field keeps focus.
#define ELType(app, identifier, text) ELTypeAt((app), (identifier), (text), @__FILE__, __LINE__)
/// Asserts that the element with this identifier exists and is disabled (a control the view advertises no
/// event for); NO with a failure otherwise.
#define ELExpectDisabled(app, identifier) ELExpectDisabledAt((app), (identifier), @__FILE__, __LINE__)
/// Asserts that no element has this identifier within `seconds`; NO with a failure if one appears.
#define ELExpectMissing(app, identifier, seconds) ELExpectMissingAt((app), (identifier), (seconds), @__FILE__, __LINE__)
/// A screenshot of the app attached to the running test as `name` and, with a directory, written there.
/// NO with a failure if the PNG cannot be written.
#define ELShot(test, app, name, screenshots) ELShotAt((test), (app), (name), (screenshots), @__FILE__, __LINE__)

BOOL ELWaitAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line);
BOOL ELTapAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line);
BOOL ELTypeAt(XCUIApplication *app, NSString *identifier, NSString *text, NSString *file, NSUInteger line);
BOOL ELExpectDisabledAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line);
BOOL ELExpectMissingAt(XCUIApplication *app, NSString *identifier, NSTimeInterval seconds, NSString *file, NSUInteger line);
BOOL ELShotAt(XCTestCase *test, XCUIApplication *app, NSString *name, ELScreenshots *screenshots, NSString *file, NSUInteger line);

/// Records an XCTest failure at `file`:`line` (what the helpers do when a precondition fails).
void ELFail(NSString *file, NSUInteger line, NSString *message);

NS_ASSUME_NONNULL_END
