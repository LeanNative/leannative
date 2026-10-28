import ElmShell.ObjC

/-! # ElmShell.BackgroundTasks: `ELBackgroundTasks`, in `ELCapabilities.m`

Background tasks through `BGTaskScheduler`, for the `bgtask.*` capabilities. iOS requires every launch
handler to be registered before the app finishes launching, so `ELAppDelegate` calls `registerLaunch`
first thing in `didFinishLaunching`: one handler per identifier the app lists in Info.plist
(`BGTaskSchedulerPermittedIdentifiers`; refresh tasks also need `UIBackgroundModes` `fetch`, processing
tasks `processing`). A launched task is reported to the app as the system event
`{"bgtask":{"id","kind"}}` and stays pending until the app answers `bgtask.complete`; when iOS expires it
the app gets `{"bgtaskExpired":{"id","kind"}}`, and a task still pending one second later is completed
by the shell with `success: false`. Everything happens on the main queue, like every answer. -/

namespace ElmShell

set_option maxRecDepth 8000 in
def backgroundTasksClass : List Stmt := [
    .l "@interface ELBackgroundTasks ()",
    .l "- (void)schedule:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)complete:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "@end",
    .blank,
    b "static NSString *ELTaskKind(BGTask *task) {" [
        .l "if ([task isKindOfClass:BGProcessingTask.class]) return @\"processing\";",
        .l "if ([task isKindOfClass:BGAppRefreshTask.class]) return @\"refresh\";",
        .l "return @\"other\";"],
    .blank,
    .l "/// A submission's answer: `{\"ok\":true}`, or `{\"ok\":false,\"error\":…,\"code\":…,\"detail\":…}`.",
    b "static NSDictionary *ELSubmitted(NSError *error) {" [
        .l "if (!error) return @{@\"ok\": @YES};",
        .l "NSString *name = @\"unknown\";",
        b "if ([error.domain isEqualToString:BGTaskSchedulerErrorDomain]) {" [
            b "switch ((BGTaskSchedulerErrorCode)error.code) {" [
                .l "case BGTaskSchedulerErrorCodeUnavailable: name = @\"unavailable\"; break;",
                .l "case BGTaskSchedulerErrorCodeTooManyPendingTaskRequests: name = @\"tooManyPending\"; break;",
                .l "case BGTaskSchedulerErrorCodeNotPermitted: name = @\"notPermitted\"; break;",
                .l "case BGTaskSchedulerErrorCodeImmediateRunIneligible: name = @\"immediateRunIneligible\"; break;",
                .l "default: break;"]],
        .l "return @{@\"ok\": @NO, @\"error\": name, @\"code\": @(error.code), @\"detail\": error.localizedDescription ?: @\"\"};"],
    .blank,
    b "@implementation ELBackgroundTasks {" [
        .l "NSMutableSet<NSString *> *_registered;",
        .l "// launched and not yet completed, by identifier",
        .l "NSMutableDictionary<NSString *, BGTask *> *_running;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static ELBackgroundTasks *shared;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ shared = [ELBackgroundTasks new]; });",
        .l "return shared;"],
    .blank,
    b "- (instancetype)init {" [
        b "if ((self = [super init])) {" [
            .l "_registered = [NSMutableSet set];",
            .l "_running = [NSMutableDictionary dictionary];"],
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
            .blk [("@try {", [
                  .l "BOOL ok = [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:identifier usingQueue:dispatch_get_main_queue()",
                  .l "                                                             launchHandler:^(__kindof BGTask *task) { [self launched:task]; }];",
                  .l "if (ok) [_registered addObject:identifier];"]), ("} @catch (NSException *e) {", [
                  .l "NSLog(@\"bgtask: cannot register %@: %@\", identifier, e.reason);"])] "}"]],
    .blank,
    b "- (void)launched:(BGTask *)task {" [
        .l "NSString *identifier = task.identifier;",
        .l "NSDictionary *info = @{@\"id\": identifier, @\"kind\": ELTaskKind(task)};",
        .l "// a task of the same identifier still pending is over: iOS has launched its successor",
        .l "[self finish:_running[identifier] success:NO];",
        .l "_running[identifier] = task;",
        .l "__weak BGTask *weakTask = task;",
        b "task.expirationHandler = ^{" [
            .l "dispatch_async(dispatch_get_main_queue(), ^{ [self expired:weakTask info:info]; });"] "};",
        .l "[ELStore.shared system:@{@\"bgtask\": info}];"],
    .blank,
    .l "/// The app hears of the expiration and has a second to complete the task; after that the shell does.",
    b "- (void)expired:(BGTask *)task info:(NSDictionary *)info {" [
        .l "if (!task || _running[task.identifier] != task) return;",
        .l "[ELStore.shared system:@{@\"bgtaskExpired\": info}];",
        b "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{" [
            .l "[self finish:task success:NO];"] "});"],
    .blank,
    .l "/// Completes `task` if it is still the pending one of its identifier.",
    b "- (BOOL)finish:(nullable BGTask *)task success:(BOOL)success {" [
        .l "if (!task || _running[task.identifier] != task) return NO;",
        .l "[_running removeObjectForKey:task.identifier];",
        .l "task.expirationHandler = nil;",
        .l "[task setTaskCompletedWithSuccess:success];",
        .l "return YES;"],
    .blank,
    b "- (void)schedule:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "NSString *identifier = ELArgString(args, @\"id\");",
        .l "NSString *kind = ELArgString(args, @\"kind\") ?: @\"refresh\";",
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
              .l "p.requiresNetworkConnectivity = [ELArgNumber(args, @\"requiresNetwork\") boolValue];",
              .l "p.requiresExternalPower = [ELArgNumber(args, @\"requiresPower\") boolValue];",
              .l "request = p;"]), ("} else {", [
              .l "request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:identifier];"])] "}",
        .l "NSNumber *after = ELArgNumber(args, @\"after\");",
        .l "if (after) request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:after.doubleValue];",
        .l "BGTaskScheduler *scheduler = BGTaskScheduler.sharedScheduler;",
        .l "// one request per identifier: a new one replaces the last",
        .l "[scheduler cancelTaskRequestWithIdentifier:identifier];",
        .blk [("if (@available(iOS 27.0, *)) {", [
              .l "// the completion form reports every refusal; Apple asks for it off the main thread",
              b "dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{" [
                  b "[scheduler submitTaskRequest:request completionHandler:^(NSError *error) {" [
                      .l "NSDictionary *result = ELSubmitted(error);",
                      .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"] "}];"] "});"]), ("} else {", [
              .l "NSError *error = nil;",
              .pp "#pragma clang diagnostic push",
              .pp "#pragma clang diagnostic ignored \"-Wdeprecated-declarations\"",
              .l "BOOL ok = [scheduler submitTaskRequest:request error:&error];",
              .pp "#pragma clang diagnostic pop",
              .l "answer(ELSubmitted(ok ? nil : (error ?: [NSError errorWithDomain:BGTaskSchedulerErrorDomain code:BGTaskSchedulerErrorCodeUnavailable userInfo:nil])));"])] "}"],
    .blank,
    b "- (void)complete:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "BGTask *task = _running[ELArgString(args, @\"id\") ?: @\"\"];",
        .l "BOOL done = [self finish:task success:[ELArgNumber(args, @\"success\") boolValue]];",
        .l "answer(done ? @{@\"ok\": @YES} : @{@\"ok\": @NO, @\"error\": @\"notPending\"});"],
    .blank,
    .l "@end"]

end ElmShell
