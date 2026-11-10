import Lean.Data.Json
import LeanNativeShell.ObjC

/-! # LeanNativeShell.BackgroundTasks: `LNBackgroundTasks`, in `LNCapabilities.m`

Background tasks through `BGTaskScheduler`, for the `bgtask.*` capabilities. iOS requires every launch
handler to be registered before the app finishes launching, so `LNAppDelegate` calls `registerLaunch`
first thing in `didFinishLaunching`: one handler per identifier the app lists in Info.plist
(`BGTaskSchedulerPermittedIdentifiers`; refresh tasks also need `UIBackgroundModes` `fetch`, processing
tasks `processing`). A launched task is reported to the app as the system event
`{"bgtask":{"id","kind","tag"}}` and stays pending until the app answers `bgtask.complete`; when iOS
expires it the app gets `{"bgtaskExpired":{"id","kind","tag"}}`, and a task still pending one second later
is completed by the shell with `success: false`. Everything happens on the main queue, like every answer.

**The tag.** A launch of an identifier ends the task still pending under it (iOS has launched its successor),
so a `bgtask.complete` that names only the identifier can end the successor: an older run that finishes on
its own after iOS launched the new task, but before the app has heard of it, would complete the new task
before its work ran. Each launch therefore carries a tag, a serial the shell counts up, and a
`bgtask.complete` with a `tag` completes the pending task only if it is that launch's: an older launch's
answer is `notPending`. A completion without a tag completes whatever task is pending under its identifier,
as before tags (apps that do not send one keep working).

**Continued processing** (iOS 26, `BGContinuedProcessingTask`; not on Mac Catalyst). Work a person started
that should finish though they leave the app: iOS keeps the app running, shows the work's title, subtitle and
progress in a Live Activity, and lets the person cancel it there. An identifier of this kind is listed in
Info.plist with a wildcard (`<bundle id>.<context>.*`); each piece of work has its own identifier under it,
which is registered when it is first asked for (iOS exempts these from the before-launch rule, and kills an
app that registers one identifier twice, so the shell registers each once). `bgtask.continue` registers and
submits; the launch arrives as `{"bgtask":{"id","kind":"continued","tag"}}` like any other; the app says how
far the work is with `bgtask.progress` (iOS expires work that reports none) and ends it with
`bgtask.complete`. A cancel by the person, or iOS taking the time back, is `{"bgtaskExpired":…}`.

