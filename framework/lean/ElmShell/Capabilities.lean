import ElmShell.ObjC

/-! # ElmShell.Capabilities: `ELCapabilities.m`

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
  { name := "auth", args := "`reason`", result := "`{\"ok\":true}` or `{\"ok\":false,\"error\":…}` (device-owner authentication)",
    body := [
      .l "LAContext *context = [LAContext new];",
      b "if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:nil]) {" [
          .pp "#if TARGET_OS_SIMULATOR",
          .l "answer(@{@\"ok\": @YES, @\"note\": @\"simulator without a passcode\"});",
          .pp "#else",
          .l "answer(@{@\"ok\": @NO, @\"error\": @\"Set a device passcode first.\"});",
          .pp "#endif",
          .l "return;"],
      .l "NSString *reason = ELArgString(args, @\"reason\") ?: @\"Confirm\";",
      b "[context evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:reason reply:^(BOOL ok, NSError *error) {" [
          .l "NSDictionary *result = ok ? @{@\"ok\": @YES} : @{@\"ok\": @NO, @\"error\": error.localizedDescription ?: @\"Authentication failed.\"};",
          .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"] "}];"] },
  { name := "keychain.get", args := "`key`, `service`?", result := "`{\"value\":…}` or `{\"value\":null}` (`service` defaults to the bundle id)",
    body := [
      .l "NSMutableDictionary *query = [self base:args];",
      .l "query[(__bridge id)kSecReturnData] = @YES;",
      .l "CFTypeRef out = NULL;",
      .l "OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &out);",
      .l "NSData *data = status == errSecSuccess ? (__bridge_transfer NSData *)out : nil;",
      .l "NSString *s = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;",
      .l "answer(@{@\"value\": s ?: NSNull.null});"] },
  { name := "keychain.set", args := "`key`, `value`, `service`?", result := "`{\"ok\":…,\"status\":…}` (the `OSStatus`); this device only, while unlocked",
    body := [
      .l "NSData *data = [(ELArgString(args, @\"value\") ?: @\"\") dataUsingEncoding:NSUTF8StringEncoding];",
      .l "SecItemDelete((__bridge CFDictionaryRef)[self base:args]);",
      .l "NSMutableDictionary *query = [self base:args];",
      .l "query[(__bridge id)kSecValueData] = data;",
      .l "query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;",
      .l "OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess)), @\"status\": @(status)});"] },
  { name := "keychain.delete", args := "`key`, `service`?", result := "`{\"ok\":…,\"status\":…}`",
    body := [
      .l "OSStatus status = SecItemDelete((__bridge CFDictionaryRef)[self base:args]);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess || status == errSecItemNotFound)), @\"status\": @(status)});"] },
  { name := "keychain.clear", args := "`service`", result := "`{\"ok\":…,\"status\":…}` deletes every item of that service (a test namespace's reset)",
    body := [
      .l "NSString *service = ELArgString(args, @\"service\");",
      .l "if (service.length == 0) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam)}); return; }",
      .l "OSStatus status = SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,",
      .l "                                                            (__bridge id)kSecAttrService: service});",
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
  { name := "http.get", args := "`url`, `maxBytes`, `timeout` (s), `accept`?", result := "`{\"status\":…,\"body\":hex}` or `{\"error\":…}`; ephemeral session, no cookies or cache, redirects only within the same host and never from https to http",
    body := [
      .l "NSURL *url = [NSURL URLWithString:ELArgString(args, @\"url\") ?: @\"\"];",
      .l "NSString *scheme = url.scheme.lowercaseString ?: @\"\";",
      .l "if (!url || !([scheme isEqualToString:@\"http\"] || [scheme isEqualToString:@\"https\"])) { answer(@{@\"error\": @\"bad-url\"}); return; }",
      .l "NSInteger maxBytes = ELArgNumber(args, @\"maxBytes\") ? [ELArgNumber(args, @\"maxBytes\") integerValue] : 1000000;",
      .l "NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];",
      .l "request.timeoutInterval = ELArgNumber(args, @\"timeout\") ? [ELArgNumber(args, @\"timeout\") doubleValue] : 30;",
      .l "NSString *accept = ELArgString(args, @\"accept\");",
      .l "if (accept) [request setValue:accept forHTTPHeaderField:@\"Accept\"];",
      b "[[ELHTTPFetch.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {" [
          .l "NSDictionary *result;",
          .blk [("if (error) {", [
                .l "result = @{@\"error\": error.localizedDescription};"]), ("} else if ([response isKindOfClass:NSHTTPURLResponse.class] && data) {", [
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
            .l "answer(@{@\"ok\": @NO});"])] "}"] } ]

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
    .blank,
    .l "/// One ephemeral URLSession for `http.get`: no cookies, no cache, redirects only within the same host and",
    .l "/// never from https down to http.",
    .l "@interface ELHTTPFetch : NSObject <NSURLSessionTaskDelegate>",
    .l "+ (NSURLSession *)session;",
    .l "@end",
    .blank,
    .l "@implementation ELHTTPFetch",
    .blank,
    b "+ (NSURLSession *)session {" [
        .l "static NSURLSession *session;",
        .l "static dispatch_once_t once;",
        b "dispatch_once(&once, ^{" [
            .l "NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];",
            .l "config.HTTPShouldSetCookies = NO;",
            .l "config.HTTPCookieStorage = nil;",
            .l "config.URLCache = nil;",
            .l "config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;",
            .l "config.timeoutIntervalForResource = 120;",
            .l "session = [NSURLSession sessionWithConfiguration:config delegate:[ELHTTPFetch new] delegateQueue:nil];"] "});",
        .l "return session;"],
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
    b "static NSString *ELArgString(NSDictionary *args, NSString *k) {" [
        .l "return [args[k] isKindOfClass:NSString.class] ? args[k] : nil;"],
    .blank,
    b "static NSNumber *ELArgNumber(NSDictionary *args, NSString *k) {" [
        .l "return [args[k] isKindOfClass:NSNumber.class] ? args[k] : nil;"],
    .blank,
    .l "@implementation ELCapabilities",
    .blank,
    .l "/// The item named by `key` within `service` (the app's bundle id unless the app names one).",
    b "- (NSMutableDictionary *)base:(NSDictionary *)args {" [
        .l "NSString *service = ELArgString(args, @\"service\") ?: (NSBundle.mainBundle.bundleIdentifier ?: @\"elmlean\");",
        .l "return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,",
        .l "          (__bridge id)kSecAttrAccount: ELArgString(args, @\"key\") ?: @\"\"} mutableCopy];"],
    .blank]

def capsFile : List Stmt :=
  capsBefore ++
  [ b "- (void)run:(NSString *)name args:(NSDictionary *)args answer:(void (^)(NSDictionary *))answer {"
      [ ifChain "" (capabilities.map (fun c => (s!"[name isEqualToString:{lit c.name}]", c.body)) ++ [("", unknownCapability)]) ] ] ++
  [
    .blank,
    .l "@end"]

end ElmShell
