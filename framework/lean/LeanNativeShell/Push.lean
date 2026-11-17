import Lean.Data.Json
import LeanNativeShell.ObjC

/-! # LeanNativeShell.Push: `LNPush`, in `LNCapabilities.m`

Apple's push notifications, for the `push.*` capabilities: the device's token (`push.register`), whether
notices may be shown and the question that asks (`push.permission`, `push.ask`), and a notice that arrives,
handed to the app as a system event and answered with `push.complete`.

**Only in an app that asks for it.** Apple reads a binary for the push delegate methods and writes to the
developer of one that has them and no push entitlement, so none of this is in an app whose manifest lists no
`push.*`: the class, the app delegate's three methods (a category on `LNAppDelegate`) and the
UserNotifications import are printed by `capsFileFor` only when a `push.*` capability is selected, as
CoreBluetooth is only with `ble.*`. `LNApp.m`, which every app has, reaches the class by its name at run time
(`NSClassFromString`) and does nothing when there is none.

**A notice received** (`application:didReceiveRemoteNotification:fetchCompletionHandler:`: the app in
front, or woken behind by a notice that carries `content-available`, which needs `UIBackgroundModes`
`remote-notification`) is the system event `{"push":{"tag","state","payload"}}`: `state` is `active`,
`inactive` or `background`, `payload` the notice's own dictionary with only what JSON can carry. iOS waits
about thirty seconds for the app to say it is done; the app answers `push.complete` with the `tag` and
`newData`, `noData` or `failed`. At twenty-four seconds the app is told `{"pushExpired":{"tag"}}`, and a
notice still pending a second later is answered by the shell with `failed`: a late `push.complete` is then
`notPending`. Each notice has its own tag (a serial), so an answer never ends another notice's wait.

**A notice that arrives while the app is in front** is `{"pushPresented":{"payload"}}`, and shows no
banner: the app is on the screen and has just been told. (If it also carries `content-available`, iOS
delivers it as a notice received as well, with its tag: an app that acts on both does the work once.)

**A notice tapped** is `{"pushOpened":{"payload"}}`, whether the app was running or the tap started it: the
shell is the notification centre's delegate from before launch ends (`registerLaunch`, called by `LNApp.m`).
A notice that woke the app and is then tapped arrives twice, once as received and once as opened.