`PendingTasks` below is the same bookkeeping in Lean, step for step; background-run-test's `tasks`
(`make check`) runs `LeanNative.Native.BackgroundTasks` against it. The Objective-C itself is only
compiled here (native-demo's builds), never run: launches happen only on a device. -/

namespace LeanNativeShell

set_option maxRecDepth 8000 in
def backgroundTasksClass : List Stmt := [
    .l "@interface LNBackgroundTasks ()",
    .l "- (void)schedule:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)complete:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)continueWork:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)progress:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "@end",
    .blank,
    .l "// BGContinuedProcessingTask: the iOS 26 SDK, and never Mac Catalyst",
    .pp "#if !TARGET_OS_MACCATALYST && defined(__IPHONE_26_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_26_0",
    .pp "#define LN_CONTINUED_TASKS 1",
    .pp "#else",
    .pp "#define LN_CONTINUED_TASKS 0",
    .pp "#endif",
    .blank,
    b "static NSString *LNTaskKind(BGTask *task) {" [
        .l "if ([task isKindOfClass:BGProcessingTask.class]) return @\"processing\";",
        .l "if ([task isKindOfClass:BGAppRefreshTask.class]) return @\"refresh\";",
        .pp "#if LN_CONTINUED_TASKS",
        .l "if (@available(iOS 26.0, *)) { if ([task isKindOfClass:BGContinuedProcessingTask.class]) return @\"continued\"; }",
        .pp "#endif",
        .l "return @\"other\";"],
    .blank,
    .l "/// A submission's answer: `{\"ok\":true}`, or `{\"ok\":false,\"error\":…,\"code\":…,\"detail\":…}`.",
    b "static NSDictionary *LNSubmitted(NSError *error) {" [
        .l "if (!error) return @{@\"ok\": @YES};",
        .l "NSString *name = @\"unknown\";",
        b "if ([error.domain isEqualToString:BGTaskSchedulerErrorDomain]) {" [
            b "switch ((BGTaskSchedulerErrorCode)error.code) {" [
                .l "case BGTaskSchedulerErrorCodeUnavailable: name = @\"unavailable\"; break;",
                .l "case BGTaskSchedulerErrorCodeTooManyPendingTaskRequests: name = @\"tooManyPending\"; break;",
                .pp "#if TARGET_OS_MACCATALYST",
                .l "// Mac Catalyst registers the launch handlers but refuses every request this way, however the",
                .l "// identifier is listed: the Mac runs no background tasks for the app",
                .l "case BGTaskSchedulerErrorCodeNotPermitted: name = @\"unavailable\"; break;",
                .pp "#else",
                .l "case BGTaskSchedulerErrorCodeNotPermitted: name = @\"notPermitted\"; break;",
                .pp "#endif",
                .l "case BGTaskSchedulerErrorCodeImmediateRunIneligible: name = @\"immediateRunIneligible\"; break;",
                .l "default: break;"]],
        .l "return @{@\"ok\": @NO, @\"error\": name, @\"code\": @(error.code), @\"detail\": error.localizedDescription ?: @\"\"};"],
    .blank,
    b "@implementation LNBackgroundTasks {" [
        .l "NSMutableSet<NSString *> *_registered;",
        .l "// the wildcard identifiers of Info.plist, without their `*`: what a continued task's identifier starts with",
        .l "NSMutableArray<NSString *> *_continuedPrefixes;",
        .l "// launched and not yet completed, by identifier, each with its launch's tag (`PendingTasks`)",
        .l "NSMutableDictionary<NSString *, BGTask *> *_running;",
        .l "NSMutableDictionary<NSString *, NSNumber *> *_tags;",
        .l "// the last launch's tag; the first is 1",
        .l "unsigned long long _serial;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static LNBackgroundTasks *shared;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ shared = [LNBackgroundTasks new]; });",
        .l "return shared;"],
    .blank,
    b "- (instancetype)init {" [
        b "if ((self = [super init])) {" [
            .l "_registered = [NSMutableSet set];",
            .l "_continuedPrefixes = [NSMutableArray array];",
            .l "_running = [NSMutableDictionary dictionary];",
            .l "_tags = [NSMutableDictionary dictionary];"],
        .l "return self;"],
    .blank,
    .l "/// Once, before launch ends: iOS kills an app that registers an identifier twice, and raises for one",
    .l "/// Info.plist does not list.",
    b "- (void)registerLaunch {" [
        .l "static BOOL done;",
        .l "if (done) return;",
        .l "done = YES;",
        .l "NSArray *identifiers = [NSBundle.mainBundle objectForInfoDictionaryKey:@\"BGTaskSchedulerPermittedIdentifiers\"];",
        .l "if (![identifiers isKindOfClass:NSArray.class]) return;",
        b "for (NSString *identifier in identifiers) {" [
            .l "if (![identifier isKindOfClass:NSString.class] || [_registered containsObject:identifier]) continue;",
            .l "// a wildcard names continued tasks: each is registered when it is asked for (`continueWork:`)",
            b "if ([identifier hasSuffix:@\".*\"]) {" [
                .l "[_continuedPrefixes addObject:[identifier substringToIndex:identifier.length - 1]];",
                .l "continue;"],
            .blk [("@try {", [
                  .l "BOOL ok = [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:identifier usingQueue:dispatch_get_main_queue()",
                  .l "                                                             launchHandler:^(__kindof BGTask *task) { [self launched:task]; }];",
                  .l "if (ok) [_registered addObject:identifier];"]), ("} @catch (NSException *e) {", [
                  .l "NSLog(@\"bgtask: cannot register %@: %@\", identifier, e.reason);"])] "}"]],
    .blank,
    b "- (void)launched:(BGTask *)task {" [
        .l "NSString *identifier = task.identifier;",
        .l "NSNumber *tag = @(++_serial);",
        .l "NSDictionary *info = @{@\"id\": identifier, @\"kind\": LNTaskKind(task), @\"tag\": tag};",
        .l "// a task of the same identifier still pending is over: iOS has launched its successor",
        .l "[self finish:_running[identifier] success:NO];",
        .l "_running[identifier] = task;",
        .l "_tags[identifier] = tag;",
        .l "__weak BGTask *weakTask = task;",
        b "task.expirationHandler = ^{" [
            .l "dispatch_async(dispatch_get_main_queue(), ^{ [self expired:weakTask info:info]; });"] "};",
        .l "[LNStore.shared system:@{@\"bgtask\": info}];"],
    .blank,
    .l "/// The app hears of the expiration and has a second to complete the task; after that the shell does.",
    b "- (void)expired:(BGTask *)task info:(NSDictionary *)info {" [
        .l "if (!task || _running[task.identifier] != task) return;",
        .l "[LNStore.shared system:@{@\"bgtaskExpired\": info}];",
        b "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{" [
            .l "[self finish:task success:NO];"] "});"],
    .blank,
    .l "/// Completes `task` if it is still the pending one of its identifier.",
    b "- (BOOL)finish:(nullable BGTask *)task success:(BOOL)success {" [
        .l "if (!task || _running[task.identifier] != task) return NO;",
        .l "[_running removeObjectForKey:task.identifier];",
        .l "[_tags removeObjectForKey:task.identifier];",
        .l "task.expirationHandler = nil;",
        .l "[task setTaskCompletedWithSuccess:success];",
        .l "return YES;"],
    .blank,
    b "- (void)schedule:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSString *identifier = LNArgString(args, @\"id\");",
        .l "NSString *kind = LNArgString(args, @\"kind\") ?: @\"refresh\";",
        .l "BOOL processing = [kind isEqualToString:@\"processing\"];",
        b "if (identifier.length == 0 || !(processing || [kind isEqualToString:@\"refresh\"])) {" [
            .l "answer(@{@\"ok\": @NO, @\"error\": @\"badArgs\", @\"detail\": @\"an id, and a kind of refresh or processing\"});",
            .l "return;"],
        b "if (![_registered containsObject:identifier]) {" [
            .l "answer(@{@\"ok\": @NO, @\"error\": @\"notPermitted\", @\"detail\": @\"not registered: list it in BGTaskSchedulerPermittedIdentifiers\"});",
            .l "return;"],
        .l "BGTaskRequest *request;",
        .blk [("if (processing) {", [
              .l "BGProcessingTaskRequest *p = [[BGProcessingTaskRequest alloc] initWithIdentifier:identifier];",
              .l "p.requiresNetworkConnectivity = [LNArgNumber(args, @\"requiresNetwork\") boolValue];",
              .l "p.requiresExternalPower = [LNArgNumber(args, @\"requiresPower\") boolValue];",
              .l "request = p;"]), ("} else {", [
              .l "request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:identifier];"])] "}",
        .l "NSNumber *after = LNArgNumber(args, @\"after\");",
        .l "if (after) request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:after.doubleValue];",
        .l "BGTaskScheduler *scheduler = BGTaskScheduler.sharedScheduler;",
        .l "// one request per identifier: a new one replaces the last",
        .l "[scheduler cancelTaskRequestWithIdentifier:identifier];",
        .l "// the completion form is in the iOS 27 SDK only; an older SDK (CI's Xcode 26) builds the error form alone",
        .pp "#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 270000",
        .blk [("if (@available(iOS 27.0, *)) {", [
              .l "// the completion form reports every refusal; Apple asks for it off the main thread",
              b "dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{" [
                  b "[scheduler submitTaskRequest:request completionHandler:^(NSError *error) {" [
                      .l "NSDictionary *result = LNSubmitted(error);",
                      .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"] "}];"] "});"])] "} else",
        .pp "#endif",
        .blk [("{", [
              .l "NSError *error = nil;",
              .pp "#pragma clang diagnostic push",
              .pp "#pragma clang diagnostic ignored \"-Wdeprecated-declarations\"",
              .l "BOOL ok = [scheduler submitTaskRequest:request error:&error];",
              .pp "#pragma clang diagnostic pop",
              .l "answer(LNSubmitted(ok ? nil : (error ?: [NSError errorWithDomain:BGTaskSchedulerErrorDomain code:BGTaskSchedulerErrorCodeUnavailable userInfo:nil])));"])] "}"],
    .blank,
    .l "/// `bgtask.continue`: the work `id` (under a wildcard identifier of Info.plist) registered, once, and",
    .l "/// submitted with what the person is shown. iOS runs it at once or queues it (`strategy` `fail`: refuses).",
    b "- (void)continueWork:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .pp "#if LN_CONTINUED_TASKS",
        b "if (@available(iOS 26.0, *)) {" [
            .l "NSString *identifier = LNArgString(args, @\"id\");",
            .l "NSString *title = LNArgString(args, @\"title\");",
            b "if (identifier.length == 0 || title.length == 0) {" [
                .l "answer(@{@\"ok\": @NO, @\"error\": @\"badArgs\", @\"detail\": @\"an id and a title\"});",
                .l "return;"],
            .l "BOOL permitted = NO;",
            .l "for (NSString *prefix in _continuedPrefixes) if ([identifier hasPrefix:prefix] && identifier.length > prefix.length) permitted = YES;",
            b "if (!permitted) {" [
                .l "answer(@{@\"ok\": @NO, @\"error\": @\"notPermitted\", @\"detail\": @\"no wildcard identifier of BGTaskSchedulerPermittedIdentifiers covers it\"});",
                .l "return;"],
            b "if (![_registered containsObject:identifier]) {" [
                .blk [("@try {", [
                      .l "BOOL ok = [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:identifier usingQueue:dispatch_get_main_queue()",
                      .l "                                                             launchHandler:^(__kindof BGTask *task) { [self launched:task]; }];",
                      .l "if (ok) [_registered addObject:identifier];"]), ("} @catch (NSException *e) {", [
                      .l "NSLog(@\"bgtask: cannot register %@: %@\", identifier, e.reason);"])] "}",
                b "if (![_registered containsObject:identifier]) {" [
                    .l "answer(@{@\"ok\": @NO, @\"error\": @\"notPermitted\", @\"detail\": @\"iOS did not register it\"});",
                    .l "return;"]],
            .l "BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc] initWithIdentifier:identifier",
            .l "    title:title subtitle:LNArgString(args, @\"subtitle\") ?: @\"\"];",
            .l "if ([LNArgString(args, @\"strategy\") isEqualToString:@\"fail\"]) request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;",
            .l "NSError *error = nil;",
            .pp "#pragma clang diagnostic push",
            .pp "#pragma clang diagnostic ignored \"-Wdeprecated-declarations\"",
            .l "BOOL ok = [BGTaskScheduler.sharedScheduler submitTaskRequest:request error:&error];",
            .pp "#pragma clang diagnostic pop",
            .l "answer(LNSubmitted(ok ? nil : (error ?: [NSError errorWithDomain:BGTaskSchedulerErrorDomain code:BGTaskSchedulerErrorCodeUnavailable userInfo:nil])));",
            .l "return;"],
        .pp "#endif",
        .l "answer(@{@\"ok\": @NO, @\"error\": @\"unavailable\", @\"detail\": @\"continued processing needs iOS 26, and is not on the Mac\"});"],
    .blank,
    .l "/// `bgtask.progress`: how far the continued task pending under `id` is (`completed` of `total`), and, when",
    .l "/// given, the title and subtitle the person is shown now.",
    b "- (void)progress:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .pp "#if LN_CONTINUED_TASKS",
        b "if (@available(iOS 26.0, *)) {" [
            .l "NSString *identifier = LNArgString(args, @\"id\") ?: @\"\";",
            .l "BGTask *pending = _running[identifier];",
            .l "NSNumber *tag = LNArgNumber(args, @\"tag\");",
            .l "if (tag && ![tag isEqualToNumber:(_tags[identifier] ?: @0)]) pending = nil;",
            b "if (![pending isKindOfClass:BGContinuedProcessingTask.class]) {" [
                .l "answer(@{@\"ok\": @NO, @\"error\": @\"notPending\"});",
                .l "return;"],
            .l "BGContinuedProcessingTask *task = (BGContinuedProcessingTask *)pending;",
            .l "NSNumber *total = LNArgNumber(args, @\"total\");",
            .l "NSNumber *completed = LNArgNumber(args, @\"completed\");",
            .l "if (total) task.progress.totalUnitCount = MAX(total.longLongValue, 1);",
            .l "// never the whole of it: a finished progress is the task's end, which is `bgtask.complete`'s to say",
            .l "if (completed) task.progress.completedUnitCount = MIN(MAX(completed.longLongValue, 0), MAX(task.progress.totalUnitCount - 1, 0));",
            .l "NSString *title = LNArgString(args, @\"title\");",
            .l "NSString *subtitle = LNArgString(args, @\"subtitle\");",
            .l "if (title.length || subtitle.length) [task updateTitle:(title.length ? title : task.title) subtitle:(subtitle ?: task.subtitle)];",
            .l "answer(@{@\"ok\": @YES});",
            .l "return;"],
        .pp "#endif",
        .l "answer(@{@\"ok\": @NO, @\"error\": @\"unavailable\"});"],
    .blank,
    b "- (void)complete:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSString *identifier = LNArgString(args, @\"id\") ?: @\"\";",
        .l "BGTask *task = _running[identifier];",
        .l "// a completion that names its launch completes that launch's task only: an older run's late answer",
        .l "// must not end the successor iOS launched since (`PendingTasks.complete`); one without a tag",
        .l "// completes whatever is pending under the identifier",
        .l "NSNumber *tag = LNArgNumber(args, @\"tag\");",
        .l "if (tag && ![tag isEqualToNumber:(_tags[identifier] ?: @0)]) task = nil;",
        .l "BOOL done = [self finish:task success:[LNArgNumber(args, @\"success\") boolValue]];",
        .l "answer(done ? @{@\"ok\": @YES} : @{@\"ok\": @NO, @\"error\": @\"notPending\"});"],
    .blank,
    .l "@end"]

