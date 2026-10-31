// LNTest: XCUITest helpers for any LeanNative native app (test-only Objective-C; never part of an app target).
//
// Add this directory to the app's UI-test target only (a manifest's `uiTests` does: LeanNativeShell/Manifest.lean;
// in a hand-kept project.yml, `sources: [UITests, <framework>/native/testkit]` on the `bundle.ui-testing`
// target). Nothing here knows the app: elements are found by the accessibility identifiers the app gives its
// nodes (`Html.identified`), and screenshots go where the test says.
//
// Every action checks its preconditions first (the element appears, can be brought into view, is enabled)
// and, when one fails, records an XCTest failure at the caller's line and returns NO without acting: no
// tap or keystroke lands on whatever else is on screen. A test that cannot go on checks the result:
//
//     if (!LNTap(app, @"send")) return;
//
// Platforms. Under Mac Catalyst a "tap" is a click and scrolling is the scroll wheel (there is no touch
// screen to drag); on iOS (device or simulator) scrolling drags in the middle of the screen. Typing
// replaces a field's text on both: Command-A then the new text on the Mac, deletes then the new text on iOS.
// Helpers marked "iOS only" are not compiled for Mac Catalyst. Coverage on one platform says nothing about
// the other: run the tests on each.
#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN

/// Where screenshots go, passed explicitly to `LNShot`. Attachments always; PNG files only when `directory`
/// is set (nothing is read from the environment unless the test asks with `fromEnvironment:`).
@interface LNScreenshots : NSObject
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
XCUIElement *LNElement(XCUIApplication *app, NSString *identifier);

/// Polls `condition` every `interval` seconds until it holds or `timeout` passes; the last check is after the timeout.
BOOL LNPoll(NSTimeInterval timeout, NSTimeInterval interval, BOOL (^condition)(void));

/// A label's (or value's) text without the zero-width spaces the shell puts into long words so they can wrap.
NSString *LNText(XCUIElement *element);

/// Scrolls (down, then up past where it started) until the element is hittable; NO if it never is. Records
/// nothing: the actions below turn a NO into a failure.
BOOL LNScrollTo(XCUIApplication *app, XCUIElement *element);

/// How long the actions wait for an element to appear and to become enabled (20 s and 15 s by default).
extern NSTimeInterval LNAppearTimeout;
extern NSTimeInterval LNEnabledTimeout;

/// Waits for the element with this identifier; a failure at the caller's line and NO if it never appears.
#define LNWait(app, identifier) LNWaitAt((app), (identifier), @__FILE__, __LINE__)
/// Waits for, scrolls to and taps (clicks, on the Mac) the element, which must become enabled. An element not
/// there after two seconds is looked for by scrolling (a list makes its rows as they come into view).
#define LNTap(app, identifier) LNTapAt((app), (identifier), @__FILE__, __LINE__)
/// Replaces the text of the input with this identifier, then closes the keyboard (iOS: the shell's Done bar,
/// or return). On the Mac the field keeps focus.
#define LNType(app, identifier, text) LNTypeAt((app), (identifier), (text), @__FILE__, __LINE__)
/// Asserts that the element with this identifier exists and is disabled (a control the view advertises no
/// event for); NO with a failure otherwise.
#define LNExpectDisabled(app, identifier) LNExpectDisabledAt((app), (identifier), @__FILE__, __LINE__)
/// Asserts that no element has this identifier within `seconds`; NO with a failure if one appears.
#define LNExpectMissing(app, identifier, seconds) LNExpectMissingAt((app), (identifier), (seconds), @__FILE__, __LINE__)
/// A screenshot of the app attached to the running test as `name` and, with a directory, written there.
/// NO with a failure if the PNG cannot be written.
#define LNShot(test, app, name, screenshots) LNShotAt((test), (app), (name), (screenshots), @__FILE__, __LINE__)

BOOL LNWaitAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line);
BOOL LNTapAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line);
BOOL LNTypeAt(XCUIApplication *app, NSString *identifier, NSString *text, NSString *file, NSUInteger line);
BOOL LNExpectDisabledAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line);
BOOL LNExpectMissingAt(XCUIApplication *app, NSString *identifier, NSTimeInterval seconds, NSString *file, NSUInteger line);
BOOL LNShotAt(XCTestCase *test, XCUIApplication *app, NSString *name, LNScreenshots *screenshots, NSString *file, NSUInteger line);

/// Records an XCTest failure at `file`:`line` (what the helpers do when a precondition fails).
void LNFail(NSString *file, NSUInteger line, NSString *message);

/// LNTap and LNType for an element found any way (a tab, an alert's button, a text), recording nothing: nil
/// when it was done, else why not (`name` says which element). The journey driver (LNDriver.m) answers with it.
NSString *_Nullable LNTapElement(XCUIApplication *app, XCUIElement *element, NSString *name);
/// LNTapElement, holding the element down for `seconds` instead (a stepper's autorepeat).
NSString *_Nullable LNPressElement(XCUIApplication *app, XCUIElement *element, NSString *name, NSTimeInterval seconds);
NSString *_Nullable LNTypeElement(XCUIApplication *app, XCUIElement *element, NSString *name, NSString *text);

NS_ASSUME_NONNULL_END
