import ElmShell.ObjC
import ElmShell.BackgroundTasks
import ElmShell.CloudKit

/-! # ElmShell.Capabilities: `ELCapabilities.m`

The `ble.*` rows are generic Bluetooth Low Energy (GATT) by service and characteristic UUID, run by the
`ELBluetooth` class printed here; framing and UUIDs are the app's. An app that uses them declares
`NSBluetoothAlwaysUsageDescription` in its Info.plist.

One row per capability: its name, the documentation of its arguments and result (printed as the table in
the header's doc comment on `ELCapabilities`), and the Objective-C that runs it, which answers through
`answer`. The dispatch on the name is printed from the same rows, so a documented capability is a handled
one. -/

namespace ElmShell

structure Capability where
  name : String
  args : String
  result : String
  body : List Stmt

set_option maxRecDepth 8000 in
def capabilities : List Capability :=
[
  { name := "auth", args := "`reason`", result := "`{\"ok\":true}` or `{\"ok\":false,\"error\":…,\"name\":…,\"code\":…,\"domain\":…}` (device-owner authentication; `error` is the system's text, `name` and `code` the `LAError` (`domain` the error's, so a non-`LAError` answer, named `unknown`, can be told apart): `userCancel`, `systemCancel`, `appCancel`, `userFallback`, `authenticationFailed`, `biometryLockout`, `passcodeNotSet`, `biometryNotAvailable`, `biometryNotEnrolled`, `notInteractive`, `invalidContext` or `unknown`)",
    body := [
      .l "LAContext *context = [LAContext new];",
      .l "NSError *unable = nil;",
      b "if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&unable]) {" [
          .pp "#if TARGET_OS_SIMULATOR",
          .l "answer(@{@\"ok\": @YES, @\"note\": @\"simulator without a passcode\"});",
          .pp "#else",
          .l "answer(@{@\"ok\": @NO, @\"error\": @\"Set a device passcode first.\", @\"name\": ELAuthErrorName(unable), @\"code\": @(unable.code)});",
          .pp "#endif",
          .l "return;"],
      .l "NSString *reason = ELArgString(args, @\"reason\") ?: @\"Confirm\";",
      b "[context evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:reason reply:^(BOOL ok, NSError *error) {" [
          .l "NSDictionary *result = ok ? @{@\"ok\": @YES} : @{@\"ok\": @NO, @\"error\": error.localizedDescription ?: @\"Authentication failed.\",",
          .l "                                                @\"name\": ELAuthErrorName(error), @\"code\": @(error.code), @\"domain\": error.domain ?: @\"\"};",
          .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"] "}];"] },
  { name := "keychain.get", args := "`key`, `service`?, `synchronizable`?, `hex`?",
    result := "`{\"value\":…,\"status\":…}` or `{\"value\":null,\"status\":…}` (`service` defaults to the bundle id; `status` is the `OSStatus`: `-25300` for no such item); with `hex`, `{\"hex\":…|null,\"status\":…}`: the raw bytes",
    body := [
      .l "NSMutableDictionary *query = [self base:args];",
      .l "query[(__bridge id)kSecReturnData] = @YES;",
      .l "if ([self synchronizable:args]) query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;",
      .l "CFTypeRef out = NULL;",
      .l "OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &out);",
      .l "NSData *data = status == errSecSuccess ? (__bridge_transfer NSData *)out : nil;",
      b "if ([ELArgNumber(args, @\"hex\") boolValue]) {" [
          .l "answer(@{@\"hex\": data ? ELHexOf(data) : NSNull.null, @\"status\": @(status)});",
          .l "return;"],
      .l "NSString *s = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;",
      .l "answer(@{@\"value\": s ?: NSNull.null, @\"status\": @(status)});"] },
  { name := "keychain.add", args := "`key`, `value` or `hex`, `service`?, `synchronizable`?",
    result := "`{\"ok\":…,\"status\":…,\"exists\":…}`: creates the item only if there is none (one `SecItemAdd`; `-25299`, `errSecDuplicateItem`, with `exists` when there is, and the item is untouched); protection as `keychain.set`",
    body := [
      .l "NSString *hex = ELArgString(args, @\"hex\");",
      .l "NSData *data = hex ? ELDataOf(hex) : [(ELArgString(args, @\"value\") ?: @\"\") dataUsingEncoding:NSUTF8StringEncoding];",
      .l "if (!data) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam), @\"exists\": @NO}); return; }",
      .l "NSMutableDictionary *query = [self base:args];",
      .l "query[(__bridge id)kSecValueData] = data;",
      .l "query[(__bridge id)kSecAttrAccessible] = [self synchronizable:args] ? (__bridge id)kSecAttrAccessibleWhenUnlocked",
      .l "                                                                    : (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;",
      .l "// no delete first: the Keychain refuses a second item of the same name, so racing adds cannot both succeed",
      .l "OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess)), @\"status\": @(status), @\"exists\": @((BOOL)(status == errSecDuplicateItem))});"] },
  { name := "keychain.set", args := "`key`, `value` or `hex`, `service`?, `synchronizable`?",
    result := "`{\"ok\":…,\"status\":…}` (the `OSStatus`; `-50` for bad hex); this device only, while unlocked; with `synchronizable`, iCloud Keychain (`kSecAttrSynchronizable`), while unlocked",
    body := [
      .l "NSString *hex = ELArgString(args, @\"hex\");",
      .l "NSData *data = hex ? ELDataOf(hex) : [(ELArgString(args, @\"value\") ?: @\"\") dataUsingEncoding:NSUTF8StringEncoding];",
      .l "if (!data) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam)}); return; }",
      .l "SecItemDelete((__bridge CFDictionaryRef)[self base:args]);",
      .l "NSMutableDictionary *query = [self base:args];",
      .l "query[(__bridge id)kSecValueData] = data;",
      .l "// an item that syncs cannot be this-device-only",
      .l "query[(__bridge id)kSecAttrAccessible] = [self synchronizable:args] ? (__bridge id)kSecAttrAccessibleWhenUnlocked",
      .l "                                                                    : (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;",
      .l "OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess)), @\"status\": @(status)});"] },
  { name := "keychain.delete", args := "`key`, `service`?, `synchronizable`?", result := "`{\"ok\":…,\"status\":…}`",
    body := [
      .l "OSStatus status = SecItemDelete((__bridge CFDictionaryRef)[self base:args]);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess || status == errSecItemNotFound)), @\"status\": @(status)});"] },
  { name := "keychain.clear", args := "`service`, `synchronizable`?", result := "`{\"ok\":…,\"status\":…}` deletes every item of that service (a test namespace's reset); with `synchronizable`, its iCloud Keychain items instead",
    body := [
      .l "NSString *service = ELArgString(args, @\"service\");",
      .l "if (service.length == 0) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam)}); return; }",
      .l "NSMutableDictionary *query = [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,",
      .l "                                (__bridge id)kSecAttrService: service} mutableCopy];",
      .l "if ([self synchronizable:args]) query[(__bridge id)kSecAttrSynchronizable] = @YES;",
      .l "OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess || status == errSecItemNotFound)), @\"status\": @(status)});"] },
  { name := "build", args := "—", result := "`{\"debug\":…}` whether this is a Debug build (`#if DEBUG`): test hooks stay off in Release",
    body := [
      .pp "#if DEBUG",
      .l "answer(@{@\"debug\": @YES});",
      .pp "#else",
      .l "answer(@{@\"debug\": @NO});",
      .pp "#endif"] },
  { name := "clipboard.set", args := "`text`, `localOnly`, `expiresIn` (s)", result := "`{\"ok\":true}`",
    body := [
      .l "// `localOnly` keeps it off Universal Clipboard; `expiresIn` (seconds) clears it afterwards",
      .l "NSMutableDictionary *options = [NSMutableDictionary dictionary];",
      .l "if ([ELArgNumber(args, @\"localOnly\") boolValue]) options[UIPasteboardOptionLocalOnly] = @YES;",
      .l "NSNumber *seconds = ELArgNumber(args, @\"expiresIn\");",
      .l "if (seconds) options[UIPasteboardOptionExpirationDate] = [NSDate dateWithTimeIntervalSinceNow:seconds.doubleValue];",
      .l "[UIPasteboard.generalPasteboard setItems:@[@{UIPasteboardTypeAutomatic: ELArgString(args, @\"text\") ?: @\"\"}] options:options];",
      .l "answer(@{@\"ok\": @YES});"] },
  { name := "clipboard.get", args := "—", result := "`{\"text\":…}`",
    body := [
      .l "answer(@{@\"text\": UIPasteboard.generalPasteboard.string ?: NSNull.null});"] },
  { name := "documents", args := "—", result := "`{\"path\":…}` the app's Documents directory",
    body := [
      .l "NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;",
      .l "answer(@{@\"path\": docs.path ?: @\"\"});"] },
  { name := "paths", args := "—", result := "`{\"documents\",\"support\",\"tmp\"}`: Documents, Application Support (created), temporary",
    body := [
      .l "NSFileManager *fm = NSFileManager.defaultManager;",
      .l "NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;",
      .l "if (support) [fm createDirectoryAtURL:support withIntermediateDirectories:YES attributes:nil error:nil];",
      .l "NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;",
      .l "answer(@{@\"documents\": docs.path ?: @\"\", @\"support\": support.path ?: @\"\", @\"tmp\": fm.temporaryDirectory.path});"] },
  { name := "exclude-from-backup", args := "`path`, `complete`?", result := "`{\"ok\":…}` marks a file or directory as excluded from iCloud/device backup; with `complete`, also `NSFileProtectionComplete` (readable only while unlocked)",
    body := [
      .l "NSURL *url = [NSURL fileURLWithPath:ELArgString(args, @\"path\") ?: @\"\"];",
      .l "BOOL ok = [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];",
      .l "if (ok && [ELArgNumber(args, @\"complete\") boolValue])",
      .l "    ok = [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionComplete} ofItemAtPath:url.path error:nil];",
      .l "answer(@{@\"ok\": @(ok)});"] },
  { name := "http.get", args := "`url`, `maxBytes`, `timeout` (s), `accept`?, `socks`? (`{\"host\",\"port\"}`)",
    result := "`{\"status\":…,\"body\":hex}` or `{\"error\":…}` (`bad-url`, `bad-proxy`, `tooLarge`, `response`, or the system's description with its `code` and `domain`); ephemeral session, no cookies or cache, redirects only within the same host and never from https to http; with `socks`, through that SOCKS5 proxy only (names resolved by the proxy, no direct fallback)",
    body := [
      .l "NSURL *url = [NSURL URLWithString:ELArgString(args, @\"url\") ?: @\"\"];",
      .l "NSString *scheme = url.scheme.lowercaseString ?: @\"\";",
      .l "if (!url || !([scheme isEqualToString:@\"http\"] || [scheme isEqualToString:@\"https\"])) { answer(@{@\"error\": @\"bad-url\"}); return; }",
      .l "NSURLSession *session = [ELHTTPFetch session:args[@\"socks\"]];",
      .l "if (!session) { answer(@{@\"error\": @\"bad-proxy\"}); return; }",
      .l "NSInteger maxBytes = ELArgNumber(args, @\"maxBytes\") ? [ELArgNumber(args, @\"maxBytes\") integerValue] : 1000000;",
      .l "NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];",
      .l "BOOL proxied = args[@\"socks\"] && args[@\"socks\"] != NSNull.null;",
      .l "request.timeoutInterval = ELArgNumber(args, @\"timeout\") ? [ELArgNumber(args, @\"timeout\") doubleValue] : (proxied ? 90 : 30);",
      .l "NSString *accept = ELArgString(args, @\"accept\");",
      .l "if (accept) [request setValue:accept forHTTPHeaderField:@\"Accept\"];",
      b "[[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {" [
          .l "NSDictionary *result;",
          .blk [("if (error) {", [
                .l "result = @{@\"error\": error.localizedDescription ?: @\"\", @\"code\": @(error.code), @\"domain\": error.domain ?: @\"\"};"]), ("} else if ([response isKindOfClass:NSHTTPURLResponse.class] && data) {", [
                .blk [("if ((NSInteger)data.length > maxBytes) {", [
                      .l "result = @{@\"error\": @\"tooLarge\"};"]), ("} else {", [
                      .l "NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];",
                      .l "const unsigned char *bytes = data.bytes;",
                      .l "for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@\"%02x\", bytes[i]];",
                      .l "result = @{@\"status\": @(((NSHTTPURLResponse *)response).statusCode), @\"body\": hex};"])] "}"]), ("} else {", [
                .l "result = @{@\"error\": @\"response\"};"])] "}",
          .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"] "}] resume];"] },
  { name := "open", args := "`url`", result := "`{\"ok\":…}` opens the URL outside the app",
    body := [
      .l "NSURL *url = [NSURL URLWithString:ELArgString(args, @\"url\") ?: @\"\"];",
      .blk [("if (url) {", [
            .l "[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];",
            .l "answer(@{@\"ok\": @YES});"]), ("} else {", [
            .l "answer(@{@\"ok\": @NO});"])] "}"] },
  { name := "ble.state", args := "—",
    result := "`{\"state\":…}`: `poweredOn`, `poweredOff`, `unauthorized`, `unsupported`, `resetting` or `unknown`",
    body := [.l "[[ELBluetooth shared] state:answer];"] },
  { name := "ble.connect", args := "`services` (UUIDs), `timeout`? (s, 45)",
    result := "`{\"ok\":true,\"id\",\"service\",\"characteristics\"}` for the first peripheral offering one of the services (one the system already holds connected, else the first found by a scan), or `{\"ok\":false,\"error\":…}` (a Bluetooth state, `timeout`, `refused`, `busy`, …)",
    body := [.l "[[ELBluetooth shared] connect:args answer:answer];"] },
  { name := "ble.subscribe", args := "`id`, `characteristic`, `timeout`? (s, 90)",
    result := "`{\"ok\":…}` once notifications are on: iOS pairs on the first encrypted access, so this can wait on the user",
    body := [.l "[[ELBluetooth shared] subscribe:args answer:answer];"] },
  { name := "ble.write", args := "`id`, `characteristic`, `hex`, `response`? (true), `timeout`? (s, 15)",
    result := "`{\"ok\":…}`; with `response`, after the peripheral acknowledges",
    body := [.l "[[ELBluetooth shared] write:args answer:answer];"] },
  { name := "ble.read", args := "`id`, `characteristic`, `timeout`? (s, 30)",
    result := "`{\"hex\":…}`: the next notified value, in arrival order per characteristic; or `{\"error\":\"timeout\"|\"disconnected\"}`",
    body := [.l "[[ELBluetooth shared] read:args answer:answer];"] },
  { name := "ble.close", args := "`id`",
    result := "`{\"ok\":true}` disconnects; requests waiting on the peripheral fail with `disconnected`",
    body := [.l "[[ELBluetooth shared] close:args answer:answer];"] },
  { name := "bgtask.schedule", args := "`id`, `kind`? (`refresh` or `processing`; `refresh`), `after`? (s from now), `requiresNetwork`?, `requiresPower`? (processing only)",
    result := "`{\"ok\":true}` or `{\"ok\":false,\"error\",\"detail\",\"code\"?}` (`unavailable`, `tooManyPending`, `notPermitted`, `immediateRunIneligible`, `badArgs`, `unknown`); replaces any request of that `id`, which must be in Info.plist's `BGTaskSchedulerPermittedIdentifiers`. iOS decides when, and whether, it runs; under Mac Catalyst every request answers `unavailable`",
    body := [.l "[ELBackgroundTasks.shared schedule:args answer:answer];"] },
  { name := "bgtask.complete", args := "`id`, `success`",
    result := "`{\"ok\":true}`, or `{\"ok\":false,\"error\":\"notPending\"}` when no task of that `id` is running (never launched, completed, or completed by the shell a second after it expired)",
    body := [.l "[ELBackgroundTasks.shared complete:args answer:answer];"] },
  { name := "bgtask.refreshStatus", args := "—",
    result := "`{\"status\":…}`: `available`, `denied` (Background App Refresh off for the app) or `restricted`",
    body := [
      b "switch (UIApplication.sharedApplication.backgroundRefreshStatus) {" [
          .l "case UIBackgroundRefreshStatusAvailable: answer(@{@\"status\": @\"available\"}); break;",
          .l "case UIBackgroundRefreshStatusDenied: answer(@{@\"status\": @\"denied\"}); break;",
          .l "default: answer(@{@\"status\": @\"restricted\"}); break;"]] },
  { name := "cloudkit.account", args := "`container`? (an identifier; the app's default container)",
    result := "`{\"status\":…,\"user\":…}`: `available` (with `user`, the account's record name), `noAccount`, `restricted`, `couldNotDetermine` or `temporarilyUnavailable` (`user` null); or an error. Every `cloudkit.*` error is `{\"error\",\"code\",\"detail\",\"retryAfter\"?}`, named as `CKErrorCode` (`notAuthenticated`, `networkUnavailable`, `quotaExceeded`, `serverRecordChanged`, …; `notFound` for an unknown item), or `missingEntitlement` without the iCloud entitlement, `badArgs`",
    body := [.l "[ELCloudKit.shared account:args answer:answer];"] },
  { name := "cloudkit.query", args := "`type`, `equals`? (`{field: value}`, all must hold), `sortBy`?, `ascending`? (true), `keys`? (fields to fetch; all), `limit`? (100, at most 500), `container`?",
    result := "`{\"records\":[{\"name\",\"type\",\"fields\",\"modified\",\"tag\"}…],\"more\":…}` from the private database, following cursors up to `limit`. A field is a string, a number, `{\"date\":s}` (since 1970), `{\"hex\":…}` (bytes), a list of those, `{\"asset\":true}` or `{\"ref\":name}`",
    body := [.l "[ELCloudKit.shared query:args answer:answer];"] },
  { name := "cloudkit.save", args := "`type`, `name` (the record name), `fields`? (as in a query), `asset`? (hex), `assetField`? (`asset`), `container`?",
    result := "`{\"ok\":true,\"record\":…}`: the record made or updated, only the given fields changed (`changedKeys`, atomic); the asset goes up from a temporary file with complete protection, removed afterwards",
    body := [.l "[ELCloudKit.shared save:args answer:answer];"] },
  { name := "cloudkit.load", args := "`name`, `maxBytes`? (of the asset; 32 MiB), `assetField`? (`asset`), `container`?",
    result := "`{\"record\":…,\"asset\":hex|null}`, or `{\"error\":\"notFound\"…}`, `{\"error\":\"tooLarge\"}`",
    body := [.l "[ELCloudKit.shared load:args answer:answer];"] },
  { name := "cloudkit.delete", args := "`name`, `container`?",
    result := "`{\"ok\":true}` (also when there was no such record), or an error",
    body := [.l "[ELCloudKit.shared remove:args answer:answer];"] } ]


def unknownCapability : List Stmt := [
    .l "answer(@{@\"error\": [NSString stringWithFormat:@\"unknown capability %@\", name]});"]

def capabilitiesDoc : List String :=
  [ "What only iOS can do, offered to every ElmLean native app by name. The app asks with",
    "`Effects.cap name args`; the answer goes back as JSON. Nothing here knows the app.", "",
    "| name | args | result |", "|---|---|---|" ] ++
  capabilities.map fun c => s!"| `{c.name}` | {c.args} | {c.result} |"

set_option maxRecDepth 8000 in
def capsBefore : List Stmt := [
    .pp "#import \"ElmLeanShell.h\"",
    .pp "#import <LocalAuthentication/LocalAuthentication.h>",
    .pp "#import <Security/Security.h>",
    .pp "#import <CoreBluetooth/CoreBluetooth.h>",
    .pp "#import <Network/Network.h>",
    .pp "#import <Network/NSURLSession+Network.h>",
    .pp "#import <BackgroundTasks/BackgroundTasks.h>",
    .pp "#import <CloudKit/CloudKit.h>",
    .pp "#import <mach-o/dyld.h>",
    .pp "#import <mach-o/getsect.h>",
    .pp "#import <mach-o/loader.h>",
    .blank,
    .l "/// An `LAError`'s name for `auth` (`unknown` for any other error, or none).",
    b "static NSString *ELAuthErrorName(NSError *error) {" [
        .l "if (![error.domain isEqualToString:LAErrorDomain]) return @\"unknown\";",
        b "switch ((LAError)error.code) {" [
            .l "case LAErrorAuthenticationFailed: return @\"authenticationFailed\";",
            .l "case LAErrorUserCancel: return @\"userCancel\";",
            .l "case LAErrorUserFallback: return @\"userFallback\";",
            .l "case LAErrorSystemCancel: return @\"systemCancel\";",
            .l "case LAErrorPasscodeNotSet: return @\"passcodeNotSet\";",
            .l "case LAErrorAppCancel: return @\"appCancel\";",
            .l "case LAErrorInvalidContext: return @\"invalidContext\";",
            .l "case LAErrorNotInteractive: return @\"notInteractive\";",
            .l "case LAErrorBiometryNotAvailable: return @\"biometryNotAvailable\";",
            .l "case LAErrorBiometryNotEnrolled: return @\"biometryNotEnrolled\";",
            .l "case LAErrorBiometryLockout: return @\"biometryLockout\";",
            .l "default: return @\"unknown\";"]],
    .blank,
    .l "/// The ephemeral URLSessions of `http.get`: no cookies, no cache, redirects only within the same host and",
    .l "/// never from https down to http. One shared session without a proxy, and one per SOCKS5 proxy (`host:port`),",
    .l "/// kept for the life of the app (a session is never invalidated while a request might still use it).",
    .l "@interface ELHTTPFetch : NSObject <NSURLSessionTaskDelegate>",
    .l "+ (nullable NSURLSession *)session:(nullable id)socks;",
    .l "@end",
    .blank,
    .l "@implementation ELHTTPFetch",
    .blank,
    b "+ (NSURLSessionConfiguration *)configuration {" [
        .l "NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];",
        .l "config.HTTPShouldSetCookies = NO;",
        .l "config.HTTPCookieStorage = nil;",
        .l "config.URLCache = nil;",
        .l "config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;",
        .l "config.timeoutIntervalForResource = 120;",
        .l "return config;"],
    .blank,
    .l "/// The session for a request: the shared one when `socks` is absent, else the one for that proxy",
    .l "/// (`{\"host\":…,\"port\":…}`); nil when `socks` is not a host and a port in 1…65535.",
    b "+ (nullable NSURLSession *)session:(nullable id)socks {" [
        .l "static NSURLSession *direct;",
        .l "static NSMutableDictionary<NSString *, NSURLSession *> *proxied;",
        .l "static dispatch_once_t once;",
        b "dispatch_once(&once, ^{" [
            .l "direct = [NSURLSession sessionWithConfiguration:[self configuration] delegate:[ELHTTPFetch new] delegateQueue:nil];",
            .l "proxied = [NSMutableDictionary dictionary];"] "});",
        .l "if (!socks || socks == NSNull.null) return direct;",
        .l "if (![socks isKindOfClass:NSDictionary.class]) return nil;",
        .l "NSString *host = ELArgString(socks, @\"host\");",
        .l "NSNumber *port = ELArgNumber(socks, @\"port\");",
        .l "if (host.length == 0 || !port || port.doubleValue != (double)port.integerValue || port.integerValue < 1 || port.integerValue > 65535) return nil;",
        .l "NSString *key = [NSString stringWithFormat:@\"%@:%ld\", host, (long)port.integerValue];",
        b "@synchronized (proxied) {" [
            .l "NSURLSession *session = proxied[key];",
            .l "if (session) return session;",
            .l "NSURLSessionConfiguration *config = [self configuration];",
            .l "// a SOCKS5 proxy with the hostname sent to it (the proxy resolves it), and no direct fallback",
            .l "nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, [NSString stringWithFormat:@\"%ld\", (long)port.integerValue].UTF8String);",
            .l "nw_proxy_config_t proxy = nw_proxy_config_create_socksv5(endpoint);",
            .l "nw_proxy_config_set_failover_allowed(proxy, false);",
            .l "config.proxyConfigurations = @[proxy];",
            .l "// a proxy (Tor, say) is slower than a direct connection",
            .l "config.timeoutIntervalForRequest = 90;",
            .l "config.timeoutIntervalForResource = 180;",
            .l "session = [NSURLSession sessionWithConfiguration:config delegate:[ELHTTPFetch new] delegateQueue:nil];",
            .l "proxied[key] = session;",
            .l "return session;"]],
    .blank,
    .l "- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response",
    b "        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {" [
        .l "NSURL *to = request.URL, *from = response.URL;",
        .l "BOOL sameHost = to.host && from.host && [to.host.lowercaseString isEqualToString:from.host.lowercaseString];",
        .l "BOOL downgrade = [from.scheme isEqualToString:@\"https\"] && ![to.scheme isEqualToString:@\"https\"];",
        .l "completionHandler(sameHost && !downgrade ? request : nil);"],
    .blank,
    .l "@end",
    .blank,
    .l "@implementation ELCapabilities",
    .blank,
    .l "/// Whether a keychain request is about iCloud Keychain items (`synchronizable`: true).",
    b "- (BOOL)synchronizable:(NSDictionary *)args {" [
        .l "return [ELArgNumber(args, @\"synchronizable\") boolValue];"],
    .blank,
    .l "/// The item named by `key` within `service` (the app's bundle id unless the app names one). Without",
    .l "/// `synchronizable` the query names no kSecAttrSynchronizable, so it matches this device's items only; with",
    .l "/// it, only iCloud Keychain items.",
    b "- (NSMutableDictionary *)base:(NSDictionary *)args {" [
        .l "NSString *service = ELArgString(args, @\"service\") ?: (NSBundle.mainBundle.bundleIdentifier ?: @\"elmlean\");",
        .l "NSMutableDictionary *query = [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,",
        .l "                                (__bridge id)kSecAttrAccount: ELArgString(args, @\"key\") ?: @\"\"} mutableCopy];",
        .l "if ([self synchronizable:args]) query[(__bridge id)kSecAttrSynchronizable] = @YES;",
        .l "return query;"],
    .blank]

/-- The arguments of a request, by kind (nil when absent or of another JSON kind). -/
def argHelpers : List Stmt := [
    b "static NSString *ELArgString(NSDictionary *args, NSString *k) {" [
        .l "return [args[k] isKindOfClass:NSString.class] ? args[k] : nil;"],
    .blank,
    b "static NSNumber *ELArgNumber(NSDictionary *args, NSString *k) {" [
        .l "return [args[k] isKindOfClass:NSNumber.class] ? args[k] : nil;"],
    .blank,
    ]

set_option maxRecDepth 8000 in
def bluetoothClass : List Stmt := [
    .l "/// Bluetooth Low Energy (GATT) for the `ble.*` capabilities: generic, by service and characteristic UUIDs;",
    .l "/// what the bytes mean is the app's. One central manager, made on the first `ble.*` request so that an app",
    .l "/// that never uses Bluetooth never asks for it. Callbacks arrive on the main queue, like every answer.",
    .l "typedef void (^ELAnswer)(NSDictionary *result);",
    .blank,
    .l "@interface ELBluetooth : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>",
    .l "+ (instancetype)shared;",
    .l "- (void)state:(ELAnswer)answer;",
    .l "- (void)connect:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)subscribe:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)write:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)read:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)close:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "@end",
    .blank,
    .l "/// Lowercase hex of some bytes, and back (nil unless every character is a hex digit and they pair up).",
    b "static NSString *ELHexOf(NSData *data) {" [
        .l "static const char digits[] = \"0123456789abcdef\";",
        .l "const unsigned char *bytes = data.bytes;",
        .l "NSMutableData *out = [NSMutableData dataWithLength:data.length * 2];",
        .l "char *p = out.mutableBytes;",
        .l "for (NSUInteger i = 0; i < data.length; i++) { p[2 * i] = digits[bytes[i] >> 4]; p[2 * i + 1] = digits[bytes[i] & 15]; }",
        .l "return [[NSString alloc] initWithData:out encoding:NSASCIIStringEncoding] ?: @\"\";"],
    .blank,
    b "static int ELNibble(unichar c) {" [
        .l "if (c >= '0' && c <= '9') return c - '0';",
        .l "if (c >= 'a' && c <= 'f') return c - 'a' + 10;",
        .l "if (c >= 'A' && c <= 'F') return c - 'A' + 10;",
        .l "return -1;"],
    .blank,
    b "static NSData *ELDataOf(NSString *hex) {" [
        .l "if (hex.length % 2 != 0) return nil;",
        .l "NSMutableData *data = [NSMutableData dataWithLength:hex.length / 2];",
        .l "unsigned char *bytes = data.mutableBytes;",
        b "for (NSUInteger i = 0; i < hex.length; i += 2) {" [
            .l "int hi = ELNibble([hex characterAtIndex:i]), lo = ELNibble([hex characterAtIndex:i + 1]);",
            .l "if (hi < 0 || lo < 0) return nil;",
            .l "bytes[i / 2] = (unsigned char)(hi << 4 | lo);"],
        .l "return data;"],
    .blank,
    b "static NSString *ELStateName(CBManagerState state) {" [
        b "switch (state) {" [
            .l "case CBManagerStatePoweredOn: return @\"poweredOn\";",
            .l "case CBManagerStatePoweredOff: return @\"poweredOff\";",
            .l "case CBManagerStateUnauthorized: return @\"unauthorized\";",
            .l "case CBManagerStateUnsupported: return @\"unsupported\";",
            .l "case CBManagerStateResetting: return @\"resetting\";",
            .l "default: return @\"unknown\";"]],
    .blank,
    .l "/// A request waiting for a callback, with the deadline that answers it instead.",
    .l "@interface ELPending : NSObject",
    .l "@property (nonatomic, copy) ELAnswer answer;",
    .l "@property (nonatomic, strong) dispatch_block_t deadline;",
    .l "@end",
    .blank,
    .l "@implementation ELPending",
    .l "@end",
    .blank,
    b "@implementation ELBluetooth {" [
        .l "CBCentralManager *_central;",
        .l "NSMutableArray<void (^)(void)> *_whenReady;",
        .l "NSMutableDictionary<NSString *, CBPeripheral *> *_peripherals;",
        .l "// the connection being made: its services, its peripheral once found, its answer",
        .l "NSArray<CBUUID *> *_connectServices;",
        .l "CBPeripheral *_connecting;",
        .l "ELPending *_connect;",
        .l "// per \"peripheral id|characteristic uuid\": requests in flight, and notified values not yet read",
        .l "NSMutableDictionary<NSString *, ELPending *> *_subscribes;",
        .l "NSMutableDictionary<NSString *, NSMutableArray<ELPending *> *> *_writes;",
        .l "NSMutableDictionary<NSString *, NSMutableArray<ELPending *> *> *_reads;",
        .l "NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_values;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static ELBluetooth *shared;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ shared = [ELBluetooth new]; });",
        .l "return shared;"],
    .blank,
    b "- (instancetype)init {" [
        b "if ((self = [super init])) {" [
            .l "_whenReady = [NSMutableArray array];",
            .l "_peripherals = [NSMutableDictionary dictionary];",
            .l "_subscribes = [NSMutableDictionary dictionary];",
            .l "_writes = [NSMutableDictionary dictionary];",
            .l "_reads = [NSMutableDictionary dictionary];",
            .l "_values = [NSMutableDictionary dictionary];"],
        .l "return self;"],
    .blank,
    .l "/// Runs `then` once the central knows its state (made on first use), or after 5 s.",
    b "- (void)ready:(void (^)(void))then {" [
        .l "if (!_central) _central = [[CBCentralManager alloc] initWithDelegate:self queue:nil];",
        .l "if (_central.state != CBManagerStateUnknown && _central.state != CBManagerStateResetting) { then(); return; }",
        .l "[_whenReady addObject:then];",
        b "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{" [
            .l "if (![self->_whenReady containsObject:then]) return;",
            .l "[self->_whenReady removeObject:then];",
            .l "then();"] "});"],
    .blank,
    b "- (ELPending *)pending:(ELAnswer)answer timeout:(NSTimeInterval)seconds onTimeout:(void (^)(ELPending *p))expire {" [
        .l "ELPending *p = [ELPending new];",
        .l "p.answer = answer;",
        .l "__weak ELPending *weakP = p;",
        b "p.deadline = dispatch_block_create(0, ^{" [
            .l "ELPending *q = weakP;",
            .l "if (q) expire(q);"] "});",
        .l "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), p.deadline);",
        .l "return p;"],
    .blank,
    b "- (void)settle:(ELPending *)p with:(NSDictionary *)result {" [
        .l "if (p.deadline) dispatch_block_cancel(p.deadline);",
        .l "p.deadline = nil;",
        .l "p.answer(result);"],
    .blank,
    b "- (NSString *)key:(NSString *)peripheral characteristic:(CBUUID *)uuid {" [
        .l "return [NSString stringWithFormat:@\"%@|%@\", peripheral, uuid.UUIDString];"],
    .blank,
    b "- (CBCharacteristic *)characteristic:(CBUUID *)uuid of:(CBPeripheral *)peripheral {" [
        .l "for (CBService *service in peripheral.services)",
        .l "    for (CBCharacteristic *c in service.characteristics)",
        .l "        if ([c.UUID isEqual:uuid]) return c;",
        .l "return nil;"],
    .blank,
    b "static NSArray<CBUUID *> *ELUUIDs(id list) {" [
        .l "NSMutableArray *out = [NSMutableArray array];",
        .l "if ([list isKindOfClass:NSArray.class])",
        .l "    for (id s in list) if ([s isKindOfClass:NSString.class]) [out addObject:[CBUUID UUIDWithString:s]];",
        .l "return out;"],
    .blank,
    b "static NSTimeInterval ELSeconds(NSDictionary *args, NSString *k, NSTimeInterval dflt) {" [
        .l "return [args[k] isKindOfClass:NSNumber.class] ? [args[k] doubleValue] : dflt;"],
    .blank,
    b "- (void)state:(ELAnswer)answer {" [
        .l "[self ready:^{ answer(@{@\"state\": ELStateName(self->_central.state)}); }];"],
    .blank,
    b "- (void)connect:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "NSArray<CBUUID *> *services = ELUUIDs(args[@\"services\"]);",
        .l "if (services.count == 0) { answer(@{@\"ok\": @NO, @\"error\": @\"no-services\"}); return; }",
        .l "if (_connect) { answer(@{@\"ok\": @NO, @\"error\": @\"busy\"}); return; }",
        .l "NSTimeInterval timeout = ELSeconds(args, @\"timeout\", 45);",
        b "[self ready:^{" [
            b "if (self->_central.state != CBManagerStatePoweredOn) {" [
                .l "answer(@{@\"ok\": @NO, @\"error\": ELStateName(self->_central.state)});",
                .l "return;"],
            .l "self->_connectServices = services;",
            b "self->_connect = [self pending:answer timeout:timeout onTimeout:^(ELPending *p) {" [
                .l "[self->_central stopScan];",
                .l "if (self->_connecting) [self->_central cancelPeripheralConnection:self->_connecting];",
                .l "[self endConnect:@{@\"ok\": @NO, @\"error\": @\"timeout\"}];"] "}];",
            .l "// a peripheral the system already holds (paired and connected) is used as it is",
            .l "CBPeripheral *known = [self->_central retrieveConnectedPeripheralsWithServices:services].firstObject;",
            .l "if (known) [self attach:known];",
            .l "else [self->_central scanForPeripheralsWithServices:services options:nil];"] "}];"],
    .blank,
    b "- (void)attach:(CBPeripheral *)peripheral {" [
        .l "_connecting = peripheral;",
        .l "peripheral.delegate = self;",
        .l "[_central connectPeripheral:peripheral options:nil];"],
    .blank,
    b "- (void)endConnect:(NSDictionary *)result {" [
        .l "ELPending *p = _connect;",
        .l "_connect = nil;",
        .l "_connecting = nil;",
        .l "_connectServices = nil;",
        .l "if (p) [self settle:p with:result];"],
    .blank,
    b "- (void)subscribe:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "CBPeripheral *peripheral = _peripherals[args[@\"id\"] ?: @\"\"];",
        .l "CBUUID *uuid = [args[@\"characteristic\"] isKindOfClass:NSString.class] ? [CBUUID UUIDWithString:args[@\"characteristic\"]] : nil;",
        .l "CBCharacteristic *c = uuid ? [self characteristic:uuid of:peripheral] : nil;",
        .l "if (!c) { answer(@{@\"ok\": @NO, @\"error\": peripheral ? @\"no-characteristic\" : @\"disconnected\"}); return; }",
        .l "NSString *key = [self key:args[@\"id\"] characteristic:uuid];",
        .l "if (_subscribes[key]) { answer(@{@\"ok\": @NO, @\"error\": @\"busy\"}); return; }",
        .l "// the first encrypted access is where iOS pairs: the user may be comparing codes",
        b "_subscribes[key] = [self pending:answer timeout:ELSeconds(args, @\"timeout\", 90) onTimeout:^(ELPending *p) {" [
            .l "[self->_subscribes removeObjectForKey:key];",
            .l "[self settle:p with:@{@\"ok\": @NO, @\"error\": @\"timeout\"}];"] "}];",
        .l "[peripheral setNotifyValue:YES forCharacteristic:c];"],
    .blank,
    b "- (void)write:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "CBPeripheral *peripheral = _peripherals[args[@\"id\"] ?: @\"\"];",
        .l "CBUUID *uuid = [args[@\"characteristic\"] isKindOfClass:NSString.class] ? [CBUUID UUIDWithString:args[@\"characteristic\"]] : nil;",
        .l "CBCharacteristic *c = uuid ? [self characteristic:uuid of:peripheral] : nil;",
        .l "NSData *data = [args[@\"hex\"] isKindOfClass:NSString.class] ? ELDataOf(args[@\"hex\"]) : nil;",
        .l "if (!c) { answer(@{@\"ok\": @NO, @\"error\": peripheral ? @\"no-characteristic\" : @\"disconnected\"}); return; }",
        .l "if (!data) { answer(@{@\"ok\": @NO, @\"error\": @\"bad-hex\"}); return; }",
        .l "BOOL response = [args[@\"response\"] isKindOfClass:NSNumber.class] ? [args[@\"response\"] boolValue] : YES;",
        b "if (!response) {" [
            .l "[peripheral writeValue:data forCharacteristic:c type:CBCharacteristicWriteWithoutResponse];",
            .l "answer(@{@\"ok\": @YES});",
            .l "return;"],
        .l "NSString *key = [self key:args[@\"id\"] characteristic:uuid];",
        .l "if (!_writes[key]) _writes[key] = [NSMutableArray array];",
        .l "__block ELPending *mine = nil;",
        b "mine = [self pending:answer timeout:ELSeconds(args, @\"timeout\", 15) onTimeout:^(ELPending *p) {" [
            .l "[self->_writes[key] removeObject:p];",
            .l "[self settle:p with:@{@\"ok\": @NO, @\"error\": @\"timeout\"}];"] "}];",
        .l "[_writes[key] addObject:mine];",
        .l "[peripheral writeValue:data forCharacteristic:c type:CBCharacteristicWriteWithResponse];"],
    .blank,
    b "- (void)read:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "CBUUID *uuid = [args[@\"characteristic\"] isKindOfClass:NSString.class] ? [CBUUID UUIDWithString:args[@\"characteristic\"]] : nil;",
        .l "if (!uuid) { answer(@{@\"error\": @\"no-characteristic\"}); return; }",
        .l "NSString *key = [self key:args[@\"id\"] ?: @\"\" characteristic:uuid];",
        .l "NSMutableArray<NSString *> *queued = _values[key];",
        b "if (queued.count > 0) {" [
            .l "NSString *hex = queued.firstObject;",
            .l "[queued removeObjectAtIndex:0];",
            .l "answer(@{@\"hex\": hex});",
            .l "return;"],
        .l "if (!_peripherals[args[@\"id\"] ?: @\"\"]) { answer(@{@\"error\": @\"disconnected\"}); return; }",
        .l "if (!_reads[key]) _reads[key] = [NSMutableArray array];",
        b "ELPending *p = [self pending:answer timeout:ELSeconds(args, @\"timeout\", 30) onTimeout:^(ELPending *q) {" [
            .l "[self->_reads[key] removeObject:q];",
            .l "[self settle:q with:@{@\"error\": @\"timeout\"}];"] "}];",
        .l "[_reads[key] addObject:p];"],
    .blank,
    b "- (void)close:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "CBPeripheral *peripheral = _peripherals[args[@\"id\"] ?: @\"\"];",
        .l "if (peripheral) [_central cancelPeripheralConnection:peripheral];",
        .l "answer(@{@\"ok\": @YES});"],
    .blank,
    .l "/// Everything waiting on a peripheral that went away fails, and its unread values are dropped.",
    b "- (void)drop:(NSString *)peripheral {" [
        .l "NSString *prefix = [peripheral stringByAppendingString:@\"|\"];",
        .l "for (NSString *key in _subscribes.allKeys)",
        .l "    if ([key hasPrefix:prefix]) { ELPending *p = _subscribes[key]; [_subscribes removeObjectForKey:key]; [self settle:p with:@{@\"ok\": @NO, @\"error\": @\"disconnected\"}]; }",
        .l "for (NSString *key in _writes.allKeys)",
        .l "    if ([key hasPrefix:prefix]) { NSArray *ps = _writes[key]; [_writes removeObjectForKey:key]; for (ELPending *p in ps) [self settle:p with:@{@\"ok\": @NO, @\"error\": @\"disconnected\"}]; }",
        .l "for (NSString *key in _reads.allKeys)",
        .l "    if ([key hasPrefix:prefix]) { NSArray *ps = _reads[key]; [_reads removeObjectForKey:key]; for (ELPending *p in ps) [self settle:p with:@{@\"error\": @\"disconnected\"}]; }",
        .l "for (NSString *key in _values.allKeys)",
        .l "    if ([key hasPrefix:prefix]) [_values removeObjectForKey:key];",
        .l "[_peripherals removeObjectForKey:peripheral];"],
    .blank,
    b "- (void)centralManagerDidUpdateState:(CBCentralManager *)central {" [
        .l "if (central.state == CBManagerStateUnknown || central.state == CBManagerStateResetting) return;",
        .l "NSArray *waiting = [_whenReady copy];",
        .l "[_whenReady removeAllObjects];",
        .l "for (void (^then)(void) in waiting) then();",
        b "if (central.state != CBManagerStatePoweredOn) {" [
            .l "if (_connect) [self endConnect:@{@\"ok\": @NO, @\"error\": ELStateName(central.state)}];",
            .l "for (NSString *id_ in _peripherals.allKeys) [self drop:id_];"]],
    .blank,
    .l "- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral",
    b "     advertisementData:(NSDictionary<NSString *, id> *)advertisementData RSSI:(NSNumber *)RSSI {" [
        .l "if (!_connect || _connecting) return;",
        .l "[central stopScan];",
        .l "[self attach:peripheral];"],
    .blank,
    b "- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {" [
        .l "if (peripheral != _connecting) return;",
        .l "[peripheral discoverServices:_connectServices];"],
    .blank,
    b "- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {" [
        .l "if (peripheral == _connecting) [self endConnect:@{@\"ok\": @NO, @\"error\": @\"refused\"}];"],
    .blank,
    b "- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {" [
        .l "if (peripheral == _connecting) [self endConnect:@{@\"ok\": @NO, @\"error\": @\"disconnected\"}];",
        .l "[self drop:peripheral.identifier.UUIDString];"],
    .blank,
    b "- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {" [
        .l "if (peripheral != _connecting) return;",
        .l "CBService *service = nil;",
        .l "for (CBService *s in peripheral.services) if ([_connectServices containsObject:s.UUID]) { service = s; break; }",
        b "if (error || !service) {" [
            .l "[_central cancelPeripheralConnection:peripheral];",
            .l "[self endConnect:@{@\"ok\": @NO, @\"error\": @\"no-service\"}];",
            .l "return;"],
        .l "[peripheral discoverCharacteristics:nil forService:service];"],
    .blank,
    b "- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {" [
        .l "if (peripheral != _connecting) return;",
        b "if (error) {" [
            .l "[_central cancelPeripheralConnection:peripheral];",
            .l "[self endConnect:@{@\"ok\": @NO, @\"error\": @\"no-characteristics\"}];",
            .l "return;"],
        .l "NSString *id_ = peripheral.identifier.UUIDString;",
        .l "_peripherals[id_] = peripheral;",
        .l "NSMutableArray *uuids = [NSMutableArray array];",
        .l "for (CBCharacteristic *c in service.characteristics) [uuids addObject:c.UUID.UUIDString];",
        .l "[self endConnect:@{@\"ok\": @YES, @\"id\": id_, @\"service\": service.UUID.UUIDString, @\"characteristics\": uuids}];"],
    .blank,
    .l "- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic",
    b "             error:(NSError *)error {" [
        .l "NSString *key = [self key:peripheral.identifier.UUIDString characteristic:characteristic.UUID];",
        .l "ELPending *p = _subscribes[key];",
        .l "if (!p) return;",
        .l "[_subscribes removeObjectForKey:key];",
        .l "[self settle:p with:error ? @{@\"ok\": @NO, @\"error\": error.localizedDescription ?: @\"refused\"} : @{@\"ok\": @YES}];"],
    .blank,
    b "- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {" [
        .l "NSString *key = [self key:peripheral.identifier.UUIDString characteristic:characteristic.UUID];",
        .l "NSMutableArray<ELPending *> *ps = _writes[key];",
        .l "if (ps.count == 0) return;",
        .l "ELPending *p = ps.firstObject;",
        .l "[ps removeObjectAtIndex:0];",
        .l "[self settle:p with:error ? @{@\"ok\": @NO, @\"error\": error.localizedDescription ?: @\"refused\"} : @{@\"ok\": @YES}];"],
    .blank,
    b "- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {" [
        .l "if (error || !characteristic.value) return;",
        .l "NSString *key = [self key:peripheral.identifier.UUIDString characteristic:characteristic.UUID];",
        .l "NSString *hex = ELHexOf(characteristic.value);",
        .l "NSMutableArray<ELPending *> *readers = _reads[key];",
        b "if (readers.count > 0) {" [
            .l "ELPending *p = readers.firstObject;",
            .l "[readers removeObjectAtIndex:0];",
            .l "[self settle:p with:@{@\"hex\": hex}];",
            .l "return;"],
        .l "if (!_values[key]) _values[key] = [NSMutableArray array];",
        .l "[_values[key] addObject:hex];"],
    .blank,
    .l "@end"]

/-- The statements before the first declaration: the imports. -/
def capsImports : Nat := (capsBefore.findIdx? fun | .l _ | .blk .. => true | _ => false).getD 0

def capsFile : List Stmt :=
  capsBefore.take capsImports ++ argHelpers ++ bluetoothClass ++ [.blank] ++ backgroundTasksClass ++ [.blank] ++ cloudKitClass ++ [.blank] ++ capsBefore.drop capsImports ++
  [ b "- (void)run:(NSString *)name args:(NSDictionary *)args answer:(void (^)(NSDictionary *))answer {"
      [ ifChain "" (capabilities.map (fun c => (s!"[name isEqualToString:{lit c.name}]", c.body)) ++ [("", unknownCapability)]) ] ] ++
  [
    .blank,
    .l "@end"]

end ElmShell
