import LeanNativeShell.ObjC
import LeanNativeShell.BackgroundTasks
import LeanNativeShell.CloudKit
import LeanNativeShell.Push

/-! # LeanNativeShell.Capabilities: `LNCapabilities.m`

The `ble.*` rows are generic Bluetooth Low Energy (GATT) by service and characteristic UUID, run by the
`LNBluetooth` class printed here; framing and UUIDs are the app's. An app that uses them declares
`NSBluetoothAlwaysUsageDescription` in its Info.plist.

One row per capability: its name, the documentation of its arguments and result (printed as the table in
the header's doc comment on `LNCapabilities`), and the Objective-C that runs it, which answers through
`answer`. The dispatch on the name is printed from the same rows, so a documented capability is a handled
one. -/

namespace LeanNativeShell

structure Capability where
  name : String
  args : String
  result : String
  body : List Stmt

set_option maxRecDepth 8000 in
def capabilities : List Capability :=
[
  { name := "auth", args := "`reason`, `keep`?", result := "`{\"ok\":true}` or `{\"ok\":false,\"error\":…,\"name\":…,\"code\":…,\"domain\":…}` (device-owner authentication; `error` is the system's text, `name` and `code` the `LAError` (`domain` the error's, so a non-`LAError` answer, named `unknown`, can be told apart): `userCancel`, `systemCancel`, `appCancel`, `userFallback`, `authenticationFailed`, `biometryLockout`, `passcodeNotSet`, `biometryNotAvailable`, `biometryNotEnrolled`, `notInteractive`, `invalidContext` or `unknown`); with `keep` (seconds, at most 60) a yes answers `{\"ok\":true,\"context\":…}`: the authentication is kept, under an id nobody can guess, for the `keychain.get`s that name it, until the first of `auth.end`, its time, and the app entering the background (not its resigning active, which the Face ID sheet causes)",
    body := [
      .l "LAContext *context = [LAContext new];",
      .l "NSError *unable = nil;",
      .l "// `keep`: the seconds a yes is kept for the Keychain reads that name it, at most 60; absent or not above 0, nothing is kept",
      .l "NSNumber *asked = LNArgNumber(args, @\"keep\");",
      .l "NSTimeInterval keep = asked ? MIN(asked.doubleValue, 60.0) : 0;",
      b "if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&unable]) {" [
          .pp "#if TARGET_OS_SIMULATOR",
          b "if (keep > 0) {" [
              .l "// nothing was checked, so what is kept allows no interaction: it satisfies no access control, and a",
              .l "// simulator without a passcode holds none (`keychain.add`)",
              .l "context.interactionNotAllowed = YES;",
              .l "answer(@{@\"ok\": @YES, @\"note\": @\"simulator without a passcode\", @\"context\": [self keepContext:context seconds:keep]});",
              .l "return;"],
          .l "answer(@{@\"ok\": @YES, @\"note\": @\"simulator without a passcode\"});",
          .pp "#else",
          .l "answer(@{@\"ok\": @NO, @\"error\": @\"Set a device passcode first.\", @\"name\": LNAuthErrorName(unable), @\"code\": @(unable.code)});",
          .pp "#endif",
          .l "return;"],
      .l "NSString *reason = LNArgString(args, @\"reason\") ?: @\"Confirm\";",
      b "[context evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:reason reply:^(BOOL ok, NSError *error) {" [
          .l "NSDictionary *result = ok ? @{@\"ok\": @YES} : @{@\"ok\": @NO, @\"error\": error.localizedDescription ?: @\"Authentication failed.\",",
          .l "                                                @\"name\": LNAuthErrorName(error), @\"code\": @(error.code), @\"domain\": error.domain ?: @\"\"};",
          b "dispatch_async(dispatch_get_main_queue(), ^{" [
              .l "// kept only while the app is in front: one already in the background has had the notification that ends it",
              b "if (ok && keep > 0 && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {" [
                  .l "// the reads that name it never ask again: one this authentication does not satisfy is refused instead",
                  .l "context.interactionNotAllowed = YES;",
                  .l "answer(@{@\"ok\": @YES, @\"context\": [self keepContext:context seconds:keep]});",
                  .l "return;"],
              .l "answer(result);"] "});"] "}];"] },
  { name := "auth.end", args := "`context` (a kept authentication's id, from `auth` with `keep`)",
    result := "`{\"ok\":true}`: that authentication is ended (`[LAContext invalidate]`) and its id unknown from here on; also when it had ended already, or never was",
    body := [
      .l "[self endContext:LNArgString(args, @\"context\")];",
      .l "answer(@{@\"ok\": @YES});"] },
  { name := "webauth", args := "`url`, `callbackHost` and `callbackPath` (an https callback: iOS 17.4 and later, with the host in the app's `webcredentials:` associated domains) or `callbackScheme` (a custom scheme), `ephemeral`?",
    result := "`{\"ok\":true,\"url\":…}` (the callback URL the sign-in ended at, query and all) or `{\"ok\":false,\"error\":…,\"name\":…,\"code\":…,\"domain\":…}`: a sign-in in the system browser (`ASWebAuthenticationSession`, with the browser's cookies unless `ephemeral`); `name` is the `ASWebAuthenticationSessionError` (`canceledLogin`, `presentationContextNotProvided`, `presentationContextInvalid`), `unsupported` (an https callback below iOS 17.4), `bad-url`, `bad-callback`, or `busy` (one sign-in at a time)",
    body := [
      .l "NSURL *url = [NSURL URLWithString:LNArgString(args, @\"url\") ?: @\"\"];",
      b "if (!url || !([url.scheme isEqualToString:@\"https\"] || [url.scheme isEqualToString:@\"http\"])) {" [
          .l "answer(@{@\"ok\": @NO, @\"error\": @\"Not an http(s) URL.\", @\"name\": @\"bad-url\"});",
          .l "return;"],
      .l "NSString *host = LNArgString(args, @\"callbackHost\"), *path = LNArgString(args, @\"callbackPath\"), *scheme = LNArgString(args, @\"callbackScheme\");",
      .l "BOOL ephemeral = [LNArgNumber(args, @\"ephemeral\") boolValue];",
      .l "[LNWebAuth.shared start:url host:host path:path scheme:scheme ephemeral:ephemeral answer:answer];"] },
  { name := "keychain.get", args := "`key`, `service`?, `synchronizable`?, `hex`?, `context`?",
    result := "`{\"value\":…,\"status\":…}` or `{\"value\":null,\"status\":…}` (`service` defaults to the bundle id; `status` is the `OSStatus`: `-25300` for no such item); with `hex`, `{\"hex\":…|null,\"status\":…}`: the raw bytes. It never asks the person and never holds the main thread for them: an item behind the person's presence (`keychain.add` with `access`, `keychain.protect`) is read under the kept authentication `context` names (`auth` with `keep`), and with none, or one that has ended or never was, answers `-25308` (`errSecInteractionNotAllowed`)",
    body := [
      .l "NSMutableDictionary *query = [self base:args];",
      .l "query[(__bridge id)kSecReturnData] = @YES;",
      .l "// never a prompt: the kept authentication the request names, else a context that allows no interaction",
      .l "query[(__bridge id)kSecUseAuthenticationContext] = [self liveContext:LNArgString(args, @\"context\")] ?: [self noInteraction];",
      .l "if ([self synchronizable:args]) query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;",
      .l "CFTypeRef out = NULL;",
      .l "OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &out);",
      .l "NSData *data = status == errSecSuccess ? (__bridge_transfer NSData *)out : nil;",
      b "if ([LNArgNumber(args, @\"hex\") boolValue]) {" [
          .l "answer(@{@\"hex\": data ? LNHexOf(data) : NSNull.null, @\"status\": @(status)});",
          .l "return;"],
      .l "NSString *s = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;",
      .l "answer(@{@\"value\": s ?: NSNull.null, @\"status\": @(status)});"] },
  { name := "keychain.add", args := "`key`, `value` or `hex`, `service`?, `synchronizable`?, `access`? (`userPresence`)",
    result := "`{\"ok\":…,\"status\":…,\"exists\":…}`: creates the item only if there is none (one `SecItemAdd`; `-25299`, `errSecDuplicateItem`, with `exists` when there is, and the item is untouched); protection as `keychain.set`. With `access`: `userPresence` the item is behind the person's presence instead: an access control (`SecAccessControlCreateWithFlags`, `kSecAccessControlUserPresence` over `WhenUnlockedThisDeviceOnly`) in place of the protection class, so the Keychain gives its value only after Face ID, Touch ID or the passcode, and the answer says `\"access\":\"userPresence\"`; refused with `-50` for a `synchronizable` item or any other `access`. A device without a passcode refuses it (`-25293`, nothing stored); a simulator whose Keychain refuses it so stores the item in the plain class, there only, and says `\"access\":\"unlocked\"`",
    body := [
      .l "NSString *hex = LNArgString(args, @\"hex\");",
      .l "NSData *data = hex ? LNDataOf(hex) : [(LNArgString(args, @\"value\") ?: @\"\") dataUsingEncoding:NSUTF8StringEncoding];",
      .l "if (!data) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam), @\"exists\": @NO}); return; }",
      .l "int access = [self access:args];",
      .l "// an access control is one device's: an item that syncs cannot have one",
      .l "if (access < 0 || (access == 1 && [self synchronizable:args])) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam), @\"exists\": @NO}); return; }",
      .l "NSMutableDictionary *query = [self base:args];",
      .l "query[(__bridge id)kSecValueData] = data;",
      b "if (access == 1) {" [
          .l "OSStatus status = errSecSuccess;",
          .l "NSString *applied = @\"userPresence\";",
          .l "NSDictionary *presence = [self userPresence:&status];",
          b "if (presence) {" [
              .l "[query addEntriesFromDictionary:presence];",
              .l "status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);"],
          .pp "#if TARGET_OS_SIMULATOR",
          .l "// a simulator has no passcode to set: where its Keychain refuses the access control for want of one, there",
          .l "// and only there, the item is stored in the plain class and the answer says so, as `auth` notes a simulator",
          .l "// without a passcode. A device fails closed: the status, and nothing stored",
          b "if (!presence || status == errSecAuthFailed) {" [
              .l "[query removeObjectsForKeys:@[(__bridge id)kSecAttrAccessControl, (__bridge id)kSecAttrGeneric]];",
              .l "query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;",
              .l "status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);",
              .l "applied = @\"unlocked\";"],
          .pp "#endif",
          .l "NSMutableDictionary *result = [@{@\"ok\": @((BOOL)(status == errSecSuccess)), @\"status\": @(status),",
          .l "                                 @\"exists\": @((BOOL)(status == errSecDuplicateItem))} mutableCopy];",
          .l "if (status == errSecSuccess) result[@\"access\"] = applied;",
          .l "answer(result);",
          .l "return;"],
      .l "query[(__bridge id)kSecAttrAccessible] = [self synchronizable:args] ? (__bridge id)kSecAttrAccessibleWhenUnlocked",
      .l "                                                                    : (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;",
      .l "// no delete first: the Keychain refuses a second item of the same name, so racing adds cannot both succeed",
      .l "OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess)), @\"status\": @(status), @\"exists\": @((BOOL)(status == errSecDuplicateItem))});"] },
  { name := "keychain.set", args := "`key`, `value` or `hex`, `service`?, `synchronizable`?",
    result := "`{\"ok\":…,\"status\":…}` (the `OSStatus`; `-50` for bad hex): the item's value is replaced in place (`SecItemUpdate`; `SecItemAdd` when there is no item), so a write that fails leaves the old value; this device only, while unlocked; with `synchronizable`, iCloud Keychain (`kSecAttrSynchronizable`), while unlocked. It neither makes nor rewrites an item behind the person's presence: with `access` it answers `-50`, and over such an item `-25308`, the item as it was: its attributes are looked at first, and the update runs under no interaction besides (`keychain.add` makes one, `keychain.protect` upgrades one)",
    body := [
      .l "NSString *hex = LNArgString(args, @\"hex\");",
      .l "NSData *data = hex ? LNDataOf(hex) : [(LNArgString(args, @\"value\") ?: @\"\") dataUsingEncoding:NSUTF8StringEncoding];",
      .l "if (!data) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam)}); return; }",
      .l "// never an item behind an access control from here, made or rewritten: `keychain.add` makes one",
      .l "if ([self access:args] != 0) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam)}); return; }",
      .l "// nor is one that is there rewritten: its attributes say it is one (never its value), and it stays as it was.",
      .l "// The Keychain refuses the same of itself where it enforces an access control; a simulator's does not",
      .l "OSStatus found = errSecSuccess;",
      .l "if ([self marked:[self attributes:args status:&found]] || [self heldBack:found]) { answer(@{@\"ok\": @NO, @\"status\": @(errSecInteractionNotAllowed)}); return; }",
      .l "// an item that syncs cannot be this-device-only",
      .l "id accessible = [self synchronizable:args] ? (__bridge id)kSecAttrAccessibleWhenUnlocked",
      .l "                                           : (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;",
      .l "NSDictionary *changes = @{(__bridge id)kSecValueData: data, (__bridge id)kSecAttrAccessible: accessible};",
      .l "// in place, never a delete and then an add: a write the Keychain refuses (the device locked, say) leaves",
      .l "// the old value where it was. Under no interaction: the Keychain would ask the person, on this thread, before",
      .l "// it rewrote an item behind an access control, and is refused instead (-25308), that item as it was",
      .l "NSMutableDictionary *target = [self base:args];",
      .l "target[(__bridge id)kSecUseAuthenticationContext] = [self noInteraction];",
      .l "OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)target, (__bridge CFDictionaryRef)changes);",
      b "if (status == errSecItemNotFound) {" [
          .l "NSMutableDictionary *item = [self base:args];",
          .l "[item addEntriesFromDictionary:changes];",
          .l "status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);",
          .l "// added by another writer in between: theirs is the item to update",
          .l "if (status == errSecDuplicateItem)",
          .l "    status = SecItemUpdate((__bridge CFDictionaryRef)target, (__bridge CFDictionaryRef)changes);"],
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess)), @\"status\": @(status)});"] },
  { name := "keychain.delete", args := "`key`, `service`?, `synchronizable`?", result := "`{\"ok\":…,\"status\":…}`",
    body := [
      .l "OSStatus status = SecItemDelete((__bridge CFDictionaryRef)[self base:args]);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess || status == errSecItemNotFound)), @\"status\": @(status)});"] },
  { name := "keychain.clear", args := "`service`, `synchronizable`?", result := "`{\"ok\":…,\"status\":…}` deletes every item of that service (a test namespace's reset); with `synchronizable`, its iCloud Keychain items instead",
    body := [
      .l "NSString *service = LNArgString(args, @\"service\");",
      .l "if (service.length == 0) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam)}); return; }",
      .l "NSMutableDictionary *query = [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,",
      .l "                                (__bridge id)kSecAttrService: service} mutableCopy];",
      .l "if ([self synchronizable:args]) query[(__bridge id)kSecAttrSynchronizable] = @YES;",
      .l "OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);",
      .l "answer(@{@\"ok\": @((BOOL)(status == errSecSuccess || status == errSecItemNotFound)), @\"status\": @(status)});"] },
  { name := "keychain.protect", args := "`key`, `service`?, `access`? (`userPresence`, the only one)",
    result := "`{\"ok\":…,\"status\":…,\"changed\":…}`: puts an item that is there behind the person's presence, in place: its attributes are read (never its value), and unless it is so already one `SecItemUpdate` gives it the access control of `keychain.add` with `access`. It never deletes the item and never adds it again; a refusal leaves it as it was and answers the status (`-25300` for no such item, `-50` for a `synchronizable` one). `changed` is false for an item already behind it. With `ok`, `\"access\":\"userPresence\"`; a simulator whose Keychain refuses the access control for want of a passcode leaves the item as it is and answers `\"changed\":false,\"access\":\"unlocked\"`",
    body := [
      .l "// an access control is one device's: an item that syncs cannot have one; and the person's presence is the only one",
      .l "if ((args[@\"access\"] && [self access:args] != 1) || [self synchronizable:args]) { answer(@{@\"ok\": @NO, @\"status\": @(errSecParam), @\"changed\": @NO}); return; }",
      .l "OSStatus status = errSecSuccess;",
      .l "NSDictionary *attributes = [self attributes:args status:&status];",
      .l "// a device's Keychain gives nothing of an item behind an access control without the person, its attributes",
      .l "// included: on an unlocked device that refusal is the answer, the item is so already (`heldBack:`)",
      .l "if (!attributes && [self heldBack:status]) { answer(@{@\"ok\": @YES, @\"status\": @(errSecSuccess), @\"changed\": @NO, @\"access\": @\"userPresence\"}); return; }",
      .l "if (!attributes) { answer(@{@\"ok\": @NO, @\"status\": @(status), @\"changed\": @NO}); return; }",
      .l "if ([self marked:attributes]) { answer(@{@\"ok\": @YES, @\"status\": @(errSecSuccess), @\"changed\": @NO, @\"access\": @\"userPresence\"}); return; }",
      .l "NSDictionary *presence = [self userPresence:&status];",
      b "if (presence) {" [
          .l "// one update, in place: never a delete and then an add, and the value is not read. A refusal leaves the",
          .l "// item as it was",
          .l "NSMutableDictionary *item = [self base:args];",
          .l "item[(__bridge id)kSecUseAuthenticationContext] = [self noInteraction];",
          .l "status = SecItemUpdate((__bridge CFDictionaryRef)item, (__bridge CFDictionaryRef)presence);"],
      .pp "#if TARGET_OS_SIMULATOR",
      .l "// a simulator whose Keychain refuses the access control (`keychain.add`): the item stays as it is, and the",
      .l "// answer says so. A device answers the status",
      .l "if (!presence || status == errSecAuthFailed) { answer(@{@\"ok\": @YES, @\"status\": @(errSecSuccess), @\"changed\": @NO, @\"access\": @\"unlocked\"}); return; }",
      .pp "#endif",
      .l "if (status != errSecSuccess) { answer(@{@\"ok\": @NO, @\"status\": @(status), @\"changed\": @NO}); return; }",
      .l "answer(@{@\"ok\": @YES, @\"status\": @(status), @\"changed\": @YES, @\"access\": @\"userPresence\"});"] },
  { name := "keychain.attributes", args := "`key`, `service`?, `synchronizable`?",
    result := "`{\"status\":…,\"accessible\":…|null,\"userPresence\":bool,\"synchronizable\":bool}`: what protects the item, never its value (`kSecReturnAttributes`), so nobody is asked: `accessible` is its protection class (`whenUnlocked`, `whenUnlockedThisDeviceOnly`, `afterFirstUnlock`, `afterFirstUnlockThisDeviceOnly`, `whenPasscodeSetThisDeviceOnly`, another as the system names it, or null when the system does not say), `userPresence` whether it is behind the person's presence (the marker `keychain.add` and `keychain.protect` write with the access control, which cannot itself be read back); `status` is `-25300` for no such item, the rest then null and false",
    body := [
      .l "OSStatus status = errSecSuccess;",
      .l "NSDictionary *attributes = [self attributes:args status:&status];",
      .l "// an item behind an access control, on a device: the Keychain holds its attributes back too, and that is what",
      .l "// is known of it (`heldBack:`). Its protection class is not",
      .l "if (!attributes && [self heldBack:status]) { answer(@{@\"status\": @(errSecSuccess), @\"accessible\": NSNull.null, @\"userPresence\": @YES, @\"synchronizable\": @NO}); return; }",
      .l "NSDictionary *names = @{(__bridge id)kSecAttrAccessibleWhenUnlocked: @\"whenUnlocked\",",
      .l "                        (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly: @\"whenUnlockedThisDeviceOnly\",",
      .l "                        (__bridge id)kSecAttrAccessibleAfterFirstUnlock: @\"afterFirstUnlock\",",
      .l "                        (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: @\"afterFirstUnlockThisDeviceOnly\",",
      .l "                        (__bridge id)kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly: @\"whenPasscodeSetThisDeviceOnly\"};",
      .l "id accessible = attributes[(__bridge id)kSecAttrAccessible];",
      .l "answer(@{@\"status\": @(status), @\"accessible\": [accessible isKindOfClass:NSString.class] ? (names[accessible] ?: accessible) : NSNull.null,",
      .l "         @\"userPresence\": @((BOOL)[self marked:attributes]), @\"synchronizable\": @((BOOL)[attributes[(__bridge id)kSecAttrSynchronizable] boolValue])});"] },
  { name := "timezone", args := "`at`?", result := "`{\"id\":…,\"offset\":…}` the device's time zone: its identifier (`Europe/Paris`) and its seconds east of UTC, now or at `at` (Unix seconds), so an app can say a time as the person's clock does",
    body := [
      .l "NSTimeZone *zone = NSTimeZone.localTimeZone;",
      .l "id at = args[@\"at\"];",
      .l "NSDate *when = [at isKindOfClass:NSNumber.class] ? [NSDate dateWithTimeIntervalSince1970:[at doubleValue]] : [NSDate date];",
      .l "answer(@{@\"id\": zone.name ?: @\"\", @\"offset\": @([zone secondsFromGMTForDate:when])});"] },
  { name := "device", args := "—", result := "`{\"idiom\":…}` the kind of machine: `phone`, `pad` or `mac` (a Mac Catalyst build, or the iPad app on a Mac), so an app can lay itself out for a window and a keyboard",
    body := [
      .pp "#if TARGET_OS_MACCATALYST",
      .l "answer(@{@\"idiom\": @\"mac\"});",
      .pp "#else",
      .l "BOOL pad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;",
      .l "answer(@{@\"idiom\": NSProcessInfo.processInfo.isiOSAppOnMac ? @\"mac\" : pad ? @\"pad\" : @\"phone\"});",
      .pp "#endif"] },
  { name := "conditions", args := "—", result := "`{\"power\":…,\"lowPower\":bool,\"network\":…,\"expensive\":bool,\"constrained\":bool}` what the device is running on at this moment: `power` is `charging`, `full` (plugged in, the battery full), `battery` or `unknown` (a simulator, and a Mac that says nothing); `lowPower`, Low Power Mode; `network` is `wifi`, `wired`, `cellular`, `other`, `none`, or `unknown` when the system has not said within two seconds; `expensive` (cellular, or a personal hotspot) and `constrained` (Low Data Mode), as the system's network path says them. Asked when wanted, nothing is watched after the answer: so an app can keep heavy work for when it costs the person nothing",
    body := [
      .l "UIDevice *device = UIDevice.currentDevice;",
      .l "BOOL watched = device.batteryMonitoringEnabled;",
      .l "device.batteryMonitoringEnabled = YES;",
      .l "UIDeviceBatteryState state = device.batteryState;",
      .l "device.batteryMonitoringEnabled = watched;",
      .l "NSString *power = state == UIDeviceBatteryStateCharging ? @\"charging\" : state == UIDeviceBatteryStateFull ? @\"full\" : state == UIDeviceBatteryStateUnplugged ? @\"battery\" : @\"unknown\";",
      .l "NSNumber *lowPower = @(NSProcessInfo.processInfo.lowPowerModeEnabled);",
      .l "// the network as the system's path says it: the first update comes at once; answered once, then let go",
      .l "nw_path_monitor_t monitor = nw_path_monitor_create();",
      .l "__block BOOL answered = NO;",
      .l "nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());",
      .l "nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {",
      .l "    if (answered) return;",
      .l "    answered = YES;",
      .l "    BOOL up = nw_path_get_status(path) == nw_path_status_satisfied;",
      .l "    NSString *network = !up ? @\"none\" : nw_path_uses_interface_type(path, nw_interface_type_wifi) ? @\"wifi\"",
      .l "        : nw_path_uses_interface_type(path, nw_interface_type_wired) ? @\"wired\"",
      .l "        : nw_path_uses_interface_type(path, nw_interface_type_cellular) ? @\"cellular\" : @\"other\";",
      .l "    answer(@{@\"power\": power, @\"lowPower\": lowPower, @\"network\": network,",
      .l "             @\"expensive\": @((BOOL)nw_path_is_expensive(path)), @\"constrained\": @((BOOL)nw_path_is_constrained(path))});",
      .l "    nw_path_monitor_cancel(monitor);",
      .l "});",
      .l "nw_path_monitor_start(monitor);",
      .l "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{",
      .l "    if (answered) return;",
      .l "    answered = YES;",
      .l "    answer(@{@\"power\": power, @\"lowPower\": lowPower, @\"network\": @\"unknown\", @\"expensive\": @NO, @\"constrained\": @NO});",
      .l "    nw_path_monitor_cancel(monitor);",
      .l "});"] },
  { name := "appearance", args := "`style`", result := "`{\"ok\":true}` draws the app `light`, `dark` or as the system is (`system`, or any other style), every window now and from the first frame of the next launch (remembered), so an app can offer the choice in its settings",
    body := [
      .l "NSString *style = LNArgString(args, @\"style\") ?: @\"system\";",
      .l "[NSUserDefaults.standardUserDefaults setObject:style forKey:@\"LNAppearance\"];",
      .l "UIUserInterfaceStyle chosen = LNAppearance();",
      b "for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {" [
          .l "if (![scene isKindOfClass:UIWindowScene.class]) continue;",
          .l "for (UIWindow *w in ((UIWindowScene *)scene).windows) w.overrideUserInterfaceStyle = chosen;"],
      .l "answer(@{@\"ok\": @YES});"] },
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
      .l "if ([LNArgNumber(args, @\"localOnly\") boolValue]) options[UIPasteboardOptionLocalOnly] = @YES;",
      .l "NSNumber *seconds = LNArgNumber(args, @\"expiresIn\");",
      .l "if (seconds) options[UIPasteboardOptionExpirationDate] = [NSDate dateWithTimeIntervalSinceNow:seconds.doubleValue];",
      .l "[UIPasteboard.generalPasteboard setItems:@[@{UIPasteboardTypeAutomatic: LNArgString(args, @\"text\") ?: @\"\"}] options:options];",
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
      .l "NSURL *url = [NSURL fileURLWithPath:LNArgString(args, @\"path\") ?: @\"\"];",
      .l "BOOL ok = [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];",
      .l "if (ok && [LNArgNumber(args, @\"complete\") boolValue])",
      .l "    ok = [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionComplete} ofItemAtPath:url.path error:nil];",
      .l "answer(@{@\"ok\": @(ok)});"] },
  { name := "http.get", args := "`url`, `maxBytes`, `timeout` (s), `accept`?, `socks`? (`{\"host\",\"port\"}`)",
    result := "`{\"status\":…,\"body\":hex}` or `{\"error\":…}` (`bad-url`, `bad-proxy`, `tooLarge`, `response`, or the system's description with its `code` and `domain`); ephemeral session, no cookies or cache, a body over `maxBytes` is refused as soon as it is known to be (the length the server declares, else the bytes as they arrive: the transfer is cancelled, not buffered); redirects only within the same origin (scheme, host and port, so never from https to http); with `socks`, through that SOCKS5 proxy only (names resolved by the proxy, no direct fallback)",
    body := [
      .l "NSURL *url = [NSURL URLWithString:LNArgString(args, @\"url\") ?: @\"\"];",
      .l "NSString *scheme = url.scheme.lowercaseString ?: @\"\";",
      .l "if (!url || !([scheme isEqualToString:@\"http\"] || [scheme isEqualToString:@\"https\"])) { answer(@{@\"error\": @\"bad-url\"}); return; }",
      .l "NSURLSession *session = [LNHTTPFetch session:args[@\"socks\"]];",
      .l "if (!session) { answer(@{@\"error\": @\"bad-proxy\"}); return; }",
      .l "NSInteger maxBytes = LNArgNumber(args, @\"maxBytes\") ? [LNArgNumber(args, @\"maxBytes\") integerValue] : 1000000;",
      .l "NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];",
      .l "BOOL proxied = args[@\"socks\"] && args[@\"socks\"] != NSNull.null;",
      .l "request.timeoutInterval = LNArgNumber(args, @\"timeout\") ? [LNArgNumber(args, @\"timeout\") doubleValue] : (proxied ? 90 : 30);",
      .l "NSString *accept = LNArgString(args, @\"accept\");",
      .l "if (accept) [request setValue:accept forHTTPHeaderField:@\"Accept\"];",
      .l "[LNHTTPFetch fetch:request session:session maxBytes:maxBytes answer:answer];"] },
  { name := "http.request", args := "`url`, `method` (GET, POST, PUT, PATCH, DELETE), `headers`? (string values), `body`? (hex, at most 1 MiB), `maxBytes`?, `timeout`? (s), `socks`?",
    result := "`{\"status\":…,\"body\":hex}` or `{\"error\":…}`; ephemeral session, no cookies or cache, the body bounded by `maxBytes` and redirects followed as `http.get` does",
    body := [
      .l "NSURL *url = [NSURL URLWithString:LNArgString(args, @\"url\") ?: @\"\"];",
      .l "NSString *scheme = url.scheme.lowercaseString ?: @\"\";",
      .l "if (!url || !([scheme isEqualToString:@\"http\"] || [scheme isEqualToString:@\"https\"])) { answer(@{@\"error\": @\"bad-url\"}); return; }",
      .l "NSString *method = [LNArgString(args, @\"method\") uppercaseString] ?: @\"\";",
      .l "if (![@[@\"GET\", @\"POST\", @\"PUT\", @\"PATCH\", @\"DELETE\"] containsObject:method]) { answer(@{@\"error\": @\"bad-method\"}); return; }",
      .l "NSURLSession *session = [LNHTTPFetch session:args[@\"socks\"]];",
      .l "if (!session) { answer(@{@\"error\": @\"bad-proxy\"}); return; }",
      .l "NSInteger maxBytes = LNArgNumber(args, @\"maxBytes\") ? [LNArgNumber(args, @\"maxBytes\") integerValue] : 1000000;",
      .l "if (maxBytes < 0) { answer(@{@\"error\": @\"bad-size\"}); return; }",
      .l "NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];",
      .l "request.HTTPMethod = method;",
      .l "BOOL proxied = args[@\"socks\"] && args[@\"socks\"] != NSNull.null;",
      .l "request.timeoutInterval = LNArgNumber(args, @\"timeout\") ? [LNArgNumber(args, @\"timeout\") doubleValue] : (proxied ? 90 : 30);",
      .l "id headers = args[@\"headers\"];",
      .l "if (headers && ![headers isKindOfClass:NSDictionary.class]) { answer(@{@\"error\": @\"bad-headers\"}); return; }",
      b "for (id key in (NSDictionary *)(headers ?: @{})) {" [
          .l "id value = headers[key];",
          .l "if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class] || [key rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound || [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) { answer(@{@\"error\": @\"bad-headers\"}); return; }",
          .l "[request setValue:value forHTTPHeaderField:key];"],
      .l "id bodyHex = args[@\"body\"];",
      .l "if (bodyHex && bodyHex != NSNull.null) {",
      .l "    if (![bodyHex isKindOfClass:NSString.class] || [bodyHex length] > 2097152) { answer(@{@\"error\": @\"bad-body\"}); return; }",
      .l "    NSData *body = LNDataOf(bodyHex);",
      .l "    if (!body) { answer(@{@\"error\": @\"bad-body\"}); return; }",
      .l "    request.HTTPBody = body;",
      .l "}",
      .l "[LNHTTPFetch fetch:request session:session maxBytes:maxBytes answer:answer];"] },
  { name := "app.invoke", args := "app-defined JSON object",
    result := "app-defined JSON object; `{\"error\":\"unsupported\"}` when no `LeanNativeAppCapabilities` class is linked",
    body := [
      .l "Class bridge = NSClassFromString(@\"LeanNativeAppCapabilities\");",
      .l "SEL selector = NSSelectorFromString(@\"run:answer:\");",
      .l "if (!bridge || ![bridge respondsToSelector:selector]) { answer(@{@\"error\": @\"unsupported\"}); return; }",
      .l "void (*run)(id, SEL, NSDictionary *, void (^)(NSDictionary *)) = (void *)[bridge methodForSelector:selector];",
      .l "run(bridge, selector, args, answer);" ] },
  { name := "open", args := "`url`", result := "`{\"ok\":…}` opens the URL outside the app",
    body := [
      .l "NSURL *url = [NSURL URLWithString:LNArgString(args, @\"url\") ?: @\"\"];",
      .blk [("if (url) {", [
            .l "[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];",
            .l "answer(@{@\"ok\": @YES});"]), ("} else {", [
            .l "answer(@{@\"ok\": @NO});"])] "}"] },
  { name := "ble.state", args := "—",
    result := "`{\"state\":…}`: `poweredOn`, `poweredOff`, `unauthorized`, `unsupported`, `resetting` or `unknown`",
    body := [.l "[[LNBluetooth shared] state:answer];"] },
  { name := "ble.scan", args := "`services` (UUIDs), `seconds`? (s, 4)",
    result := "`{\"ok\":true,\"devices\":[{\"id\",\"name\",\"rssi\"}]}` (`name` the advertised local name, else the peripheral's, or null; `rssi` in dBm, null for a peripheral the system already holds connected) for every peripheral advertising one of the services within `seconds` (at most 30), without connecting; or `{\"ok\":false,\"error\":…}` (a Bluetooth state, `busy` while another scan or a connection is being made, `no-services`)",
    body := [.l "[[LNBluetooth shared] scan:args answer:answer];"] },
  { name := "ble.connect", args := "`services` (UUIDs), `timeout`? (s, 45)",
    result := "`{\"ok\":true,\"id\",\"name\",\"service\",\"characteristics\"}` (`name` the peripheral's advertised name, or null) for the first peripheral offering one of the services (one the system already holds connected, else the first found by a scan), or `{\"ok\":false,\"error\":…}` (a Bluetooth state, `timeout`, `refused`, `busy`, …)",
    body := [.l "[[LNBluetooth shared] connect:args answer:answer];"] },
  { name := "ble.subscribe", args := "`id`, `characteristic`, `timeout`? (s, 90)",
    result := "`{\"ok\":…}` once notifications are on: iOS pairs on the first encrypted access, so this can wait on the user",
    body := [.l "[[LNBluetooth shared] subscribe:args answer:answer];"] },
  { name := "ble.write", args := "`id`, `characteristic`, `hex`, `response`? (true), `timeout`? (s, 15)",
    result := "`{\"ok\":…}`; with `response`, after the peripheral acknowledges",
    body := [.l "[[LNBluetooth shared] write:args answer:answer];"] },
  { name := "ble.read", args := "`id`, `characteristic`, `timeout`? (s, 30)",
    result := "`{\"hex\":…}`: the next notified value, in arrival order per characteristic; or `{\"error\":\"timeout\"|\"disconnected\"}`",
    body := [.l "[[LNBluetooth shared] read:args answer:answer];"] },
  { name := "ble.close", args := "`id`",
    result := "`{\"ok\":true}` disconnects; requests waiting on the peripheral fail with `disconnected`",
    body := [.l "[[LNBluetooth shared] close:args answer:answer];"] },
  { name := "bgtask.schedule", args := "`id`, `kind`? (`refresh` or `processing`; `refresh`), `after`? (s from now), `requiresNetwork`?, `requiresPower`? (processing only)",
    result := "`{\"ok\":true}` or `{\"ok\":false,\"error\",\"detail\",\"code\"?}` (`unavailable`, `tooManyPending`, `notPermitted`, `immediateRunIneligible`, `badArgs`, `unknown`); replaces any request of that `id`, which must be in Info.plist's `BGTaskSchedulerPermittedIdentifiers`. iOS decides when, and whether, it runs; under Mac Catalyst every request answers `unavailable`",
    body := [.l "[LNBackgroundTasks.shared schedule:args answer:answer];"] },
  { name := "bgtask.complete", args := "`id`, `success`, `tag`? (the launch's, from `{\"bgtask\":…}`)",
    result := "`{\"ok\":true}`, or `{\"ok\":false,\"error\":\"notPending\"}` when no task of that `id` is running (never launched, completed, or completed by the shell a second after it expired) or, with a `tag`, the one running is a later launch's (an older run's late answer does not end its successor); without a `tag`, whatever task of that `id` is running is completed",
    body := [.l "[LNBackgroundTasks.shared complete:args answer:answer];"] },
  { name := "bgtask.continue", args := "`id` (under a wildcard identifier of Info.plist, one per piece of work), `title`, `subtitle`?, `strategy`? (`queue` or `fail`; `queue`)",
    result := "`{\"ok\":true}` or `{\"ok\":false,\"error\",\"detail\",\"code\"?}` (`unavailable` before iOS 26 and on the Mac, `notPermitted`, `tooManyPending`, `immediateRunIneligible`, `badArgs`, `unknown`). Continued processing: work a person started, which iOS lets finish after they leave the app, shown with its progress in a Live Activity they can cancel. Asked for while the app is in front; the launch is `{\"bgtask\":{\"id\",\"kind\":\"continued\",\"tag\"}}`",
    body := [.l "[LNBackgroundTasks.shared continueWork:args answer:answer];"] },
  { name := "bgtask.progress", args := "`id`, `tag`?, `completed`?, `total`?, `title`?, `subtitle`?",
    result := "`{\"ok\":true}`, or `{\"ok\":false,\"error\":\"notPending\"}` when no continued task of that `id` (and `tag`) is running. iOS expires continued work that reports no progress; the work's end is `bgtask.complete`",
    body := [.l "[LNBackgroundTasks.shared progress:args answer:answer];"] },
  { name := "bgtask.refreshStatus", args := "—",
    result := "`{\"status\":…}`: `available`, `denied` (Background App Refresh off for the app) or `restricted`",
    body := [
      b "switch (UIApplication.sharedApplication.backgroundRefreshStatus) {" [
          .l "case UIBackgroundRefreshStatusAvailable: answer(@{@\"status\": @\"available\"}); break;",
          .l "case UIBackgroundRefreshStatusDenied: answer(@{@\"status\": @\"denied\"}); break;",
          .l "default: answer(@{@\"status\": @\"restricted\"}); break;"]] },
  { name := "cloudkit.account", args := "`container`? (an identifier; the app's default container)",
    result := "`{\"status\":…,\"user\":…}`: `available` (with `user`, the account's record name), `noAccount`, `restricted`, `couldNotDetermine` or `temporarilyUnavailable` (`user` null); or an error. Every `cloudkit.*` error is `{\"error\",\"code\",\"detail\",\"retryAfter\"?}`, named as `CKErrorCode` (`notAuthenticated`, `networkUnavailable`, `quotaExceeded`, `serverRecordChanged`, …; `notFound` for an unknown item), or `missingEntitlement` without the iCloud entitlement, `badArgs`",
    body := [.l "[LNCloudKit.shared account:args answer:answer];"] },
  { name := "cloudkit.query", args := "`type`, `equals`? (`{field: value}`, all must hold), `sortBy`?, `ascending`? (true), `keys`? (fields to fetch; all), `limit`? (100, at most 500), `container`?",
    result := "`{\"records\":[{\"name\",\"type\",\"fields\",\"modified\",\"tag\"}…],\"more\":…}` from the private database, following cursors up to `limit`. A field is a string, a number, `{\"date\":s}` (since 1970), `{\"hex\":…}` (bytes), a list of those, `{\"asset\":true}` or `{\"ref\":name}`",
    body := [.l "[LNCloudKit.shared query:args answer:answer];"] },
  { name := "cloudkit.save", args := "`type`, `name` (the record name), `fields`? (as in a query), `asset`? (hex), `assetField`? (`asset`), `container`?",
    result := "`{\"ok\":true,\"record\":…}`: the record made or updated, only the given fields changed (`changedKeys`, atomic); the asset goes up from a temporary file with complete protection, removed afterwards",
    body := [.l "[LNCloudKit.shared save:args answer:answer];"] },
  { name := "cloudkit.load", args := "`name`, `maxBytes`? (of the asset; 32 MiB), `assetField`? (`asset`), `container`?",
    result := "`{\"record\":…,\"asset\":hex|null}`, or `{\"error\":\"notFound\"…}`, `{\"error\":\"tooLarge\"}`",
    body := [.l "[LNCloudKit.shared load:args answer:answer];"] },
  { name := "cloudkit.loadMany", args := "`names` (1 to 200 record names), `files`? (false: assets as hex), `maxBytes`? (of each asset; 32 MiB), `assetField`? (`asset`), `container`?",
    result := "`{\"records\":[…],\"directory\"?}`: one request to CloudKit, and an answer for each name in the order asked: `{\"name\",\"record\",\"asset\":hex}` (no `asset` when the record has none), or with `files` `{\"name\",\"record\",\"file\":path}` (a copy in `directory`, a directory of the temporary directory that is the caller's to remove), or the record's own error `{\"name\",\"error\",\"code\"?,\"detail\"?,\"retryAfter\"?}` (`notFound` only when CloudKit says the record is not there, `tooLarge`, `noAnswer`, or CloudKit's word for it). An error of the whole request answers as any `cloudkit.*` error",
    body := [.l "[LNCloudKit.shared loadMany:args answer:answer];"] },
  { name := "cloudkit.delete", args := "`name`, `container`?",
    result := "`{\"ok\":true}` (also when there was no such record), or an error",
    body := [.l "[LNCloudKit.shared remove:args answer:answer];"] },
  { name := "push.register", args := "—",
    result := "`{\"token\":hex,\"environment\"}`: the device's token for Apple's push notifications (`registerForRemoteNotifications`) and which of Apple's gateways it is for, `development` or `production`, from the app's `aps-environment` entitlement; or `{\"error\"}`: `missingEntitlement` (no entitlement: Apple is not asked), `failed` (Apple's refusal, with `code` and `detail`), `timeout` (no word from Apple in thirty seconds). The app's server sends by that token. A notice that arrives is the system event `{\"push\":{\"tag\",\"state\",\"payload\"}}` (`state`: `active`, `inactive`, `background`; `payload`: what of the notice JSON can carry), answered with `push.complete`; one that arrives with the app in front is `{\"pushPresented\":{\"payload\"}}` (nothing is shown), and one tapped is `{\"pushOpened\":{\"payload\"}}`",
    body := [.l "[LNPush.shared registerDevice:args answer:answer];"] },
  { name := "push.unregister", args := "—",
    result := "`{\"ok\":true}`: Apple is told to send this app no more notices (`unregisterForRemoteNotifications`), and tells a server that still sends that the token is dead. For an app that leaves when its server cannot be told; `push.register` afterwards gives a token again",
    body := [.l "[LNPush.shared unregisterDevice:args answer:answer];"] },
  { name := "push.permission", args := "—",
    result := "`{\"status\":…}` whether notices may be shown: `notDetermined` (never asked), `denied`, `authorized`, `provisional` or `ephemeral`. A notice with `content-available` wakes the app whatever this says",
    body := [.l "[LNPush.shared permission:args answer:answer];"] },
  { name := "push.ask", args := "`alert`?, `sound`?, `badge`? (each true unless said false)",
    result := "`{\"granted\":bool}` the system's question whether the app may show notices, which iOS puts once; afterwards the answer is the person's standing choice, with no question. Ask from something the person did",
    body := [.l "[LNPush.shared ask:args answer:answer];"] },
  { name := "push.complete", args := "`tag` (the notice's, from `{\"push\":…}`), `result`? (`newData`, `noData` or `failed`; `noData`)",
    result := "`{\"ok\":true}`: iOS is told the app has done with the notice (it waits about thirty seconds, and gives an app that answers sooner more such wakes); or `{\"ok\":false,\"error\":\"notPending\"}` when it was answered already, by the app or by the shell (which tells the app `{\"pushExpired\":{\"tag\"}}` at twenty-four seconds and answers `failed` a second later)",
    body := [.l "[LNPush.shared complete:args answer:answer];"] } ]


