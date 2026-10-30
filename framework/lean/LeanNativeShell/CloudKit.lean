import LeanNativeShell.ObjC

/-! # LeanNativeShell.CloudKit: `LNCloudKit`, in `LNCapabilities.m`

The `cloudkit.*` capabilities: records in the private database of a CloudKit container (the app's default
one, or `container`), in its default zone. What the records mean is the app's.

A field's JSON is a string, a number (CloudKit keeps integers and doubles apart as JSON does),
`{"date":s}` (seconds since 1970), `{"hex":…}` (bytes) or a list of those; a record answers as
`{"name","type","fields","modified","tag"}`, its fields in the same JSON (an asset as `{"asset":true}`, a
reference as `{"ref":name}`). One asset per record travels as bytes: `asset` (hex) on save, under
`assetField` (`asset`), written to a temporary file with complete file protection and removed when the
save ends; and back from `cloudkit.load`.

Errors answer `{"error":name,"code":n,"detail":…}` with `retryAfter` (s) when CloudKit gives one; the name
is the `CKErrorCode` case (`notAuthenticated`, `networkUnavailable`, `networkFailure`, `quotaExceeded`,
`serverRecordChanged`, …, with `unknownItem` as `notFound`), and a partial failure answers its record's
own error.

Without the iCloud entitlement CloudKit kills the app (a trap, not an exception) when the container is
made, so the shell reads the app's own entitlements first, from its signature (iOS has no public API for
them): the simulator keeps them in the executable's `__TEXT,__entitlements` section, a device in the
entitlements blob of the code signature. Without `com.apple.developer.icloud-services` holding `CloudKit`,
or with the container (`iCloud.<bundle id>` for the default) missing from
`com.apple.developer.icloud-container-identifiers`, every request answers `missingEntitlement` and
CloudKit is never touched. An exception CloudKit raises is still caught, as `missingEntitlement` too. -/

namespace LeanNativeShell

