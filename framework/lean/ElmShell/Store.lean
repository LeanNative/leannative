import ElmShell.Grammar

/-! # ElmShell.Store: `ELStore.m`, the store around the C interface, and the events (from `events`) -/

namespace ElmShell

set_option maxRecDepth 8000 in
def storeBody : List Stmt := [
    .pp "#import \"ElmLeanShell.h\"",
    .blank,
    .l "// Every call into Lean happens on the main thread except `elmlean_wait`, which blocks a background thread",
    .l "// until Lean has something queued; the main thread then drains it.",
    b "@implementation ELStore {" [
        .l "ELCapabilities *_capabilities;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static ELStore *store;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ store = [ELStore new]; });",
        .l "return store;"],
    .blank,
    b "- (instancetype)init {" [
        b "if ((self = [super init])) {" [
            .l "_view = ELDecode(@{@\"t\": @\"col\", @\"c\": @[]});",
            .l "_capabilities = [ELCapabilities new];"],
        .l "return self;"],
    .blank,
    b "- (void)start {" [
        b "if (elmlean_boot() != 0) {" [
            .l "_failure = @\"The app failed to start.\";",
            .l "return;"],
        .l "[self apply:[self take:elmlean_start()]];",
        b "NSThread *thread = [[NSThread alloc] initWithBlock:^{" [
            b "while (YES) {" [
                .l "elmlean_wait();",
                .l "dispatch_sync(dispatch_get_main_queue(), ^{ [[ELStore shared] drain]; });"]] "}];",
        .l "thread.stackSize = 8 << 20;",
        .l "[thread start];"],
    .blank,
    b "- (void)send:(ELPath *)path event:(NSDictionary *)event {" [
        .l "NSString *line = [self line:@{@\"seq\": @(_seq), @\"path\": path, @\"event\": event}];",
        .l "if (!line) return;",
        .l "[self apply:[self take:elmlean_event(line.UTF8String)]];"],
    .blank,
    b "- (void)drain {" [
        .l "[self apply:[self take:elmlean_drain()]];"],
    .blank,
    .l "/// A system event (scene phase, screen capture) for the app's `system` mapping.",
    b "- (void)system:(NSDictionary *)event {" [
        .l "NSString *line = [self line:event];",
        .l "if (!line) return;",
        .l "[self apply:[self take:elmlean_system(line.UTF8String)]];"],
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
        .l "if (o[@\"view\"]) _view = ELDecode(o[@\"view\"]);",
        .l "if ([o[@\"error\"] isKindOfClass:NSString.class] && ![o[@\"error\"] isEqualToString:@\"stale\"]) _failure = o[@\"error\"];",
        .l "NSArray *caps = [o[@\"caps\"] isKindOfClass:NSArray.class] ? o[@\"caps\"] : @[];",
        b "for (NSDictionary *cap in caps) {" [
            .l "if (![cap isKindOfClass:NSDictionary.class]) continue;",
            .l "NSNumber *capID = [cap[@\"id\"] isKindOfClass:NSNumber.class] ? cap[@\"id\"] : @(-1);",
            .l "NSString *name = [cap[@\"name\"] isKindOfClass:NSString.class] ? cap[@\"name\"] : @\"\";",
            .l "NSDictionary *args = [cap[@\"args\"] isKindOfClass:NSDictionary.class] ? cap[@\"args\"] : @{};",
            b "[_capabilities run:name args:args answer:^(NSDictionary *result) {" [
                .l "NSString *line = [self line:@{@\"id\": capID, @\"result\": result}];",
                .l "if (line) elmlean_cap_result(line.UTF8String);"] "}];"],
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

end ElmShell