def unknownCapability : List Stmt := [
    .l "answer(@{@\"error\": [NSString stringWithFormat:@\"unknown capability %@\", name]});"]

def capabilitiesDoc : List String :=
  [ "What only iOS can do, offered to every LeanNative native app by name. The app asks with",
    "`Effects.cap name args`; the answer goes back as JSON. Nothing here knows the app.", "",
    "| name | args | result |", "|---|---|---|" ] ++
  capabilities.map fun c => s!"| `{c.name}` | {c.args} | {c.result} |"

set_option maxRecDepth 8000 in
def capsBefore : List Stmt := [
    .pp "#import \"LeanNativeShell.h\"",
    .pp "#import <LocalAuthentication/LocalAuthentication.h>",
    .pp "#import <AuthenticationServices/AuthenticationServices.h>",
    .pp "#import <Security/Security.h>",
    .pp "#import <CoreBluetooth/CoreBluetooth.h>",
    .pp "#import <Network/Network.h>",
    .pp "#import <Network/NSURLSession+Network.h>",
    .pp "#import <BackgroundTasks/BackgroundTasks.h>",
    .pp "#import <CloudKit/CloudKit.h>",
    .pp "#import <UserNotifications/UserNotifications.h>",
    .pp "#import <mach-o/dyld.h>",
    .pp "#import <mach-o/getsect.h>",
    .pp "#import <mach-o/loader.h>",
    .blank,
    .l "/// One request's receiving: its limit, the body so far, whether it passed the limit, and its answer. Touched",
    .l "/// only on its session's delegate queue once the task has started.",
    .l "@interface LNHTTPTransfer : NSObject",
    .l "@property (nonatomic) NSInteger maxBytes;",
    .l "@property (nonatomic, strong, nullable) NSMutableData *body;",
    .l "@property (nonatomic) BOOL tooLarge;",
    .l "@property (nonatomic, copy) void (^answer)(NSDictionary *);",
    .l "@end",
    .blank,
    .l "@implementation LNHTTPTransfer",
    .l "@end",
    .blank,
    .l "/// The ephemeral URLSessions of `http.get` and `http.request`: no cookies, no cache, redirects only within the",
    .l "/// same origin (scheme, host and port). One shared session without a proxy, and one per SOCKS5 proxy",
    .l "/// (`host:port`), kept for the life of the app (a session is never invalidated while a request might still use",
    .l "/// it). Each session's delegate is its own `LNHTTPFetch`, which receives the bodies: a body is counted as it",
    .l "/// arrives and its transfer cancelled once it passes the request's `maxBytes`, so no more than that is held.",
    .l "@interface LNHTTPFetch : NSObject <NSURLSessionDataDelegate>",
    .l "+ (nullable NSURLSession *)session:(nullable id)socks;",
    .l "+ (void)fetch:(NSURLRequest *)request session:(NSURLSession *)session maxBytes:(NSInteger)maxBytes answer:(void (^)(NSDictionary *))answer;",
    .l "@end",
    .blank,
    .l "/// The port a URL is reached on: the one written, else its scheme's (443 for https, 80 for http).",
    b "static NSInteger LNPortOf(NSURL *url) {" [
        .l "if (url.port) return url.port.integerValue;",
        .l "NSString *scheme = url.scheme.lowercaseString;",
        .l "return [scheme isEqualToString:@\"https\"] ? 443 : [scheme isEqualToString:@\"http\"] ? 80 : -1;"],
    .blank,
    b "@implementation LNHTTPFetch {" [
        .l "/// the requests in flight on this delegate's session, by task identifier",
        .l "NSMutableDictionary<NSNumber *, LNHTTPTransfer *> *_transfers;"],
    .blank,
    b "- (instancetype)init {" [
        .l "if ((self = [super init])) _transfers = [NSMutableDictionary dictionary];",
        .l "return self;"],
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
            .l "direct = [NSURLSession sessionWithConfiguration:[self configuration] delegate:[LNHTTPFetch new] delegateQueue:nil];",
            .l "proxied = [NSMutableDictionary dictionary];"] "});",
        .l "if (!socks || socks == NSNull.null) return direct;",
        .l "if (![socks isKindOfClass:NSDictionary.class]) return nil;",
        .l "NSString *host = LNArgString(socks, @\"host\");",
        .l "NSNumber *port = LNArgNumber(socks, @\"port\");",
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
            .l "session = [NSURLSession sessionWithConfiguration:config delegate:[LNHTTPFetch new] delegateQueue:nil];",
            .l "proxied[key] = session;",
            .l "return session;"]],
    .blank,
    .l "/// Runs `request` on `session` (one of `session:`'s) and answers on the main queue: `{status, body}`, or",
    .l "/// `{error}`: `tooLarge` once the body is known to pass `maxBytes`, `response` for no HTTP response, else the",
    .l "/// system's error with its `code` and `domain`.",
    b "+ (void)fetch:(NSURLRequest *)request session:(NSURLSession *)session maxBytes:(NSInteger)maxBytes answer:(void (^)(NSDictionary *))answer {" [
        .l "LNHTTPFetch *fetch = (LNHTTPFetch *)session.delegate;",
        .l "LNHTTPTransfer *transfer = [LNHTTPTransfer new];",
        .l "transfer.maxBytes = maxBytes;",
        .l "transfer.body = [NSMutableData data];",
        .l "transfer.answer = answer;",
        .l "NSURLSessionDataTask *task = [session dataTaskWithRequest:request];",
        .l "@synchronized (fetch) { fetch->_transfers[@(task.taskIdentifier)] = transfer; }",
        .l "[task resume];"],
    .blank,
    b "- (nullable LNHTTPTransfer *)transfer:(NSURLSessionTask *)task {" [
        .l "@synchronized (self) { return _transfers[@(task.taskIdentifier)]; }"],
    .blank,
    .l "- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response",
    b "        completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {" [
        .l "LNHTTPTransfer *transfer = [self transfer:dataTask];",
        .l "// a body the server declares to be over the limit is refused before any of it is received. The declared",
        .l "// length of an encoded body (gzip) is not the length of what arrives, so that one is only counted.",
        .l "NSString *encoding = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@\"Content-Encoding\"] : nil;",
        .l "BOOL plain = encoding.length == 0 || [encoding caseInsensitiveCompare:@\"identity\"] == NSOrderedSame;",
        b "if (transfer && plain && response.expectedContentLength > (long long)transfer.maxBytes) {" [
            .l "transfer.tooLarge = YES;",
            .l "completionHandler(NSURLSessionResponseCancel);",
            .l "return;"],
        .l "completionHandler(NSURLSessionResponseAllow);"],
    .blank,
    b "- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {" [
        .l "LNHTTPTransfer *transfer = [self transfer:dataTask];",
        .l "if (!transfer || transfer.tooLarge) return;",
        .l "// past the limit: nothing more is received or kept",
        b "if ((NSInteger)(transfer.body.length + data.length) > transfer.maxBytes) {" [
            .l "transfer.tooLarge = YES;",
            .l "transfer.body = nil;",
            .l "[dataTask cancel];",
            .l "return;"],
        .l "[transfer.body appendData:data];"],
    .blank,
    b "- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {" [
        .l "LNHTTPTransfer *transfer;",
        b "@synchronized (self) {" [
            .l "transfer = _transfers[@(task.taskIdentifier)];",
            .l "[_transfers removeObjectForKey:@(task.taskIdentifier)];"],
        .l "if (!transfer) return;",
        .l "NSDictionary *result;",
        .blk [("if (transfer.tooLarge || (NSInteger)transfer.body.length > transfer.maxBytes) {", [
              .l "result = @{@\"error\": @\"tooLarge\"};"]), ("} else if (error) {", [
              .l "result = @{@\"error\": error.localizedDescription ?: @\"\", @\"code\": @(error.code), @\"domain\": error.domain ?: @\"\"};"]), ("} else if ([task.response isKindOfClass:NSHTTPURLResponse.class]) {", [
              .l "result = @{@\"status\": @(((NSHTTPURLResponse *)task.response).statusCode), @\"body\": LNHexOf(transfer.body)};"]), ("} else {", [
              .l "result = @{@\"error\": @\"response\"};"])] "}",
        .l "void (^answer)(NSDictionary *) = transfer.answer;",
        .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"],
    .blank,
    .l "/// A redirect is followed only to the origin it came from: the same scheme, host and port (the scheme's own",
    .l "/// port when none is written). Another port of the same host is another server, which the request's headers",
    .l "/// (a bearer token, say) were not meant for; and a change of scheme is refused with it, https to http included.",
    .l "- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response",
    b "        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {" [
        .l "NSURL *to = request.URL, *from = response.URL;",
        .l "BOOL sameScheme = to.scheme && from.scheme && [to.scheme caseInsensitiveCompare:from.scheme] == NSOrderedSame;",
        .l "BOOL sameHost = to.host && from.host && [to.host caseInsensitiveCompare:from.host] == NSOrderedSame;",
        .l "BOOL samePort = LNPortOf(to) == LNPortOf(from);",
        .l "completionHandler(sameScheme && sameHost && samePort ? request : nil);"],
    .blank,
    .l "@end",
    .blank,
    b "@implementation LNCapabilities {" [
        .l "/// The authentications `auth` kept (`keep`), by id: each its context and when it ends (the system's uptime).",
        .l "/// Main thread only, as every capability is.",
        .l "NSMutableDictionary<NSString *, NSArray *> *_kept;"],
    .blank,
    .l "/// Whether a keychain request is about iCloud Keychain items (`synchronizable`: true).",
    b "- (BOOL)synchronizable:(NSDictionary *)args {" [
        .l "return [LNArgNumber(args, @\"synchronizable\") boolValue];"],
    .blank,
    .l "/// The item named by `key` within `service` (the app's bundle id unless the app names one). Without",
    .l "/// `synchronizable` the query names no kSecAttrSynchronizable, so it matches this device's items only; with",
    .l "/// it, only iCloud Keychain items.",
    b "- (NSMutableDictionary *)base:(NSDictionary *)args {" [
        .l "NSString *service = LNArgString(args, @\"service\") ?: (NSBundle.mainBundle.bundleIdentifier ?: @\"leannative\");",
        .l "NSMutableDictionary *query = [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: service,",
        .l "                                (__bridge id)kSecAttrAccount: LNArgString(args, @\"key\") ?: @\"\"} mutableCopy];",
        .l "if ([self synchronizable:args]) query[(__bridge id)kSecAttrSynchronizable] = @YES;",
        .l "return query;"],
    .blank]