set_option maxRecDepth 8000 in
def cloudKitClass : List Stmt := [
    .l "@interface LNCloudKit : NSObject",
    .l "+ (instancetype)shared;",
    .l "- (void)account:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)query:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)save:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)load:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "- (void)remove:(NSDictionary *)args answer:(LNAnswer)answer;",
    .l "@end",
    .blank,
    b "static uint32_t LNBig32(const uint8_t *p) {" [
        .l "return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];"],
    .blank,
    .l "/// The app's own entitlements (empty when it has none or they cannot be read): the simulator's",
    .l "/// `__TEXT,__entitlements` section of the executable, else the entitlements blob of its code signature",
    .l "/// (a SuperBlob in `__LINKEDIT`, which dyld maps; big-endian).",
    b "static NSDictionary *LNEntitlements(void) {" [
        .l "static NSDictionary *entitlements;",
        .l "static dispatch_once_t once;",
        b "dispatch_once(&once, ^{" [
            .l "const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);",
            .l "NSData *xml = nil;",
            .l "unsigned long size = 0;",
            .l "uint8_t *section = header ? getsectiondata(header, \"__TEXT\", \"__entitlements\", &size) : NULL;",
            .l "if (section && size > 0) xml = [NSData dataWithBytes:section length:size];",
            b "if (!xml && header && header->magic == MH_MAGIC_64) {" [
                .l "const struct segment_command_64 *linkedit = NULL;",
                .l "const struct linkedit_data_command *signature = NULL;",
                .l "const uint8_t *cursor = (const uint8_t *)(header + 1);",
                b "for (uint32_t i = 0; i < header->ncmds; i++) {" [
                    .l "const struct load_command *lc = (const struct load_command *)cursor;",
                    .l "if (lc->cmd == LC_SEGMENT_64 && strncmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT, 16) == 0)",
                    .l "    linkedit = (const struct segment_command_64 *)lc;",
                    .l "if (lc->cmd == LC_CODE_SIGNATURE) signature = (const struct linkedit_data_command *)lc;",
                    .l "cursor += lc->cmdsize;"],
                b "if (linkedit && signature && signature->dataoff >= linkedit->fileoff && (uint64_t)signature->dataoff + signature->datasize <= linkedit->fileoff + linkedit->filesize) {" [
                    .l "const uint8_t *blob = (const uint8_t *)(_dyld_get_image_vmaddr_slide(0) + linkedit->vmaddr + (signature->dataoff - linkedit->fileoff));",
                    .l "uint32_t length = signature->datasize;",
                    .l "// a SuperBlob (0xfade0cc0): magic, length, count, then a (type, offset) per blob",
                    b "if (length >= 12 && LNBig32(blob) == 0xfade0cc0) {" [
                        .l "uint32_t count = LNBig32(blob + 8);",
                        b "for (uint32_t i = 0; i < count && 12 + 8 * (uint64_t)(i + 1) <= length; i++) {" [
                            .l "uint32_t type = LNBig32(blob + 12 + 8 * i), offset = LNBig32(blob + 16 + 8 * i);",
                            .l "// slot 5: the entitlements, an XML plist after an 8-byte blob header (0xfade7171)",
                            .l "if (type != 5 || (uint64_t)offset + 8 > length) continue;",
                            .l "uint32_t blobLength = LNBig32(blob + offset + 4);",
                            .l "if (LNBig32(blob + offset) == 0xfade7171 && blobLength >= 8 && (uint64_t)offset + blobLength <= length)",
                            .l "    xml = [NSData dataWithBytes:blob + offset + 8 length:blobLength - 8];"]]]],
            .l "id plist = xml ? [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:nil] : nil;",
            .l "entitlements = [plist isKindOfClass:NSDictionary.class] ? plist : @{};"] "});",
        .l "return entitlements;"],
    .blank,
    .l "/// Why CloudKit would kill the app for this container (nil when the entitlements allow it).",
    b "static NSString *LNCloudKitMissing(NSString *identifier) {" [
        .l "NSDictionary *entitlements = LNEntitlements();",
        .l "NSArray *services = entitlements[@\"com.apple.developer.icloud-services\"];",
        .l "NSArray *containers = entitlements[@\"com.apple.developer.icloud-container-identifiers\"];",
        .l "if (![services isKindOfClass:NSArray.class] || !([services containsObject:@\"CloudKit\"] || [services containsObject:@\"CloudKit-Anonymous\"]))",
        .l "    return @\"no CloudKit in the com.apple.developer.icloud-services entitlement\";",
        .l "NSString *wanted = identifier.length ? identifier : [@\"iCloud.\" stringByAppendingString:NSBundle.mainBundle.bundleIdentifier ?: @\"\"];",
        .l "if (![containers isKindOfClass:NSArray.class] || ![containers containsObject:wanted])",
        .l "    return [NSString stringWithFormat:@\"%@ is not in the com.apple.developer.icloud-container-identifiers entitlement\", wanted];",
        .l "return nil;"],
    .blank,
    b "static NSString *LNCloudErrorName(NSInteger code) {" [
        b "switch (code) {" [
            .l "case CKErrorInternalError: return @\"internalError\";",
            .l "case CKErrorPartialFailure: return @\"partialFailure\";",
            .l "case CKErrorNetworkUnavailable: return @\"networkUnavailable\";",
            .l "case CKErrorNetworkFailure: return @\"networkFailure\";",
            .l "case CKErrorBadContainer: return @\"badContainer\";",
            .l "case CKErrorServiceUnavailable: return @\"serviceUnavailable\";",
            .l "case CKErrorRequestRateLimited: return @\"requestRateLimited\";",
            .l "case CKErrorMissingEntitlement: return @\"missingEntitlement\";",
            .l "case CKErrorNotAuthenticated: return @\"notAuthenticated\";",
            .l "case CKErrorPermissionFailure: return @\"permissionFailure\";",
            .l "case CKErrorUnknownItem: return @\"notFound\";",
            .l "case CKErrorInvalidArguments: return @\"invalidArguments\";",
            .l "case CKErrorServerRecordChanged: return @\"serverRecordChanged\";",
            .l "case CKErrorServerRejectedRequest: return @\"serverRejectedRequest\";",
            .l "case CKErrorAssetFileNotFound: return @\"assetFileNotFound\";",
            .l "case CKErrorAssetFileModified: return @\"assetFileModified\";",
            .l "case CKErrorIncompatibleVersion: return @\"incompatibleVersion\";",
            .l "case CKErrorConstraintViolation: return @\"constraintViolation\";",
            .l "case CKErrorOperationCancelled: return @\"operationCancelled\";",
            .l "case CKErrorBatchRequestFailed: return @\"batchRequestFailed\";",
            .l "case CKErrorZoneBusy: return @\"zoneBusy\";",
            .l "case CKErrorBadDatabase: return @\"badDatabase\";",
            .l "case CKErrorQuotaExceeded: return @\"quotaExceeded\";",
            .l "case CKErrorZoneNotFound: return @\"zoneNotFound\";",
            .l "case CKErrorLimitExceeded: return @\"limitExceeded\";",
            .l "case CKErrorUserDeletedZone: return @\"userDeletedZone\";",
            .l "case CKErrorManagedAccountRestricted: return @\"managedAccountRestricted\";",
            .l "case CKErrorAccountTemporarilyUnavailable: return @\"accountTemporarilyUnavailable\";",
            .l "default: return @\"unknown\";"]],
    .blank,
    .l "/// `{\"error\",\"code\",\"detail\",\"retryAfter\"?}`; a partial failure answers its (one) record's error.",
    b "static NSDictionary *LNCloudError(NSError *error) {" [
        b "if ([error.domain isEqualToString:CKErrorDomain] && error.code == CKErrorPartialFailure) {" [
            .l "NSDictionary *items = error.userInfo[CKPartialErrorsByItemIDKey];",
            .l "NSError *item = [items isKindOfClass:NSDictionary.class] ? items.allValues.firstObject : nil;",
            .l "if ([item isKindOfClass:NSError.class]) error = item;"],
        .l "NSString *name = [error.domain isEqualToString:CKErrorDomain] ? LNCloudErrorName(error.code) : @\"unknown\";",
        .l "NSMutableDictionary *out = [@{@\"error\": name, @\"code\": @(error.code), @\"detail\": error.localizedDescription ?: @\"\"} mutableCopy];",
        .l "NSNumber *retry = error.userInfo[CKErrorRetryAfterKey];",
        .l "if ([retry isKindOfClass:NSNumber.class]) out[@\"retryAfter\"] = retry;",
        .l "return out;"],
    .blank,
    b "static NSDictionary *LNBadArgs(NSString *detail) {" [
        .l "return @{@\"error\": @\"badArgs\", @\"detail\": detail};"],
    .blank,
    .l "/// A field's value from its JSON (nil for anything else).",
    b "static id LNCloudValue(id json) {" [
        .l "if ([json isKindOfClass:NSString.class] || [json isKindOfClass:NSNumber.class]) return json;",
        b "if ([json isKindOfClass:NSDictionary.class]) {" [
            .l "NSNumber *date = LNArgNumber(json, @\"date\");",
            .l "if (date) return [NSDate dateWithTimeIntervalSince1970:date.doubleValue];",
            .l "NSString *hex = LNArgString(json, @\"hex\");",
            .l "if (hex) return LNDataOf(hex);",
            .l "return nil;"],
        b "if ([json isKindOfClass:NSArray.class]) {" [
            .l "NSMutableArray *list = [NSMutableArray array];",
            b "for (id item in json) {" [
                .l "id value = LNCloudValue(item);",
                .l "if (!value || [value isKindOfClass:NSArray.class]) return nil;",
                .l "[list addObject:value];"],
            .l "return list;"],
        .l "return nil;"],
    .blank,
    .l "/// A field's JSON (nil for a kind it has no JSON for: a location, say).",
    b "static id LNCloudJSON(id value) {" [
        .l "if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;",
        .l "if ([value isKindOfClass:NSDate.class]) return @{@\"date\": @([(NSDate *)value timeIntervalSince1970])};",
        .l "if ([value isKindOfClass:NSData.class]) return @{@\"hex\": LNHexOf(value)};",
        .l "if ([value isKindOfClass:CKAsset.class]) return @{@\"asset\": @YES};",
        .l "if ([value isKindOfClass:CKReference.class]) return @{@\"ref\": [(CKReference *)value recordID].recordName};",
        b "if ([value isKindOfClass:NSArray.class]) {" [
            .l "NSMutableArray *list = [NSMutableArray array];",
            .l "for (id item in value) { id j = LNCloudJSON(item); if (j) [list addObject:j]; }",
            .l "return list;"],
        .l "return nil;"],
    .blank,
    b "static NSDictionary *LNCloudRecord(CKRecord *record) {" [
        .l "NSMutableDictionary *fields = [NSMutableDictionary dictionary];",
        .l "for (NSString *key in record.allKeys) { id j = LNCloudJSON(record[key]); if (j) fields[key] = j; }",
        .l "return @{@\"name\": record.recordID.recordName, @\"type\": record.recordType, @\"fields\": fields,",
        .l "         @\"modified\": record.modificationDate ? @(record.modificationDate.timeIntervalSince1970) : NSNull.null,",
        .l "         @\"tag\": record.recordChangeTag ?: NSNull.null};"],
    .blank,
    .l "/// Answers on the main queue, as every capability does.",
    b "static void LNOnMain(LNAnswer answer, NSDictionary *result) {" [
        .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"],
    .blank,
    b "@implementation LNCloudKit {" [
        .l "// by container identifier (\"\" for the default container)",
        .l "NSMutableDictionary<NSString *, CKContainer *> *_containers;",
        .l "NSMutableDictionary<NSString *, NSString *> *_failed;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static LNCloudKit *shared;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ shared = [LNCloudKit new]; });",
        .l "return shared;"],
    .blank,
    b "- (instancetype)init {" [
        b "if ((self = [super init])) {" [
            .l "_containers = [NSMutableDictionary dictionary];",
            .l "_failed = [NSMutableDictionary dictionary];"],
        .l "return self;"],
    .blank,
    .l "/// The container of a request, or nil after answering `missingEntitlement`: CloudKit raises when the app",
    .l "/// lacks the iCloud entitlement or the container is not among its identifiers. Made once per identifier.",
    b "- (nullable CKContainer *)container:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSString *identifier = LNArgString(args, @\"container\") ?: @\"\";",
        .l "CKContainer *container = _containers[identifier];",
        .l "if (container) return container;",
        b "if (!_failed[identifier]) {" [
            .l "// CloudKit traps on a missing entitlement: it is never asked then",
            .l "NSString *missing = LNCloudKitMissing(identifier);",
            .l "if (missing) _failed[identifier] = missing;",
            .blk [("@try {", [
                  .l "if (!missing) container = identifier.length ? [CKContainer containerWithIdentifier:identifier] : [CKContainer defaultContainer];"]),
                 ("} @catch (NSException *e) {", [
                  .l "_failed[identifier] = e.reason ?: e.name;"])] "}",
            .l "if (container) _containers[identifier] = container;",
            .l "else if (!_failed[identifier]) _failed[identifier] = @\"no container\";"],
        .l "if (container) return container;",
        .l "answer(@{@\"error\": @\"missingEntitlement\", @\"detail\": _failed[identifier]});",
        .l "return nil;"],
    .blank,
    .l "/// Runs `work` on the request's private database; an exception CloudKit raises answers `missingEntitlement`.",
    b "- (void)with:(NSDictionary *)args answer:(LNAnswer)answer run:(void (^)(CKContainer *container, CKDatabase *db))work {" [
        .l "CKContainer *container = [self container:args answer:answer];",
        .l "if (!container) return;",
        .blk [("@try {", [
              .l "work(container, container.privateCloudDatabase);"]), ("} @catch (NSException *e) {", [
              .l "answer(@{@\"error\": @\"missingEntitlement\", @\"detail\": e.reason ?: e.name});"])] "}"],
    .blank,
    b "- (void)account:(NSDictionary *)args answer:(LNAnswer)answer {" [
        b "[self with:args answer:answer run:^(CKContainer *container, CKDatabase *db) {" [
            b "[container accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError *error) {" [
                .l "if (error) { LNOnMain(answer, LNCloudError(error)); return; }",
                .l "NSString *name = @\"couldNotDetermine\";",
                b "switch (status) {" [
                    .l "case CKAccountStatusAvailable: name = @\"available\"; break;",
                    .l "case CKAccountStatusNoAccount: name = @\"noAccount\"; break;",
                    .l "case CKAccountStatusRestricted: name = @\"restricted\"; break;",
                    .l "case CKAccountStatusTemporarilyUnavailable: name = @\"temporarilyUnavailable\"; break;",
                    .l "default: break;"],
                .l "if (status != CKAccountStatusAvailable) { LNOnMain(answer, @{@\"status\": name, @\"user\": NSNull.null}); return; }",
                .l "// the account's record name: an app binds its records to it, and notices when the account changes",
                b "[container fetchUserRecordIDWithCompletionHandler:^(CKRecordID *user, NSError *userError) {" [
                    .l "LNOnMain(answer, userError ? LNCloudError(userError) : @{@\"status\": name, @\"user\": user.recordName ?: NSNull.null});"] "}];"] "}];"] "}];"],
    .blank,
    b "- (void)query:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSString *type = LNArgString(args, @\"type\");",
        .l "if (type.length == 0) { answer(LNBadArgs(@\"a record type\")); return; }",
        .l "NSMutableArray<NSPredicate *> *terms = [NSMutableArray array];",
        .l "id equals = args[@\"equals\"];",
        .l "if (equals && ![equals isKindOfClass:NSDictionary.class]) { answer(LNBadArgs(@\"equals: an object of fields\")); return; }",
        b "for (NSString *key in (NSDictionary *)equals) {" [
            .l "id value = LNCloudValue(equals[key]);",
            .l "if (!value || [value isKindOfClass:NSArray.class]) { answer(LNBadArgs([@\"equals: \" stringByAppendingString:key])); return; }",
            .l "[terms addObject:[NSPredicate predicateWithFormat:@\"%K == %@\", key, value]];"],
        .l "NSPredicate *predicate = terms.count ? [NSCompoundPredicate andPredicateWithSubpredicates:terms] : [NSPredicate predicateWithValue:YES];",
        .l "NSString *sortBy = LNArgString(args, @\"sortBy\");",
        .l "BOOL ascending = LNArgNumber(args, @\"ascending\") ? [LNArgNumber(args, @\"ascending\") boolValue] : YES;",
        .l "CKQuery *query = nil;",
        .blk [("@try {", [
              .l "query = [[CKQuery alloc] initWithRecordType:type predicate:predicate];",
              .l "if (sortBy) query.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:sortBy ascending:ascending]];"]),
             ("} @catch (NSException *e) {", [
              .l "answer(LNBadArgs(e.reason ?: e.name));",
              .l "return;"])] "}",
        .l "NSMutableArray<NSString *> *keys = nil;",
        b "if ([args[@\"keys\"] isKindOfClass:NSArray.class]) {" [
            .l "keys = [NSMutableArray array];",
            .l "for (id k in args[@\"keys\"]) if ([k isKindOfClass:NSString.class]) [keys addObject:k];"],
        .l "NSInteger limit = LNArgNumber(args, @\"limit\") ? [LNArgNumber(args, @\"limit\") integerValue] : 100;",
        .l "limit = MAX(1, MIN(limit, 500));",
        b "[self with:args answer:answer run:^(CKContainer *container, CKDatabase *db) {" [
            .l "[self page:[[CKQueryOperation alloc] initWithQuery:query] db:db keys:keys limit:limit into:[NSMutableArray array] answer:answer];"] "}];"],
    .blank,
    .l "/// One page of a query (at most 100 records), then the next from its cursor until `limit`.",
    .l "- (void)page:(CKQueryOperation *)op db:(CKDatabase *)db keys:(NSArray<NSString *> *)keys limit:(NSInteger)limit",
    b "      into:(NSMutableArray *)records answer:(LNAnswer)answer {" [
        .l "op.desiredKeys = keys;",
        .l "op.resultsLimit = (NSUInteger)MIN(100, limit - (NSInteger)records.count);",
        .l "op.qualityOfService = NSQualityOfServiceUserInitiated;",
        .l "NSMutableArray *page = [NSMutableArray array];",
        .l "// both blocks run on the operation's own serial queue",
        b "op.recordMatchedBlock = ^(CKRecordID *recordID, CKRecord *record, NSError *error) {" [
            .l "if (record) [page addObject:LNCloudRecord(record)];"] "};",
        b "op.queryCompletionBlock = ^(CKQueryCursor *cursor, NSError *error) {" [
            .l "NSArray *got = [page copy];",
            b "dispatch_async(dispatch_get_main_queue(), ^{" [
                .l "if (error) { answer(LNCloudError(error)); return; }",
                .l "[records addObjectsFromArray:got];",
                .l "if (cursor && (NSInteger)records.count < limit)",
                .l "    [self page:[[CKQueryOperation alloc] initWithCursor:cursor] db:db keys:keys limit:limit into:records answer:answer];",
                .l "else answer(@{@\"records\": records, @\"more\": @(cursor != nil)});"] "});"] "};",
        .l "[db addOperation:op];"],
    .blank,
    b "- (void)save:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSString *type = LNArgString(args, @\"type\"), *name = LNArgString(args, @\"name\");",
        .l "if (type.length == 0 || name.length == 0) { answer(LNBadArgs(@\"a record type and name\")); return; }",
        .l "id fields = args[@\"fields\"] ?: @{};",
        .l "if (![fields isKindOfClass:NSDictionary.class]) { answer(LNBadArgs(@\"fields: an object\")); return; }",
        .l "CKRecord *record = nil;",
        .l "// CloudKit raises for a name, type or key it does not allow (a reserved key, say)",
        .blk [("@try {", [
              .l "record = [[CKRecord alloc] initWithRecordType:type recordID:[[CKRecordID alloc] initWithRecordName:name]];",
              b "for (NSString *key in (NSDictionary *)fields) {" [
                  .l "id value = LNCloudValue(fields[key]);",
                  .l "if (!value) { answer(LNBadArgs([@\"fields: \" stringByAppendingString:key])); return; }",
                  .l "record[key] = value;"]]), ("} @catch (NSException *e) {", [
              .l "answer(LNBadArgs(e.reason ?: e.name));",
              .l "return;"])] "}",
        .l "NSData *bytes = LNArgString(args, @\"asset\") ? LNDataOf(args[@\"asset\"]) : nil;",
        .l "if (args[@\"asset\"] && !bytes) { answer(LNBadArgs(@\"asset: hex\")); return; }",
        .l "CKContainer *container = [self container:args answer:answer];",
        .l "if (!container) return;",
        .l "NSURL *directory = nil;",
        b "if (bytes) {" [
            .l "// CloudKit uploads from a file: one only this request uses, readable only while unlocked",
            .l "directory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[@\"cloudkit-\" stringByAppendingString:NSUUID.UUID.UUIDString]];",
            .l "NSURL *file = [directory URLByAppendingPathComponent:@\"asset\"];",
            .l "NSError *writeError = nil;",
            .l "BOOL written = [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&writeError] &&",
            .l "               [bytes writeToURL:file options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:&writeError];",
            b "if (!written) {" [
                .l "[NSFileManager.defaultManager removeItemAtURL:directory error:nil];",
                .l "answer(@{@\"error\": @\"assetFile\", @\"detail\": writeError.localizedDescription ?: @\"\"});",
                .l "return;"],
            .l "record[LNArgString(args, @\"assetField\") ?: @\"asset\"] = [[CKAsset alloc] initWithFileURL:file];"],
        .l "CKModifyRecordsOperation *op = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[record] recordIDsToDelete:nil];",
        .l "// only the fields given change; a record of that name is made or updated, whatever its server version",
        .l "op.savePolicy = CKRecordSaveChangedKeys;",
        .l "op.atomic = YES;",
        .l "op.qualityOfService = NSQualityOfServiceUserInitiated;",
        b "op.modifyRecordsCompletionBlock = ^(NSArray<CKRecord *> *saved, NSArray<CKRecordID *> *deleted, NSError *error) {" [
            .l "if (directory) [NSFileManager.defaultManager removeItemAtURL:directory error:nil];",
            .l "CKRecord *done = saved.firstObject;",
            .l "LNOnMain(answer, error ? LNCloudError(error) : @{@\"ok\": @YES, @\"record\": done ? LNCloudRecord(done) : LNCloudRecord(record)});"] "};",
        .blk [("@try {", [
              .l "[container.privateCloudDatabase addOperation:op];"]), ("} @catch (NSException *e) {", [
              .l "if (directory) [NSFileManager.defaultManager removeItemAtURL:directory error:nil];",
              .l "answer(@{@\"error\": @\"missingEntitlement\", @\"detail\": e.reason ?: e.name});"])] "}"],
    .blank,
    b "- (void)load:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSString *name = LNArgString(args, @\"name\");",
        .l "if (name.length == 0) { answer(LNBadArgs(@\"a record name\")); return; }",
        .l "NSInteger maxBytes = LNArgNumber(args, @\"maxBytes\") ? [LNArgNumber(args, @\"maxBytes\") integerValue] : 32 * 1024 * 1024;",
        .l "NSString *assetField = LNArgString(args, @\"assetField\") ?: @\"asset\";",
        b "[self with:args answer:answer run:^(CKContainer *container, CKDatabase *db) {" [
            b "[db fetchRecordWithID:[[CKRecordID alloc] initWithRecordName:name] completionHandler:^(CKRecord *record, NSError *error) {" [
                .l "if (error || !record) { LNOnMain(answer, error ? LNCloudError(error) : @{@\"error\": @\"notFound\"}); return; }",
                .l "CKAsset *asset = [record[assetField] isKindOfClass:CKAsset.class] ? record[assetField] : nil;",
                .l "id hex = NSNull.null;",
                b "if (asset.fileURL) {" [
                    .l "NSNumber *size = nil;",
                    .l "[asset.fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];",
                    .l "if (!size || size.integerValue > maxBytes) { LNOnMain(answer, @{@\"error\": @\"tooLarge\"}); return; }",
                    .l "NSData *bytes = [NSData dataWithContentsOfURL:asset.fileURL];",
                    .l "if (!bytes) { LNOnMain(answer, @{@\"error\": @\"assetFileNotFound\"}); return; }",
                    .l "hex = LNHexOf(bytes);"],
                .l "LNOnMain(answer, @{@\"record\": LNCloudRecord(record), @\"asset\": hex});"] "}];"] "}];"],
    .blank,
    b "- (void)remove:(NSDictionary *)args answer:(LNAnswer)answer {" [
        .l "NSString *name = LNArgString(args, @\"name\");",
        .l "if (name.length == 0) { answer(LNBadArgs(@\"a record name\")); return; }",
        b "[self with:args answer:answer run:^(CKContainer *container, CKDatabase *db) {" [
            b "[db deleteRecordWithID:[[CKRecordID alloc] initWithRecordName:name] completionHandler:^(CKRecordID *recordID, NSError *error) {" [
                .l "// a record that is not there is deleted",
                .l "BOOL gone = !error || ([error.domain isEqualToString:CKErrorDomain] && error.code == CKErrorUnknownItem);",
                .l "LNOnMain(answer, gone ? @{@\"ok\": @YES} : LNCloudError(error));"] "}];"] "}];"],
    .blank,
    .l "@end"]

end LeanNativeShell
