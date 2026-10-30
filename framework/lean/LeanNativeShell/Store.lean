import LeanNativeShell.Grammar

/-! # LeanNativeShell.Store: `LNStore.m`, the store around the C interface, and the events (from `events`) -/

namespace LeanNativeShell

set_option maxRecDepth 8000 in
def storeBody : List Stmt := [
    .pp "#import \"LeanNativeShell.h\"",
    .blank,
    .l "/// `Wire.accepts` at a path of the last view (LeanNative/Wire.lean): whether the node there takes the event.",
    .l "/// The shell sends nothing else, so a tap on something without an action (a list row that only shows",
    .l "/// text, a disabled button, a screen without pull to refresh) is no event at all, never a `no-handler`.",
    b "static BOOL LNAccepts(NSDictionary *view, LNPath *path, NSDictionary *event) {" [
        .l "NSDictionary *n = view;",
        b "for (NSNumber *i in path) {" [
            .l "NSArray *c = [n[@\"c\"] isKindOfClass:NSArray.class] ? n[@\"c\"] : @[];",
            .l "if (![i isKindOfClass:NSNumber.class] || i.integerValue < 0 || (NSUInteger)i.integerValue >= c.count) return NO;",
            .l "n = c[(NSUInteger)i.integerValue];",
            .l "if (![n isKindOfClass:NSDictionary.class]) return NO;"],
        .l "NSString *t = n[@\"t\"], *k = event[@\"k\"];",
        .l "if ([k isEqualToString:@\"click\"]) return ([t isEqualToString:@\"button\"] && [n[@\"enabled\"] boolValue])",
        .l "    || ([t isEqualToString:@\"screen\"] && [n[@\"refreshable\"] boolValue]);",
        .l "if ([k isEqualToString:@\"input\"]) return [t isEqualToString:@\"field\"] || [t isEqualToString:@\"input\"];",
        .l "if ([k isEqualToString:@\"submit\"]) return ([t isEqualToString:@\"field\"] || [t isEqualToString:@\"input\"]) && [n[@\"submits\"] boolValue];",
        .l "if ([k isEqualToString:@\"toggle\"]) return [t isEqualToString:@\"toggle\"] || [t isEqualToString:@\"disclosure\"];",
        .l "if ([k isEqualToString:@\"select\"]) return [@[@\"tabs\", @\"picker\", @\"stepper\"] containsObject:t];",
        .l "if ([k isEqualToString:@\"dismiss\"]) return ([t isEqualToString:@\"screen\"] && [n[@\"back\"] boolValue])",
        .l "    || ([t isEqualToString:@\"sheet\"] && [n[@\"dismissable\"] boolValue]);",
        .l "return NO;"],
    .blank,
    .l "// Every call into Lean happens on the main thread except `leannative_wait`, which blocks a background thread",
    .l "// until Lean has something queued; the main thread then drains it.",
    b "@implementation LNStore {" [
        .l "LNCapabilities *_capabilities;",
        .l "BOOL _started, _booted;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static LNStore *store;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ store = [LNStore new]; });",
        .l "return store;"],
    .blank,
    b "- (instancetype)init {" [
        b "if ((self = [super init])) {" [
            .l "_view = LNDecode(@{@\"t\": @\"col\", @\"c\": @[]});",
            .l "_capabilities = [LNCapabilities new];"],
        .l "return self;"],
    .blank,
    b "- (void)start {" [
        .l "if (_started) return;",
        .l "_started = YES;",
        b "if (leannative_boot() != 0) {" [
            .l "_failure = @\"The app failed to start.\";",
            .l "return;"],
        .l "_booted = YES;",
        .l "[self apply:[self take:leannative_start()]];",
        b "NSThread *thread = [[NSThread alloc] initWithBlock:^{" [
            b "while (YES) {" [
                .l "leannative_wait();",
                .l "dispatch_sync(dispatch_get_main_queue(), ^{ [[LNStore shared] drain]; });"]] "}];",
        .l "thread.stackSize = 8 << 20;",
        .l "[thread start];"],
    .blank,
    b "- (void)send:(LNPath *)path event:(NSDictionary *)event {" [
        .l "if (!LNAccepts(_view, path, event)) return;",
        .l "NSString *line = [self line:@{@\"seq\": @(_seq), @\"path\": path, @\"event\": event}];",
        .l "if (!line) return;",
        .l "[self apply:[self take:leannative_event(line.UTF8String)]];"],
    .blank,
    b "- (void)drain {" [
        .l "[self apply:[self take:leannative_drain()]];"],
    .blank,
    .l "/// A system event (scene phase, screen capture, background task) for the app's `system` mapping. One",
    .l "/// that comes before `start` (a background task launched early) starts the app first.",
    b "- (void)system:(NSDictionary *)event {" [
        .l "[self start];",
        .l "if (!_booted) return;",
        .l "NSString *line = [self line:event];",
        .l "if (!line) return;",
        .l "[self apply:[self take:leannative_system(line.UTF8String)]];"],
    .blank,
    b "- (nullable NSString *)line:(id)object {" [
        .l "NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];",
        .l "return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;"],
    .blank,
    b "- (NSString *)take:(char *)p {" [
        .l "if (!p) return @\"\";",
        .l "NSString *s = [NSString stringWithUTF8String:p];",
        .l "free(p);",
        .l "return s ?: @\"\";"],
    .blank,
    b "- (void)apply:(NSString *)reply {" [
        .l "NSData *data = [reply dataUsingEncoding:NSUTF8StringEncoding];",
        .l "NSDictionary *o = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;",
        .l "if (![o isKindOfClass:NSDictionary.class]) return;",
        .l "if ([o[@\"seq\"] isKindOfClass:NSNumber.class]) _seq = [o[@\"seq\"] integerValue];",
        .l "if (o[@\"view\"]) _view = LNDecode(o[@\"view\"]);",
        .l "if ([o[@\"error\"] isKindOfClass:NSString.class] && ![o[@\"error\"] isEqualToString:@\"stale\"]) _failure = o[@\"error\"];",
        .l "NSArray *caps = [o[@\"caps\"] isKindOfClass:NSArray.class] ? o[@\"caps\"] : @[];",
        b "for (NSDictionary *cap in caps) {" [
            .l "if (![cap isKindOfClass:NSDictionary.class]) continue;",
            .l "NSNumber *capID = [cap[@\"id\"] isKindOfClass:NSNumber.class] ? cap[@\"id\"] : @(-1);",
            .l "NSString *name = [cap[@\"name\"] isKindOfClass:NSString.class] ? cap[@\"name\"] : @\"\";",
            .l "NSDictionary *args = [cap[@\"args\"] isKindOfClass:NSDictionary.class] ? cap[@\"args\"] : @{};",
            b "[_capabilities run:name args:args answer:^(NSDictionary *result) {" [
                .l "NSString *line = [self line:@{@\"id\": capID, @\"result\": result}];",
                .l "if (line) leannative_cap_result(line.UTF8String);"] "}];"],
        .l "if (self.onChange) self.onChange();"],
    .blank,
    .l "@end",
    .blank]

def eventDefs : List Stmt :=
  events.map fun e =>
    let value := match e.2 with
      | some (_, v) => s!", @\"value\": {v}"
      | none => ""
    .l s!"{eventSig e} \{ return @\{@\"k\": {lit e.1}{value}}; }"

def storeFile : List Stmt := storeBody ++ eventDefs

end LeanNativeShell