set_option maxRecDepth 8000 in
/-- The kept authentications (`auth` with `keep`), for `auth.*` and for `keychain.*`, whose reads run under one:
methods of `LNCapabilities`. They name LocalAuthentication, so an app with neither family does not get them (nor,
then, the framework). -/
def keptContexts : List Stmt := [
    .l "/// Keeps an authentication for `seconds`, under a new id nobody can guess: the Keychain reads that name it run",
    .l "/// under `context`. It ends (`[context invalidate]`, its id unknown from then on) at the first of `auth.end`, its",
    .l "/// time, and the app entering the background; not when the app resigns active, which the Face ID sheet itself",
    .l "/// causes. Any number of reads may use it until then.",
    b "- (NSString *)keepContext:(LAContext *)context seconds:(NSTimeInterval)seconds {" [
        b "if (!_kept) {" [
            .l "_kept = [NSMutableDictionary dictionary];",
            .l "// the app's entering the background, and its scene's (the shell has one scene: the same moment)",
            .l "for (NSNotificationName left in @[UIApplicationDidEnterBackgroundNotification, UISceneDidEnterBackgroundNotification])",
            .l "    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(endContexts) name:left object:nil];"],
        .l "NSString *name = NSUUID.UUID.UUIDString;",
        .l "_kept[name] = @[context, @(NSProcessInfo.processInfo.systemUptime + seconds)];",
        .l "__weak typeof(self) weak = self;",
        .l "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weak endContext:name]; });",
        .l "return name;"],
    .blank,
    b "- (void)endContext:(nullable NSString *)name {" [
        .l "NSArray *kept = name ? _kept[name] : nil;",
        .l "if (!kept) return;",
        .l "[(LAContext *)kept[0] invalidate];",
        .l "[_kept removeObjectForKey:name];"],
    .blank,
    b "- (void)endContexts {" [
        .l "for (NSString *name in _kept.allKeys) [self endContext:name];"],
    .blank,
    .l "/// The kept authentication an id names, while it lives: nil for one that has ended, or never was, which a request",
    .l "/// that names it is then answered as one that names none.",
    b "- (nullable LAContext *)liveContext:(nullable NSString *)name {" [
        .l "NSArray *kept = name ? _kept[name] : nil;",
        .l "if (!kept) return nil;",
        .l "if (NSProcessInfo.processInfo.systemUptime >= [kept[1] doubleValue]) { [self endContext:name]; return nil; }",
        .l "return kept[0];"],
    .blank]

