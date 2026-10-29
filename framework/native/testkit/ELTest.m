#import "ELTest.h"

NSTimeInterval ELAppearTimeout = 20;
NSTimeInterval ELEnabledTimeout = 15;

@implementation ELScreenshots

+ (instancetype)attachmentsOnly {
    ELScreenshots *s = [self new];
    s.lifetime = XCTAttachmentLifetimeKeepAlways;
    return s;
}

+ (instancetype)inDirectory:(NSString *)directory {
    ELScreenshots *s = [self attachmentsOnly];
    s.directory = directory;
    return s;
}

+ (instancetype)fromEnvironment:(NSString *)name {
    NSString *dir = NSProcessInfo.processInfo.environment[name];
    return dir.length ? [self inDirectory:dir] : [self attachmentsOnly];
}

@end

void ELFail(NSString *file, NSUInteger line, NSString *message) {
    // what XCTFail does, at the caller's file and line (the running test; nil is the current one)
    _XCTPreformattedFailureHandler(nil, YES, file, line, @"ELTest", message);
}

XCUIElement *ELElement(XCUIApplication *app, NSString *identifier) {
    return [[app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:identifier].firstMatch;
}

BOOL ELPoll(NSTimeInterval timeout, NSTimeInterval interval, BOOL (^condition)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        if (condition()) return YES;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:interval]];
    } while (end.timeIntervalSinceNow > 0);
    return condition();
}

NSString *ELText(XCUIElement *element) {
    NSString *text = element.label.length ? element.label : ([element.value isKindOfClass:NSString.class] ? element.value : @"");
    return [text stringByReplacingOccurrencesOfString:@"​" withString:@""];
}

/// One scroll of the content, down (towards the end) or up.
static void ELScrollStep(XCUIApplication *app, BOOL down) {
#if TARGET_OS_MACCATALYST
    // no touch screen: the scroll wheel, over the window's middle (negative deltaY scrolls the content up); the
    // window's, as a Mac application's own frame is unbounded (a point in it is at infinity)
    [[app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)] scrollByDeltaX:0 deltaY:down ? -200 : 200];
#else
    // drag in the middle of the screen: the bottom edge belongs to the home indicator
    XCUICoordinate *from = [app coordinateWithNormalizedOffset:CGVectorMake(0.5, down ? 0.7 : 0.35)];
    [from pressForDuration:0.05 thenDragToCoordinate:[app coordinateWithNormalizedOffset:CGVectorMake(0.5, down ? 0.35 : 0.7)]];
#endif
}

/// Scrolls (8 steps down, then up past where it started) until the element is hittable or `deadline` passes.
static BOOL ELScrollUntil(XCUIApplication *app, XCUIElement *element, NSDate *_Nullable deadline) {
    for (int step = 0; step < 24; step++) {
        if (element.exists && element.hittable) return YES;
        if (deadline && deadline.timeIntervalSinceNow <= 0) return NO;
        ELScrollStep(app, step < 8);
    }
    return element.exists && element.hittable;
}

BOOL ELScrollTo(XCUIApplication *app, XCUIElement *element) {
    return ELScrollUntil(app, element, nil);
}

/// The element, present, in view and enabled; nil after recording why not.
static XCUIElement *ELReady(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line) {
    XCUIElement *e = ELElement(app, identifier);
    // a list makes its rows only as they scroll into view: an element not there after a moment is looked for
    // by scrolling, then waited for the rest of the time
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:ELAppearTimeout];
    if (![e waitForExistenceWithTimeout:MIN(2, ELAppearTimeout)] && !ELScrollUntil(app, e, deadline) &&
        ![e waitForExistenceWithTimeout:MAX(deadline.timeIntervalSinceNow, 0)]) {
        ELFail(file, line, [NSString stringWithFormat:@"%@ does not appear within %.0f s, nor by scrolling", identifier, ELAppearTimeout]);
        return nil;
    }
    if (!ELScrollTo(app, e)) {
        ELFail(file, line, [NSString stringWithFormat:@"%@ cannot be scrolled into view", identifier]);
        return nil;
    }
    if (!ELPoll(ELEnabledTimeout, 0.2, ^BOOL{ return e.isEnabled; })) {
        ELFail(file, line, [NSString stringWithFormat:@"%@ stays disabled for %.0f s", identifier, ELEnabledTimeout]);
        return nil;
    }
    return e;
}

