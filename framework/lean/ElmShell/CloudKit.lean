import ElmShell.ObjC

/-! # ElmShell.CloudKit: `ELCloudKit`, in `ELCapabilities.m`

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
own error. Without the iCloud entitlement CloudKit raises an Objective-C exception (a Swift app traps on
it) when the container is made; here the exception is caught, every request answers `missingEntitlement`,
and the failure is remembered so that it is raised once. -/

namespace ElmShell

set_option maxRecDepth 8000 in
def cloudKitClass : List Stmt := [
    .l "@interface ELCloudKit : NSObject",
    .l "+ (instancetype)shared;",
    .l "- (void)account:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)query:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)save:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)load:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "- (void)remove:(NSDictionary *)args answer:(ELAnswer)answer;",
    .l "@end",
    .blank,
    b "static NSString *ELCloudErrorName(NSInteger code) {" [
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
    b "static NSDictionary *ELCloudError(NSError *error) {" [
        b "if ([error.domain isEqualToString:CKErrorDomain] && error.code == CKErrorPartialFailure) {" [
            .l "NSDictionary *items = error.userInfo[CKPartialErrorsByItemIDKey];",
            .l "NSError *item = [items isKindOfClass:NSDictionary.class] ? items.allValues.firstObject : nil;",
            .l "if ([item isKindOfClass:NSError.class]) error = item;"],
        .l "NSString *name = [error.domain isEqualToString:CKErrorDomain] ? ELCloudErrorName(error.code) : @\"unknown\";",
        .l "NSMutableDictionary *out = [@{@\"error\": name, @\"code\": @(error.code), @\"detail\": error.localizedDescription ?: @\"\"} mutableCopy];",
        .l "NSNumber *retry = error.userInfo[CKErrorRetryAfterKey];",
        .l "if ([retry isKindOfClass:NSNumber.class]) out[@\"retryAfter\"] = retry;",
        .l "return out;"],
    .blank,
    b "static NSDictionary *ELBadArgs(NSString *detail) {" [
        .l "return @{@\"error\": @\"badArgs\", @\"detail\": detail};"],
    .blank,
    .l "/// A field's value from its JSON (nil for anything else).",
    b "static id ELCloudValue(id json) {" [
        .l "if ([json isKindOfClass:NSString.class] || [json isKindOfClass:NSNumber.class]) return json;",
        b "if ([json isKindOfClass:NSDictionary.class]) {" [
            .l "NSNumber *date = ELArgNumber(json, @\"date\");",
            .l "if (date) return [NSDate dateWithTimeIntervalSince1970:date.doubleValue];",
            .l "NSString *hex = ELArgString(json, @\"hex\");",
            .l "if (hex) return ELDataOf(hex);",
            .l "return nil;"],
        b "if ([json isKindOfClass:NSArray.class]) {" [
            .l "NSMutableArray *list = [NSMutableArray array];",
            b "for (id item in json) {" [
                .l "id value = ELCloudValue(item);",
                .l "if (!value || [value isKindOfClass:NSArray.class]) return nil;",
                .l "[list addObject:value];"],
            .l "return list;"],
        .l "return nil;"],
    .blank,
    .l "/// A field's JSON (nil for a kind it has no JSON for: a location, say).",
    b "static id ELCloudJSON(id value) {" [
        .l "if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;",
        .l "if ([value isKindOfClass:NSDate.class]) return @{@\"date\": @([(NSDate *)value timeIntervalSince1970])};",
        .l "if ([value isKindOfClass:NSData.class]) return @{@\"hex\": ELHexOf(value)};",
        .l "if ([value isKindOfClass:CKAsset.class]) return @{@\"asset\": @YES};",
        .l "if ([value isKindOfClass:CKReference.class]) return @{@\"ref\": [(CKReference *)value recordID].recordName};",
        b "if ([value isKindOfClass:NSArray.class]) {" [
            .l "NSMutableArray *list = [NSMutableArray array];",
            .l "for (id item in value) { id j = ELCloudJSON(item); if (j) [list addObject:j]; }",
            .l "return list;"],
        .l "return nil;"],
    .blank,
    b "static NSDictionary *ELCloudRecord(CKRecord *record) {" [
        .l "NSMutableDictionary *fields = [NSMutableDictionary dictionary];",
        .l "for (NSString *key in record.allKeys) { id j = ELCloudJSON(record[key]); if (j) fields[key] = j; }",
        .l "return @{@\"name\": record.recordID.recordName, @\"type\": record.recordType, @\"fields\": fields,",
        .l "         @\"modified\": record.modificationDate ? @(record.modificationDate.timeIntervalSince1970) : NSNull.null,",
        .l "         @\"tag\": record.recordChangeTag ?: NSNull.null};"],
    .blank,
    .l "/// Answers on the main queue, as every capability does.",
    b "static void ELOnMain(ELAnswer answer, NSDictionary *result) {" [
        .l "dispatch_async(dispatch_get_main_queue(), ^{ answer(result); });"],
    .blank,
    b "@implementation ELCloudKit {" [
        .l "// by container identifier (\"\" for the default container)",
        .l "NSMutableDictionary<NSString *, CKContainer *> *_containers;",
        .l "NSMutableDictionary<NSString *, NSString *> *_failed;"],
    .blank,
    b "+ (instancetype)shared {" [
        .l "static ELCloudKit *shared;",
        .l "static dispatch_once_t once;",
        .l "dispatch_once(&once, ^{ shared = [ELCloudKit new]; });",
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
    b "- (nullable CKContainer *)container:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "NSString *identifier = ELArgString(args, @\"container\") ?: @\"\";",
        .l "CKContainer *container = _containers[identifier];",
        .l "if (container) return container;",
        b "if (!_failed[identifier]) {" [
            .blk [("@try {", [
                  .l "container = identifier.length ? [CKContainer containerWithIdentifier:identifier] : [CKContainer defaultContainer];"]),
                 ("} @catch (NSException *e) {", [
                  .l "_failed[identifier] = e.reason ?: e.name;"])] "}",
            .l "if (container) _containers[identifier] = container;",
            .l "else if (!_failed[identifier]) _failed[identifier] = @\"no container\";"],
        .l "if (container) return container;",
        .l "answer(@{@\"error\": @\"missingEntitlement\", @\"detail\": _failed[identifier]});",
        .l "return nil;"],
    .blank,
    .l "/// Runs `work` on the request's private database; an exception CloudKit raises answers `missingEntitlement`.",
    b "- (void)with:(NSDictionary *)args answer:(ELAnswer)answer run:(void (^)(CKContainer *container, CKDatabase *db))work {" [
        .l "CKContainer *container = [self container:args answer:answer];",
        .l "if (!container) return;",
        .blk [("@try {", [
              .l "work(container, container.privateCloudDatabase);"]), ("} @catch (NSException *e) {", [
              .l "answer(@{@\"error\": @\"missingEntitlement\", @\"detail\": e.reason ?: e.name});"])] "}"],
    .blank,
    b "- (void)account:(NSDictionary *)args answer:(ELAnswer)answer {" [
        b "[self with:args answer:answer run:^(CKContainer *container, CKDatabase *db) {" [
            b "[container accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError *error) {" [
                .l "if (error) { ELOnMain(answer, ELCloudError(error)); return; }",
                .l "NSString *name = @\"couldNotDetermine\";",
                b "switch (status) {" [
                    .l "case CKAccountStatusAvailable: name = @\"available\"; break;",
                    .l "case CKAccountStatusNoAccount: name = @\"noAccount\"; break;",
                    .l "case CKAccountStatusRestricted: name = @\"restricted\"; break;",
                    .l "case CKAccountStatusTemporarilyUnavailable: name = @\"temporarilyUnavailable\"; break;",
                    .l "default: break;"],
                .l "if (status != CKAccountStatusAvailable) { ELOnMain(answer, @{@\"status\": name, @\"user\": NSNull.null}); return; }",
                .l "// the account's record name: an app binds its records to it, and notices when the account changes",
                b "[container fetchUserRecordIDWithCompletionHandler:^(CKRecordID *user, NSError *userError) {" [
                    .l "ELOnMain(answer, userError ? ELCloudError(userError) : @{@\"status\": name, @\"user\": user.recordName ?: NSNull.null});"] "}];"] "}];"] "}];"],
    .blank,
    b "- (void)query:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "NSString *type = ELArgString(args, @\"type\");",
        .l "if (type.length == 0) { answer(ELBadArgs(@\"a record type\")); return; }",
        .l "NSMutableArray<NSPredicate *> *terms = [NSMutableArray array];",
        .l "id equals = args[@\"equals\"];",
        .l "if (equals && ![equals isKindOfClass:NSDictionary.class]) { answer(ELBadArgs(@\"equals: an object of fields\")); return; }",
        b "for (NSString *key in (NSDictionary *)equals) {" [
            .l "id value = ELCloudValue(equals[key]);",
            .l "if (!value || [value isKindOfClass:NSArray.class]) { answer(ELBadArgs([@\"equals: \" stringByAppendingString:key])); return; }",
            .l "[terms addObject:[NSPredicate predicateWithFormat:@\"%K == %@\", key, value]];"],
        .l "NSPredicate *predicate = terms.count ? [NSCompoundPredicate andPredicateWithSubpredicates:terms] : [NSPredicate predicateWithValue:YES];",
        .l "NSString *sortBy = ELArgString(args, @\"sortBy\");",
        .l "BOOL ascending = ELArgNumber(args, @\"ascending\") ? [ELArgNumber(args, @\"ascending\") boolValue] : YES;",
        .l "CKQuery *query = nil;",
        .blk [("@try {", [
              .l "query = [[CKQuery alloc] initWithRecordType:type predicate:predicate];",
              .l "if (sortBy) query.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:sortBy ascending:ascending]];"]),
             ("} @catch (NSException *e) {", [
              .l "answer(ELBadArgs(e.reason ?: e.name));",
              .l "return;"])] "}",
        .l "NSMutableArray<NSString *> *keys = nil;",
        b "if ([args[@\"keys\"] isKindOfClass:NSArray.class]) {" [
            .l "keys = [NSMutableArray array];",
            .l "for (id k in args[@\"keys\"]) if ([k isKindOfClass:NSString.class]) [keys addObject:k];"],
        .l "NSInteger limit = ELArgNumber(args, @\"limit\") ? [ELArgNumber(args, @\"limit\") integerValue] : 100;",
        .l "limit = MAX(1, MIN(limit, 500));",
        b "[self with:args answer:answer run:^(CKContainer *container, CKDatabase *db) {" [
            .l "[self page:[[CKQueryOperation alloc] initWithQuery:query] db:db keys:keys limit:limit into:[NSMutableArray array] answer:answer];"] "}];"],
    .blank,
    .l "/// One page of a query (at most 100 records), then the next from its cursor until `limit`.",
    .l "- (void)page:(CKQueryOperation *)op db:(CKDatabase *)db keys:(NSArray<NSString *> *)keys limit:(NSInteger)limit",
    b "      into:(NSMutableArray *)records answer:(ELAnswer)answer {" [
        .l "op.desiredKeys = keys;",
        .l "op.resultsLimit = (NSUInteger)MIN(100, limit - (NSInteger)records.count);",
        .l "op.qualityOfService = NSQualityOfServiceUserInitiated;",
        .l "NSMutableArray *page = [NSMutableArray array];",
        .l "// both blocks run on the operation's own serial queue",
        b "op.recordMatchedBlock = ^(CKRecordID *recordID, CKRecord *record, NSError *error) {" [
            .l "if (record) [page addObject:ELCloudRecord(record)];"] "};",
        b "op.queryCompletionBlock = ^(CKQueryCursor *cursor, NSError *error) {" [
            .l "NSArray *got = [page copy];",
            b "dispatch_async(dispatch_get_main_queue(), ^{" [
                .l "if (error) { answer(ELCloudError(error)); return; }",
                .l "[records addObjectsFromArray:got];",
                .l "if (cursor && (NSInteger)records.count < limit)",
                .l "    [self page:[[CKQueryOperation alloc] initWithCursor:cursor] db:db keys:keys limit:limit into:records answer:answer];",
                .l "else answer(@{@\"records\": records, @\"more\": @(cursor != nil)});"] "});"] "};",
        .l "[db addOperation:op];"],
    .blank,
    b "- (void)save:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "NSString *type = ELArgString(args, @\"type\"), *name = ELArgString(args, @\"name\");",
        .l "if (type.length == 0 || name.length == 0) { answer(ELBadArgs(@\"a record type and name\")); return; }",
        .l "id fields = args[@\"fields\"] ?: @{};",
        .l "if (![fields isKindOfClass:NSDictionary.class]) { answer(ELBadArgs(@\"fields: an object\")); return; }",
        .l "CKRecord *record = nil;",
        .l "// CloudKit raises for a name, type or key it does not allow (a reserved key, say)",
        .blk [("@try {", [
              .l "record = [[CKRecord alloc] initWithRecordType:type recordID:[[CKRecordID alloc] initWithRecordName:name]];",
              b "for (NSString *key in (NSDictionary *)fields) {" [
                  .l "id value = ELCloudValue(fields[key]);",
                  .l "if (!value) { answer(ELBadArgs([@\"fields: \" stringByAppendingString:key])); return; }",
                  .l "record[key] = value;"]]), ("} @catch (NSException *e) {", [
              .l "answer(ELBadArgs(e.reason ?: e.name));",
              .l "return;"])] "}",
        .l "NSData *bytes = ELArgString(args, @\"asset\") ? ELDataOf(args[@\"asset\"]) : nil;",
        .l "if (args[@\"asset\"] && !bytes) { answer(ELBadArgs(@\"asset: hex\")); return; }",
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
            .l "record[ELArgString(args, @\"assetField\") ?: @\"asset\"] = [[CKAsset alloc] initWithFileURL:file];"],
        .l "CKModifyRecordsOperation *op = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[record] recordIDsToDelete:nil];",
        .l "// only the fields given change; a record of that name is made or updated, whatever its server version",
        .l "op.savePolicy = CKRecordSaveChangedKeys;",
        .l "op.atomic = YES;",
        .l "op.qualityOfService = NSQualityOfServiceUserInitiated;",
        b "op.modifyRecordsCompletionBlock = ^(NSArray<CKRecord *> *saved, NSArray<CKRecordID *> *deleted, NSError *error) {" [
            .l "if (directory) [NSFileManager.defaultManager removeItemAtURL:directory error:nil];",
            .l "CKRecord *done = saved.firstObject;",
            .l "ELOnMain(answer, error ? ELCloudError(error) : @{@\"ok\": @YES, @\"record\": done ? ELCloudRecord(done) : ELCloudRecord(record)});"] "};",
        .blk [("@try {", [
              .l "[container.privateCloudDatabase addOperation:op];"]), ("} @catch (NSException *e) {", [
              .l "if (directory) [NSFileManager.defaultManager removeItemAtURL:directory error:nil];",
              .l "answer(@{@\"error\": @\"missingEntitlement\", @\"detail\": e.reason ?: e.name});"])] "}"],
    .blank,
    b "- (void)load:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "NSString *name = ELArgString(args, @\"name\");",
        .l "if (name.length == 0) { answer(ELBadArgs(@\"a record name\")); return; }",
        .l "NSInteger maxBytes = ELArgNumber(args, @\"maxBytes\") ? [ELArgNumber(args, @\"maxBytes\") integerValue] : 32 * 1024 * 1024;",
        .l "NSString *assetField = ELArgString(args, @\"assetField\") ?: @\"asset\";",
        b "[self with:args answer:answer run:^(CKContainer *container, CKDatabase *db) {" [
            b "[db fetchRecordWithID:[[CKRecordID alloc] initWithRecordName:name] completionHandler:^(CKRecord *record, NSError *error) {" [
                .l "if (error || !record) { ELOnMain(answer, error ? ELCloudError(error) : @{@\"error\": @\"notFound\"}); return; }",
                .l "CKAsset *asset = [record[assetField] isKindOfClass:CKAsset.class] ? record[assetField] : nil;",
                .l "id hex = NSNull.null;",
                b "if (asset.fileURL) {" [
                    .l "NSNumber *size = nil;",
                    .l "[asset.fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];",
                    .l "if (!size || size.integerValue > maxBytes) { ELOnMain(answer, @{@\"error\": @\"tooLarge\"}); return; }",
                    .l "NSData *bytes = [NSData dataWithContentsOfURL:asset.fileURL];",
                    .l "if (!bytes) { ELOnMain(answer, @{@\"error\": @\"assetFileNotFound\"}); return; }",
                    .l "hex = ELHexOf(bytes);"],
                .l "ELOnMain(answer, @{@\"record\": ELCloudRecord(record), @\"asset\": hex});"] "}];"] "}];"],
    .blank,
    b "- (void)remove:(NSDictionary *)args answer:(ELAnswer)answer {" [
        .l "NSString *name = ELArgString(args, @\"name\");",
        .l "if (name.length == 0) { answer(ELBadArgs(@\"a record name\")); return; }",
        b "[self with:args answer:answer run:^(CKContainer *container, CKDatabase *db) {" [
            b "[db deleteRecordWithID:[[CKRecordID alloc] initWithRecordName:name] completionHandler:^(CKRecordID *recordID, NSError *error) {" [
                .l "// a record that is not there is deleted",
                .l "BOOL gone = !error || ([error.domain isEqualToString:CKErrorDomain] && error.code == CKErrorUnknownItem);",
                .l "ELOnMain(answer, gone ? @{@\"ok\": @YES} : ELCloudError(error));"] "}];"] "}];"],
    .blank,
    .l "@end"]

end ElmShell