set_option maxRecDepth 8000 in
/-- What `keychain.*` needs for an item behind the person's presence: methods of `LNCapabilities`, for an app that
uses the family. -/
def keychainAccess : List Stmt := [
    .l "/// A keychain request's `access`: 0 when absent or `unlocked` (the protection class alone), 1 for `userPresence`",
    .l "/// (an access control: the person, for every read of the value), -1 for anything else, which is refused.",
    b "- (int)access:(NSDictionary *)args {" [
        .l "id access = args[@\"access\"];",
        .l "if (!access || access == NSNull.null) return 0;",
        .l "if (![access isKindOfClass:NSString.class]) return -1;",
        .l "if ([access isEqualToString:@\"unlocked\"]) return 0;",
        .l "return [access isEqualToString:@\"userPresence\"] ? 1 : -1;"],
    .blank,
    .l "/// An authentication context that allows no interaction. Every keychain call that reads an item, or rewrites one",
    .l "/// that is there, runs under one, or under a kept authentication (`liveContext:`), itself made so: the Keychain",
    .l "/// never asks the person from inside a capability, and never holds the main thread for their answer. What it",
    .l "/// would have asked for, it refuses (errSecInteractionNotAllowed, -25308).",
    b "- (LAContext *)noInteraction {" [
        .l "LAContext *context = [LAContext new];",
        .l "context.interactionNotAllowed = YES;",
        .l "return context;"],
    .blank,
    .l "/// What puts an item behind the person's presence: an access control in place of a protection class (this device",
    .l "/// only, while unlocked, and Face ID, Touch ID or the passcode for every read of the value), and the marker",
    .l "/// `marked:` reads back, since an access control cannot be. nil, with `status`, when the system makes none.",
    b "- (nullable NSDictionary *)userPresence:(OSStatus *)status {" [
        .l "CFErrorRef error = NULL;",
        .l "SecAccessControlRef control = SecAccessControlCreateWithFlags(NULL, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecAccessControlUserPresence, &error);",
        .l "OSStatus failed = error ? (OSStatus)CFErrorGetCode(error) : errSecParam;",
        .l "if (error) CFRelease(error);",
        b "if (!control) {" [
            .l "*status = failed == errSecSuccess ? errSecParam : failed;",
            .l "return nil;"],
        .l "return @{(__bridge id)kSecAttrAccessControl: (__bridge_transfer id)control,",
        .l "         (__bridge id)kSecAttrGeneric: [@\"user-presence\" dataUsingEncoding:NSUTF8StringEncoding]};"],
    .blank,
    .l "/// Whether an item's attributes carry the marker of one behind the person's presence (kSecAttrGeneric).",
    b "- (BOOL)marked:(nullable NSDictionary *)attributes {" [
        .l "return [attributes[(__bridge id)kSecAttrGeneric] isEqual:[@\"user-presence\" dataUsingEncoding:NSUTF8StringEncoding]];"],
    .blank,
    .l "/// Whether the Keychain's refusal to give an item's attributes says the item is behind an access control. A",
    .l "/// device's Keychain gives nothing of such an item to a query that allows no interaction, not even its",
    .l "/// attributes (errSecInteractionNotAllowed), so the marker cannot be read there; a simulator's gives them. The",
    .l "/// same status is what a locked device answers for any item, so it counts only while protected data is",
    .l "/// available, which is to say while the device is unlocked.",
    b "- (BOOL)heldBack:(OSStatus)status {" [
        .l "return status == errSecInteractionNotAllowed && UIApplication.sharedApplication.isProtectedDataAvailable;"],
    .blank,
    .l "/// An item's attributes and never its value (kSecReturnAttributes), which the Keychain gives without anyone's",
    .l "/// authentication; nil, with `status`, when there is no such item or the Keychain refuses.",
    b "- (nullable NSDictionary *)attributes:(NSDictionary *)args status:(OSStatus *)status {" [
        .l "NSMutableDictionary *query = [self base:args];",
        .l "query[(__bridge id)kSecReturnAttributes] = @YES;",
        .l "query[(__bridge id)kSecUseAuthenticationContext] = [self liveContext:LNArgString(args, @\"context\")] ?: [self noInteraction];",
        .l "if ([self synchronizable:args]) query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;",
        .l "CFTypeRef out = NULL;",
        .l "*status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &out);",
        .l "NSDictionary *attributes = *status == errSecSuccess ? (__bridge_transfer NSDictionary *)out : nil;",
        .l "return [attributes isKindOfClass:NSDictionary.class] ? attributes : nil;"],
    .blank]