**The token.** `push.register` asks Apple (`registerForRemoteNotifications`) and answers
`{"token":hex,"environment":"development"|"production"}`, the environment read from the app's own
`aps-environment` entitlement (which of Apple's two gateways the token is for). Without the entitlement it
answers `missingEntitlement` and asks Apple nothing. Apple may not answer at all (a first registration with
no network), so after thirty seconds the answer is `timeout`.

`PendingNotices` below is the same bookkeeping in Lean. The Objective-C is compiled by native-demo's builds.
**What has been run, by hand in the simulator (iOS 26.5, `xcrun simctl push`)**: the token; a notice arriving
with the app in front. **What has not**: a notice received behind (`received:completion:`, the tag, the
answer, the expiry). The simulator does not deliver one that way: it runs a plain background fetch for a
notice that carries `content-available`, which reaches no push method at all. That path, and a tap, wait for
a device. -/

namespace LeanNativeShell

set_option maxRecDepth 8000 in
def pushClass : List Stmt := [
    .l "/// Apple's push notifications (`push.*`). Declared here, not in LeanNativeShell.h: only an app that uses",
    .l "/// `push.*` has it, and `LNApp.m` finds it by name.",
    .l "@interface LNPush : NSObject <UNUserNotificationCenterDelegate>",
    .l "+ (instancetype)shared;",
    .l "- (void)registerLaunch;",
    .l "- (void)registered:(nullable NSData *)token error:(nullable NSError *)error;",
    .l "- (void)received:(NSDictionary *)userInfo completion:(void (^)(UIBackgroundFetchResult))completion;",
    .l "- (void)registerDevice:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)permission:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)ask:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)complete:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "@end",
    .blank,
    .l "/// What of a notice's dictionary JSON can carry: strings, numbers, nulls, and lists and dictionaries (by",
    .l "/// string keys) of them. Anything else (a date, data) is left out.",
    b "static id LNPushSafe(id value) {" [
        .l "if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] || value == NSNull.null) return value;",
        b "if ([value isKindOfClass:NSArray.class]) {" [
            .l "NSMutableArray *out = [NSMutableArray array];",
            .l "for (id item in (NSArray *)value) { id safe = LNPushSafe(item); if (safe) [out addObject:safe]; }",
            .l "return out;"],
        b "if ([value isKindOfClass:NSDictionary.class]) {" [
            .l "NSMutableDictionary *out = [NSMutableDictionary dictionary];",
            b "[(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id item, BOOL *stop) {" [
                .l "id safe = [key isKindOfClass:NSString.class] ? LNPushSafe(item) : nil;",
                .l "if (safe) out[key] = safe;"] "}];",
            .l "return out;"],
        .l "return nil;"],
    .blank,
    b "@implementation LNPush {" [
        .l "// the answers waiting on Apple's word about the token, and which asking they belong to",
        .l "NSMutableArray<LNAnswer> *_registering;",
        .l "unsigned long long _asking;",
        .l "// notices received and not yet answered, by tag (`PendingNotices`); the last tag given, the first is 1",
        .l "NSMutableDictionary<NSNumber *, void (^)(UIBackgroundFetchResult)> *_pending;",
        .l "unsigned long long _serial;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static LNPush *shared;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ shared = [LNPush new]; });",
        .l "return shared;"],
    .blank,
    b "- (instancetype)init {" [
        b "if ((self = [super init])) {" [
            .l "_registering = [NSMutableArray array];",
            .l "_pending = [NSMutableDictionary dictionary];"],
        .l "return self;"],
    .blank,
    .l "/// Before launch ends: a tap on a notice that starts the app is delivered to the delegate set by then.",
    b "- (void)registerLaunch {" [
        .l "UNUserNotificationCenter.currentNotificationCenter.delegate = self;"],
    .blank,
    .l "/// Which of Apple's gateways the app's tokens are for, from its own entitlement; nil without one. (A Mac",
    .l "/// Catalyst build's key has the `com.apple.developer.` prefix.)",
    b "- (nullable NSString *)environment {" [
        .l "NSDictionary *entitlements = LNEntitlements();",
        .l "id value = entitlements[@\"aps-environment\"] ?: entitlements[@\"com.apple.developer.aps-environment\"];",
        .l "return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0 ? value : nil;"],
    .blank,
    b "- (void)registerDevice:(NSDictionary *)args answer:(LNAnswer)answer {" [
        b "if (![self environment]) {" [
            .l "answer(@{@\"error\": @\"missingEntitlement\", @\"detail\": @\"the app has no aps-environment entitlement\"});",
            .l "return;"],
        .l "[_registering addObject:[answer copy]];",
        .l "if (_registering.count > 1) return;",
        .l "unsigned long long asking = ++_asking;",
        .l "[UIApplication.sharedApplication registerForRemoteNotifications];",
        .l "// Apple may say nothing at all (a first registration with no network)",
        b "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{" [
            .l "if (self->_asking == asking && self->_registering.count > 0) [self answerRegistering:@{@\"error\": @\"timeout\", @\"detail\": @\"Apple did not answer in thirty seconds\"}];"] "});"],
    .blank,
    b "- (void)answerRegistering:(NSDictionary *)result {" [
        .l "NSArray<LNAnswer> *waiting = [_registering copy];",
        .l "[_registering removeAllObjects];",
        .l "_asking++;",
        .l "for (LNAnswer answer in waiting) answer(result);"],
    .blank,
    b "- (void)registered:(nullable NSData *)token error:(nullable NSError *)error {" [
        b "if (token.length > 0) {" [
            .l "[self answerRegistering:@{@\"token\": LNHexOf(token), @\"environment\": [self environment] ?: @\"\"}];",
            .l "return;"],
        .l "[self answerRegistering:@{@\"error\": @\"failed\", @\"code\": @(error.code), @\"detail\": error.localizedDescription ?: @\"\"}];"],
    .blank,
    b "- (void)permission:(NSDictionary *)args answer:(LNAnswer)answer {" [
        b "[UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {" [
            .l "NSString *status = @\"notDetermined\";",
            b "switch (settings.authorizationStatus) {" [
                .l "case UNAuthorizationStatusDenied: status = @\"denied\"; break;",
                .l "case UNAuthorizationStatusAuthorized: status = @\"authorized\"; break;",
                .l "case UNAuthorizationStatusProvisional: status = @\"provisional\"; break;",
                .pp "#if !TARGET_OS_MACCATALYST",
                .l "case UNAuthorizationStatusEphemeral: status = @\"ephemeral\"; break;",
                .pp "#endif",
                .l "default: break;"],
            .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(@{@\"status\": status}); });"] "}];"],
    .blank,
    .l "/// `push.ask`: the system's question, once (iOS shows it only the first time; after that the answer is the",
    .l "/// person's standing choice). Alerts, sounds and the badge unless `alert`, `sound` or `badge` is false.",
    b "- (void)ask:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "UNAuthorizationOptions options = 0;",
        .l "NSNumber *alert = LNArgNumber(args, @\"alert\"), *sound = LNArgNumber(args, @\"sound\"), *badge = LNArgNumber(args, @\"badge\");",
        .l "if (!alert || alert.boolValue) options |= UNAuthorizationOptionAlert;",
        .l "if (!sound || sound.boolValue) options |= UNAuthorizationOptionSound;",
        .l "if (!badge || badge.boolValue) options |= UNAuthorizationOptionBadge;",
        b "[UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:options completionHandler:^(BOOL granted, NSError *error) {" [
            .l "NSDictionary *result = error ? @{@\"granted\": @NO, @\"error\": @\"failed\", @\"code\": @(error.code), @\"detail\": error.localizedDescription ?: @\"\"}",
            .l "                             : @{@\"granted\": @(granted)};",
            .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"] "}];"],
    .blank,
    b "- (void)received:(NSDictionary *)userInfo completion:(void (^)(UIBackgroundFetchResult))completion {" [
        .l "NSNumber *tag = @(++_serial);",
        .l "_pending[tag] = [completion copy];",
        .l "NSString *state = @\"background\";",
        b "switch (UIApplication.sharedApplication.applicationState) {" [
            .l "case UIApplicationStateActive: state = @\"active\"; break;",
            .l "case UIApplicationStateInactive: state = @\"inactive\"; break;",
            .l "default: break;"],
        .l "[LNStore.shared system:@{@\"push\": @{@\"tag\": tag, @\"state\": state, @\"payload\": LNPushSafe(userInfo) ?: @{}}}];",
        .l "// iOS waits about thirty seconds. At twenty-four the app is told; a second later the shell answers",
        b "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(24 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{" [
            .l "if (!self->_pending[tag]) return;",
            .l "[LNStore.shared system:@{@\"pushExpired\": @{@\"tag\": tag}}];",
            b "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{" [
                .l "[self finish:tag result:UIBackgroundFetchResultFailed];"] "});"] "});"],
    .blank,
    .l "/// Answers the notice `tag` if it is still pending: iOS is answered once for each.",
    b "- (BOOL)finish:(NSNumber *)tag result:(UIBackgroundFetchResult)result {" [
        .l "void (^completion)(UIBackgroundFetchResult) = tag ? _pending[tag] : nil;",
        .l "if (!completion) return NO;",
        .l "[_pending removeObjectForKey:tag];",
        .l "completion(result);",
        .l "return YES;"],
    .blank,
    b "- (void)complete:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSString *said = LNArgString(args, @\"result\") ?: @\"noData\";",
        .l "UIBackgroundFetchResult result = [said isEqualToString:@\"newData\"] ? UIBackgroundFetchResultNewData",
        .l "    : [said isEqualToString:@\"failed\"] ? UIBackgroundFetchResultFailed : UIBackgroundFetchResultNoData;",
        .l "BOOL done = [self finish:LNArgNumber(args, @\"tag\") result:result];",
        .l "answer(done ? @{@\"ok\": @YES} : @{@\"ok\": @NO, @\"error\": @\"notPending\"});"],
    .blank,
    .l "/// A notice arriving with the app in front: the app is told, and nothing is shown.",
    .l "- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification",
    b "         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {" [
        .l "NSDictionary *userInfo = notification.request.content.userInfo;",
        b "dispatch_async(dispatch_get_main_queue(), ^{" [
            .l "[LNStore.shared system:@{@\"pushPresented\": @{@\"payload\": LNPushSafe(userInfo) ?: @{}}}];",
            .l "completionHandler(UNNotificationPresentationOptionNone);"] "});"],
    .blank,
    .l "/// A notice tapped (not one dismissed), with the app running or started by the tap.",
    .l "- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response",
    b "         withCompletionHandler:(void (^)(void))completionHandler {" [
        .l "NSDictionary *userInfo = response.notification.request.content.userInfo;",
        .l "BOOL tapped = [response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier];",
        b "dispatch_async(dispatch_get_main_queue(), ^{" [
            .l "if (tapped) [LNStore.shared system:@{@\"pushOpened\": @{@\"payload\": LNPushSafe(userInfo) ?: @{}}}];",
            .l "completionHandler();"] "});"],
    .blank,
    .l "@end",
    .blank,
    .l "/// The app delegate's part, only in an app that uses `push.*` (Apple reads the binary for these methods).",
    .l "@interface LNAppDelegate (LNPush)",
    .l "@end",
    .blank,
    .l "@implementation LNAppDelegate (LNPush)",
    .blank,
    b "- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {" [
        .l "[LNPush.shared registered:deviceToken error:nil];"],
    .blank,
    b "- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {" [
        .l "[LNPush.shared registered:nil error:error];"],
    .blank,
    .l "- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo",
    b "    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {" [
        .l "[LNPush.shared received:userInfo completion:completionHandler];"],
    .blank,
    .l "@end"]

/-! ## `PendingNotices`: the shell's bookkeeping, in Lean -/

/-- What `LNPush` keeps of the notices received: the tags still waiting for the app's answer, and the last
tag given. -/
structure PendingNotices where
  pending : List Nat := []
  serial : Nat := 0
  deriving Repr, BEq, Inhabited

namespace PendingNotices

/-- `received:completion:`: the notice's tag. -/
def received (s : PendingNotices) : PendingNotices × Nat :=
  let tag := s.serial + 1
  ({ pending := tag :: s.pending, serial := tag }, tag)

/-- `finish:result:` (`push.complete`, or the shell's own answer once the time is up): whether the notice was
still pending, which is whether iOS is answered now. -/
def finish (s : PendingNotices) (tag : Nat) : PendingNotices × Bool :=
  if s.pending.contains tag then ({ s with pending := s.pending.filter (· != tag) }, true) else (s, false)

/-- The system event of a notice received, as `received:completion:` posts it. -/
def event (tag : Nat) (state : String) (payload : Lean.Json) : Lean.Json :=
  Lean.Json.mkObj [("push", Lean.Json.mkObj [("tag", Lean.toJson tag), ("state", Lean.Json.str state), ("payload", payload)])]

/-- A notice is answered once: a second `finish` of its tag finds nothing pending. -/
theorem finish_once (s : PendingNotices) (tag : Nat) : ((s.finish tag).1.finish tag).2 = false := by
  unfold finish
  split <;> simp_all [List.contains_eq_mem, List.mem_filter]

/-- A notice just received is pending under a tag no notice had before, and answering it leaves every other
pending notice as it was. -/
theorem received_is_pending (s : PendingNotices) : (s.received.1.finish s.received.2).2 = true := by
  simp [received, finish]

end PendingNotices

end LeanNativeShell