BOOL ELWaitAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line) {
    if ([ELElement(app, identifier) waitForExistenceWithTimeout:ELAppearTimeout]) return YES;
    ELFail(file, line, [NSString stringWithFormat:@"%@ does not appear within %.0f s", identifier, ELAppearTimeout]);
    return NO;
}

BOOL ELTapAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line) {
    XCUIElement *e = ELReady(app, identifier, file, line);
    if (!e) return NO;
#if TARGET_OS_MACCATALYST
    [e click];
#else
    [e tap];
#endif
    return YES;
}

BOOL ELTypeAt(XCUIApplication *app, NSString *identifier, NSString *text, NSString *file, NSUInteger line) {
    XCUIElement *field = ELReady(app, identifier, file, line);
    if (!field) return NO;
#if TARGET_OS_MACCATALYST
    [field click];
    // whatever is there, selected, is replaced by what is typed
    [field typeKey:@"a" modifierFlags:XCUIKeyModifierCommand];
    if (text.length) [field typeText:text];
    else [field typeKey:XCUIKeyboardKeyDelete modifierFlags:XCUIKeyModifierNone];
#else
    [field tap];
    NSString *current = [field.value isKindOfClass:NSString.class] ? field.value : @"";
    if (current.length && ![current isEqualToString:field.placeholderValue]) {
        NSMutableString *delete = [NSMutableString string];
        for (NSUInteger i = 0; i < current.length; i++) [delete appendString:XCUIKeyboardKeyDelete];
        [field typeText:delete];
    }
    if (text.length) [field typeText:text];
    XCUIElement *done = ELElement(app, @"keyboardDone");
    if (done.exists && done.hittable) [done tap];
    else if (app.keyboards.count > 0 && app.keyboards.buttons[@"return"].exists) [app.keyboards.buttons[@"return"] tap];
#endif
    return YES;
}

BOOL ELExpectDisabledAt(XCUIApplication *app, NSString *identifier, NSString *file, NSUInteger line) {
    XCUIElement *e = ELElement(app, identifier);
    if (![e waitForExistenceWithTimeout:ELAppearTimeout]) {
        ELFail(file, line, [NSString stringWithFormat:@"%@ does not appear within %.0f s", identifier, ELAppearTimeout]);
        return NO;
    }
    if (e.isEnabled) {
        ELFail(file, line, [NSString stringWithFormat:@"%@ is enabled", identifier]);
        return NO;
    }
    return YES;
}

BOOL ELExpectMissingAt(XCUIApplication *app, NSString *identifier, NSTimeInterval seconds, NSString *file, NSUInteger line) {
    if (![ELElement(app, identifier) waitForExistenceWithTimeout:seconds]) return YES;
    ELFail(file, line, [NSString stringWithFormat:@"%@ exists", identifier]);
    return NO;
}

BOOL ELShotAt(XCTestCase *test, XCUIApplication *app, NSString *name, ELScreenshots *screenshots, NSString *file, NSUInteger line) {
    XCUIScreenshot *shot = app.screenshot;
    XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:shot];
    attachment.name = name;
    attachment.lifetime = screenshots.lifetime;
    [test addAttachment:attachment];
    if (!screenshots.directory.length) return YES;
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:screenshots.directory withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![shot.PNGRepresentation writeToFile:[screenshots.directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]]
                                     options:NSDataWritingAtomic error:&error]) {
        ELFail(file, line, [NSString stringWithFormat:@"screenshot %@ not written to %@: %@", name, screenshots.directory, error.localizedDescription]);
        return NO;
    }
    return YES;
}