/-- The arguments of a request, by kind (nil when absent or of another JSON kind). -/
def argHelpers : List Stmt := [
    b "static NSString *LNArgString(NSDictionary *args, NSString *k) {" [
        .l "return [args[k] isKindOfClass:NSString.class] ? args[k] : nil;"],
    .blank,
    b "static NSNumber *LNArgNumber(NSDictionary *args, NSString *k) {" [
        .l "return [args[k] isKindOfClass:NSNumber.class] ? args[k] : nil;"],
    .blank,
    .l "/// How a capability answers: once, on the main queue.",
    .l "typedef void (^LNAnswer)(NSDictionary *result);",
    .blank,
    .l "/// Lowercase hex of some bytes, and back (nil unless every character is a hex digit and they pair up).",
    b "static NSString *LNHexOf(NSData *data) {" [
        .l "static const char digits[] = \"0123456789abcdef\";",
        .l "const unsigned char *bytes = data.bytes;",
        .l "NSMutableData *out = [NSMutableData dataWithLength:data.length * 2];",
        .l "char *p = out.mutableBytes;",
        .l "for (NSUInteger i = 0; i < data.length; i++) { p[2 * i] = digits[bytes[i] >> 4]; p[2 * i + 1] = digits[bytes[i] & 15]; }",
        .l "return [[NSString alloc] initWithData:out encoding:NSASCIIStringEncoding] ?: @\"\";"],
    .blank,
    b "static int LNNibble(unichar c) {" [
        .l "if (c >= '0' && c <= '9') return c - '0';",
        .l "if (c >= 'a' && c <= 'f') return c - 'a' + 10;",
        .l "if (c >= 'A' && c <= 'F') return c - 'A' + 10;",
        .l "return -1;"],
    .blank,
    b "static NSData *LNDataOf(NSString *hex) {" [
        .l "if (hex.length % 2 != 0) return nil;",
        .l "NSMutableData *data = [NSMutableData dataWithLength:hex.length / 2];",
        .l "unsigned char *bytes = data.mutableBytes;",
        b "for (NSUInteger i = 0; i < hex.length; i += 2) {" [
            .l "int hi = LNNibble([hex characterAtIndex:i]), lo = LNNibble([hex characterAtIndex:i + 1]);",
            .l "if (hi < 0 || lo < 0) return nil;",
            .l "bytes[i / 2] = (unsigned char)(hi << 4 | lo);"],
        .l "return data;"],
    .blank,
    ]