/-! ## `PendingTasks`: the shell's bookkeeping, in Lean -/

/-- What `LNBackgroundTasks` keeps: the task pending under each identifier, by its launch's tag, and the
last tag given. -/
structure PendingTasks where
  pending : List (String × Nat) := []
  serial : Nat := 0
  deriving Repr, BEq, Inhabited

namespace PendingTasks

/-- `launched:`: the new launch's tag, and the tag of the task it ended (completed unsuccessfully), if one
was pending under the identifier. -/
def launched (s : PendingTasks) (id : String) : PendingTasks × Nat × Option Nat :=
  let tag := s.serial + 1
  ({ pending := (id, tag) :: s.pending.filter (·.1 != id), serial := tag }, tag, s.pending.lookup id)

/-- `expired:`: the app hears an expiry only for the task still pending under the identifier. -/
def expires (s : PendingTasks) (id : String) (tag : Nat) : Bool := s.pending.lookup id == some tag

/-- `complete:` (and `finish:`): the tag of the task completed, or none (`notPending`). A `tag` must be the
pending task's; without one, whatever is pending under the identifier is completed. -/
def complete (s : PendingTasks) (id : String) (tag : Option Nat) : PendingTasks × Option Nat :=
  match s.pending.lookup id with
  | some t => if tag.all (· == t) then ({ s with pending := s.pending.filter (·.1 != id) }, some t) else (s, none)
  | none => (s, none)

/-- The system event of a launch (`expired := false`) or an expiry, as `launched:` posts it. -/
def event (expired : Bool) (id kind : String) (tag : Nat) : Lean.Json :=
  Lean.Json.mkObj [(if expired then "bgtaskExpired" else "bgtask",
    Lean.Json.mkObj [("id", Lean.Json.str id), ("kind", Lean.Json.str kind), ("tag", Lean.toJson tag)])]

end PendingTasks

end LeanNativeShell