set_option maxRecDepth 8000 in
/-- `LNAuthErrorName`, for `auth` alone: it names LocalAuthentication's errors, so an app without `auth`
does not get it (nor, then, the framework). -/
def authErrorName : List Stmt := [
    .l "/// An `LAError`'s name for `auth` (`unknown` for any other error, or none).",
    b "static NSString *LNAuthErrorName(NSError *error) {" [
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
    .blank]

set_option maxRecDepth 8000 in
/-- `LNWebAuth`, for `webauth` alone: the one `ASWebAuthenticationSession` at a time, held until it ends, and the
window it is presented from. An app without `webauth` does not get it (nor AuthenticationServices). -/
def webAuthClass : List Stmt := [
    .l "/// A sign-in in the system browser (`webauth`): one session at a time, kept alive until it answers.",
    .l "@interface LNWebAuth : NSObject <ASWebAuthenticationPresentationContextProviding>",
    .l "+ (instancetype)shared;",
    .l "- (void)start:(NSURL *)url host:(nullable NSString *)host path:(nullable NSString *)path scheme:(nullable NSString *)scheme",
    .l "    ephemeral:(BOOL)ephemeral answer:(LNAnswer)answer;",
    .l "@end",
    .blank,
    b "@implementation LNWebAuth {" [
        .l "ASWebAuthenticationSession *_session;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static LNWebAuth *shared;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ shared = [LNWebAuth new]; });",
        .l "return shared;"],
    .blank,
    .l "/// An `ASWebAuthenticationSessionError`'s name (`unknown` for any other error).",
    b "static NSString *LNWebAuthErrorName(NSError *error) {" [
        .l "if (![error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain]) return @\"unknown\";",
        b "switch ((ASWebAuthenticationSessionErrorCode)error.code) {" [
            .l "case ASWebAuthenticationSessionErrorCodeCanceledLogin: return @\"canceledLogin\";",
            .l "case ASWebAuthenticationSessionErrorCodePresentationContextNotProvided: return @\"presentationContextNotProvided\";",
            .l "case ASWebAuthenticationSessionErrorCodePresentationContextInvalid: return @\"presentationContextInvalid\";",
            .l "default: return @\"unknown\";"]],
    .blank,
    .l "/// The window the browser sheet is presented from: the key window of a foreground scene, else any window.",
    b "- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {" [
        .l "UIWindow *any = nil;",
        b "for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {" [
            .l "if (![scene isKindOfClass:UIWindowScene.class]) continue;",
            .l "UIWindow *key = ((UIWindowScene *)scene).keyWindow;",
            .l "if (key && scene.activationState == UISceneActivationStateForegroundActive) return key;",
            .l "if (key && !any) any = key;"],
        .l "return any ?: [UIWindow new];"],
    .blank,
    b "- (void)start:(NSURL *)url host:(NSString *)host path:(NSString *)path scheme:(NSString *)scheme ephemeral:(BOOL)ephemeral answer:(LNAnswer)answer {" [
        .l "if (_session) { answer(@{@\"ok\": @NO, @\"error\": @\"A sign-in is already open.\", @\"name\": @\"busy\"}); return; }",
        .l "void (^done)(NSURL *, NSError *) = ^(NSURL *callback, NSError *error) {",
        .l "    NSDictionary *result = callback ? @{@\"ok\": @YES, @\"url\": callback.absoluteString}",
        .l "        : @{@\"ok\": @NO, @\"error\": error.localizedDescription ?: @\"The sign-in did not finish.\",",
        .l "            @\"name\": LNWebAuthErrorName(error), @\"code\": @(error.code), @\"domain\": error.domain ?: @\"\"};",
        .l "    dispatch_async(dispatch_get_main_queue(), ^{ self->_session = nil; answer(result); });",
        .l "};",
        .l "ASWebAuthenticationSession *session = nil;",
        b "if (host.length > 0 && path.length > 0) {" [
            b "if (@available(iOS 17.4, *)) {" [
                .l "session = [[ASWebAuthenticationSession alloc] initWithURL:url",
                .l "    callback:[ASWebAuthenticationSessionCallback callbackWithHTTPSHost:host path:path] completionHandler:done];"],
            b "else {" [
                .l "answer(@{@\"ok\": @NO, @\"error\": @\"An https callback needs iOS 17.4.\", @\"name\": @\"unsupported\"});",
                .l "return;"]],
        b "else if (scheme.length > 0) {" [
            .l "session = [[ASWebAuthenticationSession alloc] initWithURL:url callbackURLScheme:scheme completionHandler:done];"],
        b "else {" [
            .l "answer(@{@\"ok\": @NO, @\"error\": @\"Name an https callback (host and path) or a callback scheme.\", @\"name\": @\"bad-callback\"});",
            .l "return;"],
        .l "session.prefersEphemeralWebBrowserSession = ephemeral;",
        .l "session.presentationContextProvider = self;",
        .l "_session = session;",
        b "if (![session start]) {" [
            .l "_session = nil;",
            .l "answer(@{@\"ok\": @NO, @\"error\": @\"The sign-in could not start.\", @\"name\": @\"presentationContextInvalid\"});"]],
    .blank,
    .l "@end"]

set_option maxRecDepth 8000 in
def bluetoothClass : List Stmt := [
    .l "/// Bluetooth Low Energy (GATT) for the `ble.*` capabilities: generic, by service and characteristic UUIDs;",
    .l "/// what the bytes mean is the app's. One central manager, made on the first `ble.*` request so that an app",
    .l "/// that never uses Bluetooth never asks for it. Callbacks arrive on the main queue, like every answer.",
    .l "@interface LNBluetooth : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>",
    .l "+ (instancetype)shared;",
    .l "- (void)state:(LNAnswer)answer;",
    .l "- (void)scan:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)connect:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)subscribe:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)write:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)read:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)close:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "@end",
    .blank,
    b "static NSString *LNStateName(CBManagerState state) {" [
        b "switch (state) {" [
            .l "case CBManagerStatePoweredOn: return @\"poweredOn\";",
            .l "case CBManagerStatePoweredOff: return @\"poweredOff\";",
            .l "case CBManagerStateUnauthorized: return @\"unauthorized\";",
            .l "case CBManagerStateUnsupported: return @\"unsupported\";",
            .l "case CBManagerStateResetting: return @\"resetting\";",
            .l "default: return @\"unknown\";"]],
    .blank,
    .l "/// A request waiting for a callback, with the deadline that answers it instead.",
    .l "@interface LNPending : NSObject",
    .l "@property (nonatomic, copy) LNAnswer answer;",
    .l "@property (nonatomic, strong) dispatch_block_t deadline;",
    .l "@end",
    .blank,
    .l "@implementation LNPending",
    .l "@end",
    .blank,
    b "@implementation LNBluetooth {" [
        .l "CBCentralManager *_central;",
        .l "NSMutableArray<void (^)(void)> *_whenReady;",
        .l "NSMutableDictionary<NSString *, CBPeripheral *> *_peripherals;",
        .l "// the connection being made: its services, its peripheral once found, its answer",
        .l "NSArray<CBUUID *> *_connectServices;",
        .l "CBPeripheral *_connecting;",
        .l "LNPending *_connect;",
        .l "// the scan being made (no connection): what it has seen, by peripheral id, and its answer",
        .l "NSMutableDictionary<NSString *, NSDictionary *> *_scanSeen;",
        .l "LNPending *_scan;",
        .l "// per \"peripheral id|characteristic uuid\": requests in flight, and notified values not yet read",
        .l "NSMutableDictionary<NSString *, LNPending *> *_subscribes;",
        .l "NSMutableDictionary<NSString *, NSMutableArray<LNPending *> *> *_writes;",
        .l "NSMutableDictionary<NSString *, NSMutableArray<LNPending *> *> *_reads;",
        .l "NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_values;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static LNBluetooth *shared;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ shared = [LNBluetooth new]; });",
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
    b "- (LNPending *)pending:(LNAnswer)answer timeout:(NSTimeInterval)seconds onTimeout:(void (^)(LNPending *p))expire {" [
        .l "LNPending *p = [LNPending new];",
        .l "p.answer = answer;",
        .l "__weak LNPending *weakP = p;",
        b "p.deadline = dispatch_block_create(0, ^{" [
            .l "LNPending *q = weakP;",
            .l "if (q) expire(q);"] "});",
        .l "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), p.deadline);",
        .l "return p;"],
    .blank,
    b "- (void)settle:(LNPending *)p with:(NSDictionary *)result {" [
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
    b "static NSTimeInterval LNSeconds(NSDictionary *args, NSString *k, NSTimeInterval dflt) {" [
        .l "return [args[k] isKindOfClass:NSNumber.class] ? [args[k] doubleValue] : dflt;"],
    .blank,
    b "- (void)state:(LNAnswer)answer {" [
        .l "[self ready:^{ answer(@{@\"state\": LNStateName(self->_central.state)}); }];"],
    .blank,
    b "- (void)scan:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSArray<CBUUID *> *services = ELUUIDs(args[@\"services\"]);",
        .l "if (services.count == 0) { answer(@{@\"ok\": @NO, @\"error\": @\"no-services\"}); return; }",
        .l "if (_scan || _connect) { answer(@{@\"ok\": @NO, @\"error\": @\"busy\"}); return; }",
        .l "NSTimeInterval seconds = MIN(MAX(LNSeconds(args, @\"seconds\", 4), 0.5), 30);",
        b "[self ready:^{" [
            b "if (self->_central.state != CBManagerStatePoweredOn) {" [
                .l "answer(@{@\"ok\": @NO, @\"error\": LNStateName(self->_central.state)});",
                .l "return;"],
            .l "if (self->_scan || self->_connect) { answer(@{@\"ok\": @NO, @\"error\": @\"busy\"}); return; }",
            .l "self->_scanSeen = [NSMutableDictionary dictionary];",
            .l "// the peripherals the system already holds connected do not advertise: they are reported as they are",
            b "for (CBPeripheral *p in [self->_central retrieveConnectedPeripheralsWithServices:services]) {" [
                .l "self->_scanSeen[p.identifier.UUIDString] = @{@\"id\": p.identifier.UUIDString, @\"name\": (id)p.name ?: NSNull.null, @\"rssi\": NSNull.null};"],
            b "self->_scan = [self pending:answer timeout:seconds onTimeout:^(LNPending *p) {" [
                .l "// a connection begun meanwhile scans for its own peripheral: its scan is left running",
                .l "if (!self->_connect) [self->_central stopScan];",
                .l "NSArray *devices = self->_scanSeen.allValues;",
                .l "self->_scan = nil;",
                .l "self->_scanSeen = nil;",
                .l "[self settle:p with:@{@\"ok\": @YES, @\"devices\": devices}];"] "}];",
            .l "[self->_central scanForPeripheralsWithServices:services options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];"] "}];"],
    .blank,
    b "- (void)connect:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSArray<CBUUID *> *services = ELUUIDs(args[@\"services\"]);",
        .l "if (services.count == 0) { answer(@{@\"ok\": @NO, @\"error\": @\"no-services\"}); return; }",
        .l "if (_connect) { answer(@{@\"ok\": @NO, @\"error\": @\"busy\"}); return; }",
        .l "NSTimeInterval timeout = LNSeconds(args, @\"timeout\", 45);",
        b "[self ready:^{" [
            b "if (self->_central.state != CBManagerStatePoweredOn) {" [
                .l "answer(@{@\"ok\": @NO, @\"error\": LNStateName(self->_central.state)});",
                .l "return;"],
            .l "self->_connectServices = services;",
            b "self->_connect = [self pending:answer timeout:timeout onTimeout:^(LNPending *p) {" [
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
        .l "LNPending *p = _connect;",
        .l "_connect = nil;",
        .l "_connecting = nil;",
        .l "_connectServices = nil;",
        .l "if (p) [self settle:p with:result];"],
    .blank,
    b "- (void)subscribe:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "CBPeripheral *peripheral = _peripherals[args[@\"id\"] ?: @\"\"];",
        .l "CBUUID *uuid = [args[@\"characteristic\"] isKindOfClass:NSString.class] ? [CBUUID UUIDWithString:args[@\"characteristic\"]] : nil;",
        .l "CBCharacteristic *c = uuid ? [self characteristic:uuid of:peripheral] : nil;",
        .l "if (!c) { answer(@{@\"ok\": @NO, @\"error\": peripheral ? @\"no-characteristic\" : @\"disconnected\"}); return; }",
        .l "NSString *key = [self key:args[@\"id\"] characteristic:uuid];",
        .l "if (_subscribes[key]) { answer(@{@\"ok\": @NO, @\"error\": @\"busy\"}); return; }",
        .l "// the first encrypted access is where iOS pairs: the user may be comparing codes",
        b "_subscribes[key] = [self pending:answer timeout:LNSeconds(args, @\"timeout\", 90) onTimeout:^(LNPending *p) {" [
            .l "[self->_subscribes removeObjectForKey:key];",
            .l "[self settle:p with:@{@\"ok\": @NO, @\"error\": @\"timeout\"}];"] "}];",
        .l "[peripheral setNotifyValue:YES forCharacteristic:c];"],
    .blank,
    b "- (void)write:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "CBPeripheral *peripheral = _peripherals[args[@\"id\"] ?: @\"\"];",
        .l "CBUUID *uuid = [args[@\"characteristic\"] isKindOfClass:NSString.class] ? [CBUUID UUIDWithString:args[@\"characteristic\"]] : nil;",
        .l "CBCharacteristic *c = uuid ? [self characteristic:uuid of:peripheral] : nil;",
        .l "NSData *data = [args[@\"hex\"] isKindOfClass:NSString.class] ? LNDataOf(args[@\"hex\"]) : nil;",
        .l "if (!c) { answer(@{@\"ok\": @NO, @\"error\": peripheral ? @\"no-characteristic\" : @\"disconnected\"}); return; }",
        .l "if (!data) { answer(@{@\"ok\": @NO, @\"error\": @\"bad-hex\"}); return; }",
        .l "BOOL response = [args[@\"response\"] isKindOfClass:NSNumber.class] ? [args[@\"response\"] boolValue] : YES;",
        b "if (!response) {" [
            .l "[peripheral writeValue:data forCharacteristic:c type:CBCharacteristicWriteWithoutResponse];",
            .l "answer(@{@\"ok\": @YES});",
            .l "return;"],
        .l "NSString *key = [self key:args[@\"id\"] characteristic:uuid];",
        .l "if (!_writes[key]) _writes[key] = [NSMutableArray array];",
        .l "__block LNPending *mine = nil;",
        b "mine = [self pending:answer timeout:LNSeconds(args, @\"timeout\", 15) onTimeout:^(LNPending *p) {" [
            .l "[self->_writes[key] removeObject:p];",
            .l "[self settle:p with:@{@\"ok\": @NO, @\"error\": @\"timeout\"}];"] "}];",
        .l "[_writes[key] addObject:mine];",
        .l "[peripheral writeValue:data forCharacteristic:c type:CBCharacteristicWriteWithResponse];"],
    .blank,
    b "- (void)read:(NSDictionary *)args answer:(LNAnswer)answer {" [
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
        b "LNPending *p = [self pending:answer timeout:LNSeconds(args, @\"timeout\", 30) onTimeout:^(LNPending *q) {" [
            .l "[self->_reads[key] removeObject:q];",
            .l "[self settle:q with:@{@\"error\": @\"timeout\"}];"] "}];",
        .l "[_reads[key] addObject:p];"],
    .blank,
    b "- (void)close:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "CBPeripheral *peripheral = _peripherals[args[@\"id\"] ?: @\"\"];",
        .l "if (peripheral) [_central cancelPeripheralConnection:peripheral];",
        .l "answer(@{@\"ok\": @YES});"],
    .blank,
    .l "/// Everything waiting on a peripheral that went away fails, and its unread values are dropped.",
    b "- (void)drop:(NSString *)peripheral {" [
        .l "NSString *prefix = [peripheral stringByAppendingString:@\"|\"];",
        .l "for (NSString *key in _subscribes.allKeys)",
        .l "    if ([key hasPrefix:prefix]) { LNPending *p = _subscribes[key]; [_subscribes removeObjectForKey:key]; [self settle:p with:@{@\"ok\": @NO, @\"error\": @\"disconnected\"}]; }",
        .l "for (NSString *key in _writes.allKeys)",
        .l "    if ([key hasPrefix:prefix]) { NSArray *ps = _writes[key]; [_writes removeObjectForKey:key]; for (LNPending *p in ps) [self settle:p with:@{@\"ok\": @NO, @\"error\": @\"disconnected\"}]; }",
        .l "for (NSString *key in _reads.allKeys)",
        .l "    if ([key hasPrefix:prefix]) { NSArray *ps = _reads[key]; [_reads removeObjectForKey:key]; for (LNPending *p in ps) [self settle:p with:@{@\"error\": @\"disconnected\"}]; }",
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
            .l "if (_connect) [self endConnect:@{@\"ok\": @NO, @\"error\": LNStateName(central.state)}];",
            b "if (_scan) {" [
                .l "LNPending *p = _scan;",
                .l "_scan = nil;",
                .l "_scanSeen = nil;",
                .l "[self settle:p with:@{@\"ok\": @NO, @\"error\": LNStateName(central.state)}];"],
            .l "for (NSString *id_ in _peripherals.allKeys) [self drop:id_];"]],
    .blank,
    .l "- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral",
    b "     advertisementData:(NSDictionary<NSString *, id> *)advertisementData RSSI:(NSNumber *)RSSI {" [
        b "if (_scanSeen) {" [
            .l "NSString *id_ = peripheral.identifier.UUIDString;",
            .l "id name = advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name;",
            .l "_scanSeen[id_] = @{@\"id\": id_, @\"name\": name ?: NSNull.null, @\"rssi\": RSSI ?: NSNull.null};"],
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
        .l "[self endConnect:@{@\"ok\": @YES, @\"id\": id_, @\"name\": (id)peripheral.name ?: NSNull.null, @\"service\": service.UUID.UUIDString, @\"characteristics\": uuids}];"],
    .blank,
    .l "- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic",
    b "             error:(NSError *)error {" [
        .l "NSString *key = [self key:peripheral.identifier.UUIDString characteristic:characteristic.UUID];",
        .l "LNPending *p = _subscribes[key];",
        .l "if (!p) return;",
        .l "[_subscribes removeObjectForKey:key];",
        .l "[self settle:p with:error ? @{@\"ok\": @NO, @\"error\": error.localizedDescription ?: @\"refused\"} : @{@\"ok\": @YES}];"],
    .blank,
    b "- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {" [
        .l "NSString *key = [self key:peripheral.identifier.UUIDString characteristic:characteristic.UUID];",
        .l "NSMutableArray<LNPending *> *ps = _writes[key];",
        .l "if (ps.count == 0) return;",
        .l "LNPending *p = ps.firstObject;",
        .l "[ps removeObjectAtIndex:0];",
        .l "[self settle:p with:error ? @{@\"ok\": @NO, @\"error\": error.localizedDescription ?: @\"refused\"} : @{@\"ok\": @YES}];"],
    .blank,
    b "- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {" [
        .l "if (error || !characteristic.value) return;",
        .l "NSString *key = [self key:peripheral.identifier.UUIDString characteristic:characteristic.UUID];",
        .l "NSString *hex = LNHexOf(characteristic.value);",
        .l "NSMutableArray<LNPending *> *readers = _reads[key];",
        b "if (readers.count > 0) {" [
            .l "LNPending *p = readers.firstObject;",
            .l "[readers removeObjectAtIndex:0];",
            .l "[self settle:p with:@{@\"hex\": hex}];",
            .l "return;"],
        .l "if (!_values[key]) _values[key] = [NSMutableArray array];",
        .l "[_values[key] addObject:hex];"],
    .blank,
    .l "@end"]

/-- The statements before the first declaration: the imports. -/
def capsImports : Nat := (capsBefore.findIdx? fun | .l _ | .blk .. => true | _ => false).getD 0

/-- Whether `uses` (`auth`, `ble.*`, `ble.connect`) selects the capability named `name`. `auth` selects
`auth.end` with it: an app that asks for an authentication can end one the shell kept for it, and an app
written before there was an `auth.end` lists only `auth`. -/
def selects (uses : List String) (name : String) : Bool :=
  uses.any fun u => u == name || (u.endsWith ".*" && (u.splitOn ".").headD u == (name.splitOn ".").headD name)
    || (u == "auth" && name == "auth.end")

/-- `LNCapabilities.m` for an app that uses `uses` (none: every capability, which `leannative-shell` prints).
Only what a selected capability needs is printed: without `auth` and without a `keychain.*` capability (whose reads
run under an authentication context, so that the Keychain never asks the person itself) there is no LocalAuthentication, without `webauth`
no AuthenticationServices and no `LNWebAuth`, and without a `ble.*` capability no CoreBluetooth and no `LNBluetooth`, so the binary does not link a framework that App Store
Connect then asks a purpose string for. Without a `push.*` capability there is no UserNotifications, no `LNPush` and none of the app
delegate's push methods: Apple writes to the developer of a binary that has those and no push entitlement. Any other request answers `unknownCapability`, and
`Manifest.callProblems` already refuses an app whose code calls a capability `uses` leaves out. -/
def capsFileFor (uses : Option (List String)) : List Stmt :=
  let chosen := match uses with
    | none => capabilities
    | some us => capabilities.filter (selects us ·.name)
  let has (fam : String) := chosen.any fun c => (c.name.splitOn ".").headD c.name == fam
  let auth := has "auth"
  let keychain := has "keychain"
  let webauth := chosen.any (·.name == "webauth")
  let ble := has "ble"
  let push := has "push"
  let imports := (capsBefore.take capsImports).filter fun
    | .pp t => (auth || keychain || !t.contains "LocalAuthentication") && (ble || !t.contains "CoreBluetooth")
        && (webauth || !t.contains "AuthenticationServices") && (push || !t.contains "UserNotifications")
    | _ => true
  imports ++ argHelpers ++ (if ble then bluetoothClass ++ [.blank] else []) ++ (if webauth then webAuthClass ++ [.blank] else []) ++
  backgroundTasksClass ++ [.blank] ++
  cloudKitClass ++ [.blank] ++ (if push then pushClass ++ [.blank] else []) ++ (if auth then authErrorName else []) ++ capsBefore.drop capsImports ++
  (if auth || keychain then keptContexts else []) ++ (if keychain then keychainAccess else []) ++
  [ b "- (void)run:(NSString *)name args:(NSDictionary *)args answer:(void (^)(NSDictionary *))answer {"
      [ ifChain "" (chosen.map (fun c => (s!"[name isEqualToString:{lit c.name}]", c.body)) ++ [("", unknownCapability)]) ] ] ++
  [
    .blank,
    .l "@end"]

def capsFile : List Stmt := capsFileFor none

/-- The comment at the top of every printed shell file. -/
def shellHeader (name : String) : List String :=
  [ s!"GENERATED by leannative-shell ({name}) from framework/lean/LeanNativeShell (Lean {Lean.versionString}). Do not edit:",
    "framework/native/scripts/ios_lean_sources.sh writes it on every build." ]

end LeanNativeShell
