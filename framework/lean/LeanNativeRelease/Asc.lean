import LeanNativeRelease.Jwt
import LeanNativeRelease.Policy

/-! # App Store Connect: TestFlight and App Store steps

The API (https://api.appstoreconnect.apple.com/v1) through curl, a new token for every request. The steps:

- `register-bundle-id`, `create-app`: the bundle identifier and the app record, once per app.
- `upload`: `xcrun altool --upload-app` of the exported package (the release workflow uploads itself).
- `wait-processing`: until the build is VALID.
- `notes`: the build's en-US What to Test, checked against App Store Connect's answer.
- `internal`: the build is testable by the internal group, which picks up a processed build itself.
- `external`: the build in the public-link group and submitted for beta review. A review request cannot be
  withdrawn, so no workflow runs this step: handing a build to external testers is a person's decision.
- `status`, `check`: what App Store Connect says about the build, read only.
- `appstore-status`, `appstore-attach`, `appstore-notes`, `appstore-submit`: one App Store version
  (`APPSTORE_VERSION_ID`, or the one whose string is `APPSTORE_VERSION_STRING`); submit refuses without
  `APPSTORE_CONFIRM_SUBMIT=yes`.

The build is the one `TESTFLIGHT_BUILD_ID` names, else the one with `TESTFLIGHT_MARKETING_VERSION` and
`TESTFLIGHT_BUILD_NUMBER` (waited for while Apple ingests it), else the newest upload (TestFlight only).

Retries are where App Store Connect was seen to need them: it answers 500 in bursts (a read is retried five
times, a write never, since a 500 does not say whether it was applied), an upload appears minutes after
it succeeds, and a build turns VALID a moment before it takes notes or a review submission. -/

namespace LeanNativeRelease.Asc
open Lean

structure Config where
  keyId : String
  issuer : String
  keyPath : String
  bundleId : String
  api : String := "https://api.appstoreconnect.apple.com/v1"
  version : Option String := none
  build : Option String := none
  buildId : Option String := none
  notesFile : Option String := none
  publicLinkId : Option String := none
  waitAttempts : Nat := 90
  waitSeconds : Nat := 20
  appStoreVersionId : Option String := none
  appStoreVersionString : Option String := none
  appStoreNotesFile : Option String := none
  confirmSubmit : Bool := false
  appName : Option String := none
  sku : Option String := none
  ipa : Option String := none

def Config.fromEnv : IO Config := do
  let keyId ← need "ASC_KEY_ID"
  let home := (← IO.getEnv "HOME").getD ""
  let version ← env? "TESTFLIGHT_MARKETING_VERSION"
  return { keyId, issuer := ← need "ASC_ISSUER_ID",
           keyPath := (← env? "ASC_KEY_PATH").getD s!"{home}/.appstoreconnect/private_keys/AuthKey_{keyId}.p8",
           bundleId := ← need "APP_BUNDLE_ID",
           api := (← env? "ASC_API").getD "https://api.appstoreconnect.apple.com/v1",
           version, build := ← env? "TESTFLIGHT_BUILD_NUMBER", buildId := ← env? "TESTFLIGHT_BUILD_ID",
           notesFile := ← env? "TESTFLIGHT_WHATS_NEW_FILE", publicLinkId := ← env? "TESTFLIGHT_PUBLIC_LINK_ID",
           waitAttempts := ← envNat "TESTFLIGHT_BUILD_WAIT_ATTEMPTS" 90,
           waitSeconds := ← envNat "TESTFLIGHT_BUILD_WAIT_SECONDS" 20,
           appStoreVersionId := ← env? "APPSTORE_VERSION_ID",
           appStoreVersionString := (← env? "APPSTORE_VERSION_STRING").orElse fun _ => version,
           appStoreNotesFile := ← env? "APPSTORE_WHATS_NEW_FILE",
           confirmSubmit := (← env? "APPSTORE_CONFIRM_SUBMIT") == some "yes",
           appName := ← env? "APP_NAME", sku := ← env? "APP_SKU", ipa := ← env? "APP_IPA" }

/-! ## Requests -/

/-- One request; its JSON answer (null for an empty one). A failure carries App Store Connect's answer. -/
def Config.call (c : Config) (method path : String) (body : Option Json := none) : IO Json := do
  let token ← Jwt.mint c.keyPath c.keyId c.issuer
  let mut args := #["--fail-with-body", "-sS", "-g", "-X", method,
    "-H", s!"Authorization: Bearer {token}", "-H", "Content-Type: application/json"]
  if method == "GET" then args := args ++ #["--retry", "5", "--retry-delay", "15"]
  let bodyFile ← body.mapM fun b => tempFile b.compress.toUTF8
  if let some f := bodyFile then args := args ++ #["--data-binary", s!"@{f}"]
  let out ← try IO.Process.output { cmd := "curl", args := args.push (c.api ++ path) }
    finally if let some f := bodyFile then IO.FS.removeFile f
  if out.exitCode != 0 then fail s!"{method} {path}: curl exit {out.exitCode}: {trim out.stderr}\n{trim out.stdout}"
  if (trim out.stdout).isEmpty then return .null
  match Json.parse out.stdout with
  | .ok j => pure j
  | .error e => fail s!"{method} {path}: the answer is not JSON ({e}): {trim out.stdout}"

def Config.get (c : Config) (path : String) : IO Json := c.call "GET" path

def rows (j : Json) : Array Json := arrOf (j.getObjValD "data")
def idOf (row : Json) : String := strOf (row.getObjValD "id")
def attr (row : Json) (k : String) : Json := at? row ["attributes", k]
def resource (type : String) (id : String) : Json := Json.mkObj [("type", type), ("id", id)]

/-- Tries `act` up to `times` times, `pause` seconds apart, saying why each failed. -/
partial def retrying {α} (times pause : Nat) (what : String) (act : IO α) (attempt : Nat := 1) : IO α := do
  try act catch e =>
    if attempt ≥ times then throw e
    warn s!"{what}: {e} (attempt {attempt}/{times}); retrying"
    sleepSeconds pause
    retrying times pause what act (attempt + 1)

/-! ## The app and the build -/

/-- The app record's id. A failed read must not become an empty id: 0.8.6's recovery run looked the app
up during a burst of 500s and then asked for `/builds?filter[app]=` forty times. -/
def Config.appId (c : Config) : IO String :=
  retrying 5 15 s!"app lookup for {c.bundleId}" do
    let some row := (rows (← c.get s!"/apps?filter[bundleId]={c.bundleId}"))[0]? | fail "no app record"
    pure (idOf row)

def Config.findBuild (c : Config) : IO String := do
  if let some id := c.buildId then return id
  match c.version, c.build with
  | some version, some build =>
    let aid ← c.appId
    for attempt in [1:c.waitAttempts + 1] do
      let found := rows (← c.get
        s!"/builds?filter[app]={aid}&filter[version]={build}&filter[preReleaseVersion.version]={version}&limit=2")
      if found.size > 1 then fail s!"expected one build {version} ({build}); found {found.size}"
      if let some row := found[0]? then return idOf row
      warn s!"waiting for uploaded version {version} build {build} to appear (attempt {attempt}/{c.waitAttempts})"
      sleepSeconds c.waitSeconds
    fail s!"uploaded version {version} build {build} never appeared"
  | _, _ =>
    let aid ← c.appId
    let some row := (rows (← c.get s!"/builds?filter[app]={aid}&sort=-uploadedDate&limit=1"))[0]?
      | fail "the app has no builds"
    return idOf row

def Config.processingState (c : Config) (bid : String) : IO String := do
  return strOf (at? (← c.get s!"/builds/{bid}") ["data", "attributes", "processingState"])

/-! ## TestFlight -/

def Config.registerBundleId (c : Config) : IO Unit := do
  let found := rows (← c.get s!"/bundleIds?filter[identifier]={c.bundleId}")
  if found.any (fun r => strOf (attr r "identifier") == c.bundleId) then
    say s!"bundle id {c.bundleId} is registered"
    return
  let some name := c.appName | fail "set APP_NAME to register the bundle id"
  discard <| c.call "POST" "/bundleIds" (Json.mkObj [("data", Json.mkObj [("type", "bundleIds"),
    ("attributes", Json.mkObj [("identifier", c.bundleId), ("name", name), ("platform", "IOS")])])])
  say s!"registered bundle id {c.bundleId}"

def Config.createApp (c : Config) : IO Unit := do
  if !(rows (← c.get s!"/apps?filter[bundleId]={c.bundleId}")).isEmpty then
    say "app record exists"
    return
  let some bundle := (rows (← c.get s!"/bundleIds?filter[identifier]={c.bundleId}"))[0]? | fail "register the bundle id first"
  let (some name, some sku) := (c.appName, c.sku) | fail "set APP_NAME and APP_SKU to create the app record"
  discard <| c.call "POST" "/apps" (Json.mkObj [("data", Json.mkObj [("type", "apps"),
    ("attributes", Json.mkObj [("name", name), ("bundleId", c.bundleId), ("sku", sku), ("primaryLocale", "en-US")]),
    ("relationships", Json.mkObj [("bundleId", Json.mkObj [("data", resource "bundleIds" (idOf bundle))])])])])
  say s!"created the app record for {c.bundleId}"

def Config.upload (c : Config) : IO Unit := do
  let some ipa := c.ipa | fail "set APP_IPA to the exported package"
  discard <| run "xcrun" #["altool", "--upload-app", "-f", ipa, "-t", "ios", "--apiKey", c.keyId, "--apiIssuer", c.issuer]
  say s!"uploaded {ipa}"

def Config.waitProcessing (c : Config) (bid : String) : IO Unit := do
  for _ in [0:60] do
    let state ← c.processingState bid
    say s!"build {bid}: {state}"
    if state == "VALID" then return
    if state == "FAILED" || state == "INVALID" then fail s!"build {bid} is {state}"
    sleepSeconds 30
  fail s!"build {bid} did not finish processing"

/-- The en-US localization of a list, or none; more than one is an error. -/
def enUS (found : Array Json) : IO (Option Json) := do
  let hits := found.filter (fun r => strOf (attr r "locale") == "en-US")
  if hits.size > 1 then fail s!"expected at most one en-US localization; found {hits.size}"
  return hits[0]?

/-- Sets the en-US text of a localization (`type`, under the parent `parentType` `parentId`), creating it
when there is none; App Store Connect's answer must carry the text sent. -/
def Config.setText (c : Config) (listPath type parentRelation parentType parentId : String) (text : String) :
    IO Unit := do
  let answer ← match ← enUS (rows (← c.get listPath)) with
    | some row =>
      c.call "PATCH" s!"/{type}/{idOf row}" (Json.mkObj [("data", Json.mkObj [("type", type), ("id", idOf row),
        ("attributes", Json.mkObj [("whatsNew", text)])])])
    | none =>
      c.call "POST" s!"/{type}" (Json.mkObj [("data", Json.mkObj [("type", type),
        ("attributes", Json.mkObj [("locale", "en-US"), ("whatsNew", text)]),
        ("relationships", Json.mkObj [(parentRelation, Json.mkObj [("data", resource parentType parentId)])])])])
  unless strOf (at? answer ["data", "attributes", "whatsNew"]) == text do
    fail "App Store Connect did not return the text sent"

def Config.notes (c : Config) (bid : String) : IO Unit := do
  let some file := c.notesFile | fail "set TESTFLIGHT_WHATS_NEW_FILE"
  let text ← notesText file
  -- refused for a moment after the build turns VALID (or for good, with the reason in the log); each try
  -- looks the localization up again, since Apple may create it in between
  retrying 8 15 "notes" do
    c.setText s!"/builds/{bid}/betaBuildLocalizations?limit=200" "betaBuildLocalizations" "build" "builds" bid text
  say s!"notes: en-US What to Test set for build {bid} ({text.length} characters)"

def Config.internal (c : Config) (bid : String) : IO Unit := do
  -- export compliance is declared in Info.plist; this reads Apple's state instead of a PATCH that is a 409
  -- once set
  let state := strOf (at? (← c.get s!"/builds/{bid}/buildBetaDetail") ["data", "attributes", "internalBuildState"])
  unless state == "READY_FOR_BETA_TESTING" || state == "IN_BETA_TESTING" do
    fail s!"internal: build {bid} is not testable ({state})"
  say s!"internal: build {bid} is {state}"

def Config.publicGroupId (c : Config) : IO String := do
  let some link := c.publicLinkId | fail "set TESTFLIGHT_PUBLIC_LINK_ID"
  let groups := rows (← c.get
    s!"/betaGroups?filter[app]={← c.appId}&filter[publicLinkEnabled]=true&limit=200&fields[betaGroups]=name,publicLink,publicLinkId,isInternalGroup,publicLinkEnabled,createdDate")
  let matching := groups.filter fun g =>
    strOf (attr g "publicLinkId") == link ||
      (String.ofList ((strOf (attr g "publicLink")).toList.reverse.dropWhile (· == '/')).reverse).endsWith ("/" ++ link)
  unless matching.size == 1 do fail s!"expected exactly one public beta group for link {link}; found {matching.size}"
  return idOf matching[0]!

def Config.reviewState (c : Config) (bid : String) : IO String := do
  match (rows (← c.get s!"/betaAppReviewSubmissions?filter[build]={bid}&limit=1"))[0]? with
  | some row => pure (strOf (attr row "betaReviewState"))
  | none => pure "NOT_SUBMITTED"

def Config.inGroup (c : Config) (bid gid : String) : IO Bool := do
  return !(rows (← c.get s!"/builds?filter[app]={← c.appId}&filter[betaGroups]={gid}&filter[id]={bid}&limit=1")).isEmpty

def Config.external (c : Config) (bid : String) : IO Unit := do
  let gid ← c.publicGroupId
  if ← c.inGroup bid gid then
    say s!"external: build {bid} already belongs to the public link"
  else
    discard <| c.call "POST" s!"/betaGroups/{gid}/relationships/builds"
      (Json.mkObj [("data", Json.arr #[resource "builds" bid])])
    say s!"external: added build {bid} to the public link"
  let state ← c.reviewState bid
  if ["WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"].contains state then
    say s!"external: build {bid} review state is {state}"
    return
  if state == "REJECTED" then fail s!"external: build {bid} was rejected by beta review"
  -- a build is VALID a few seconds before beta review takes it
  retrying 12 15 "external: review submission" do
    discard <| c.call "POST" "/betaAppReviewSubmissions" (Json.mkObj [("data", Json.mkObj [
      ("type", "betaAppReviewSubmissions"),
      ("relationships", Json.mkObj [("build", Json.mkObj [("data", resource "builds" bid)])])])])
  let state ← c.reviewState bid
  say s!"external: build {bid} review state is {state}"
  if state == "NOT_SUBMITTED" then fail "external: the review submission did not take"

def Config.status (c : Config) (bid : String) : IO Unit := do
  let gid ← c.publicGroupId
  let processing ← c.processingState bid
  let detail := at? (← c.get s!"/builds/{bid}/buildBetaDetail") ["data", "attributes"]
  let internal := strOf (detail.getObjValD "internalBuildState")
  let external := strOf (detail.getObjValD "externalBuildState")
  let review ← c.reviewState bid
  let grouped ← c.inGroup bid gid
  say s!"build={bid} processing={processing} internal={internal} external={external} review={review} public_link={c.publicLinkId.getD ""} grouped={if grouped then "yes" else "no"}"
  unless processing == "VALID" && grouped && ["READY_FOR_BETA_TESTING", "IN_BETA_TESTING"].contains internal &&
      ["WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"].contains review do
    fail "status: the build is not with external testers yet"

/-- Read only: the token works, the app record and its newest build. -/
def Config.check (c : Config) : IO Unit := do
  let aid ← c.appId
  let newest := (rows (← c.get s!"/builds?filter[app]={aid}&sort=-uploadedDate&limit=1&include=preReleaseVersion"))[0]?
  match newest with
  | some b => say s!"App Store Connect: app {aid} ({c.bundleId}); newest build {idOf b}, build number {strOf (attr b "version")}, {strOf (attr b "processingState")}, uploaded {strOf (attr b "uploadedDate")}"
  | none => say s!"App Store Connect: app {aid} ({c.bundleId}); no builds"

/-! ## App Store -/

def Config.versionId (c : Config) : IO String := do
  if let some id := c.appStoreVersionId then return id
  let some s := c.appStoreVersionString | fail "set APPSTORE_VERSION_ID or APPSTORE_VERSION_STRING"
  let found := rows (← c.get s!"/apps/{← c.appId}/appStoreVersions?filter[platform]=IOS&filter[versionString]={s}&limit=2")
  unless found.size == 1 do fail s!"expected exactly one App Store version {s}; found {found.size}"
  return idOf found[0]!

def Config.versionJson (c : Config) (vid : String) : IO Json :=
  c.get s!"/appStoreVersions/{vid}?include=build,appStoreVersionLocalizations&fields[appStoreVersions]=versionString,appVersionState,platform,releaseType,createdDate,build,appStoreVersionLocalizations&fields[builds]=version,processingState,uploadedDate&fields[appStoreVersionLocalizations]=locale,whatsNew,description,keywords,supportUrl,marketingUrl,promotionalText"

def attachedBuild (version : Json) : String := strOf (at? version ["data", "relationships", "build", "data", "id"])

/-- The bare "newest upload" fallback is fine for TestFlight; App Store review needs the build named. -/
def Config.appStoreBuild (c : Config) : IO String := do
  if c.buildId.isNone && (c.version.isNone || c.build.isNone) then
    fail "appstore: name the build with TESTFLIGHT_BUILD_ID, or TESTFLIGHT_MARKETING_VERSION and TESTFLIGHT_BUILD_NUMBER"
  c.findBuild

def Config.appStoreAttach (c : Config) : IO Unit := do
  let bid ← c.appStoreBuild
  let vid ← c.versionId
  c.waitProcessing bid
  if let some s := c.appStoreVersionString then
    let included := arrOf ((← c.get s!"/builds/{bid}?include=preReleaseVersion&fields[preReleaseVersions]=version").getObjValD "included")
    let pre := (included.find? (fun r => strOf (r.getObjValD "type") == "preReleaseVersions")).map (fun r => strOf (attr r "version"))
    unless pre == some s do fail s!"appstore: build {bid} is version {pre.getD "?"}, not {s}"
  let version ← c.versionJson vid
  if attachedBuild version == bid then
    say s!"appstore: build {bid} is already attached to version {vid}"
    return
  let state := strOf (at? version ["data", "attributes", "appVersionState"])
  unless ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "METADATA_REJECTED", "REJECTED", "INVALID_BINARY"].contains state do
    fail s!"appstore: version {vid} is {state}; a build can only be attached while it is being prepared"
  let attributes := match c.appStoreVersionString with
    | some s => Json.mkObj [("versionString", s)]
    | none => Json.mkObj []
  discard <| c.call "PATCH" s!"/appStoreVersions/{vid}" (Json.mkObj [("data", Json.mkObj [("type", "appStoreVersions"),
    ("id", vid), ("attributes", attributes),
    ("relationships", Json.mkObj [("build", Json.mkObj [("data", resource "builds" bid)])])])])
  unless idOf ((← c.get s!"/appStoreVersions/{vid}/build").getObjValD "data") == bid do
    fail s!"appstore: App Store Connect did not report build {bid} on version {vid} after the attach"
  say s!"appstore: attached build {bid} to version {vid}"

def Config.appStoreNotes (c : Config) : IO Unit := do
  let vid ← c.versionId
  let some file := c.appStoreNotesFile | fail "set APPSTORE_WHATS_NEW_FILE"
  let text := (← IO.FS.readFile file).trimAsciiEnd.toString
  if text.isEmpty then fail s!"App Store What's New file is empty: {file}"
  c.setText s!"/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=200" "appStoreVersionLocalizations"
    "appStoreVersion" "appStoreVersions" vid text
  say s!"appstore: en-US What's New set for version {vid}"

def Config.openSubmissions (c : Config) : IO (Array Json) := do
  return rows (← c.get
    s!"/reviewSubmissions?filter[app]={← c.appId}&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES&limit=10")

/-- Prints everything first, then fails on whatever is missing, so the log shows the metadata behind
"complete". -/
def Config.appStoreStatus (c : Config) : IO Unit := do
  let vid ← c.versionId
  let aid ← c.appId
  let version ← c.versionJson vid
  let localizations ← c.get s!"/appStoreVersions/{vid}/appStoreVersionLocalizations?include=appScreenshotSets&fields[appScreenshotSets]=screenshotDisplayType&limit=200"
  let infos ← c.get s!"/apps/{aid}/appInfos?include=appInfoLocalizations,primaryCategory&fields[appInfos]=state,appStoreAgeRating,appInfoLocalizations,primaryCategory&fields[appInfoLocalizations]=locale,name,subtitle,privacyPolicyUrl&fields[appCategories]=platforms"
  let submissions ← c.openSubmissions
  let mut missing : Array String := #[]
  let data := version.getObjValD "data"
  let included := arrOf (version.getObjValD "included")
  let buildRow := included.find? fun r => strOf (r.getObjValD "type") == "builds" && idOf r == attachedBuild version
  let buildText := match buildRow with
    | some b => s!"{idOf b} (build {strOf (attr b "version")}, {strOf (attr b "processingState")})"
    | none => "none"
  say s!"version={idOf data} string={strOf (attr data "versionString")} state={strOf (attr data "appVersionState")} release={strOf (attr data "releaseType")} build={buildText}"
  if buildRow.isNone then missing := missing.push "build"
  let sets := (arrOf (localizations.getObjValD "included")).filter (fun r => strOf (r.getObjValD "type") == "appScreenshotSets")
  let mut enUSRow : Option Json := none
  for row in rows localizations do
    let setIds := (arrOf (at? row ["relationships", "appScreenshotSets", "data"])).map idOf
    let kinds := setIds.map fun sid => ((sets.find? (idOf · == sid)).map (fun r => strOf (attr r "screenshotDisplayType"))).getD "?"
    let a (k : String) := strOf (attr row k)
    say s!"  locale={a "locale"} whatsNew={if (a "whatsNew").isEmpty then "no" else "yes"} description={(a "description").length} chars keywords={if (a "keywords").isEmpty then "no" else "yes"} supportUrl={if (a "supportUrl").isEmpty then "none" else a "supportUrl"} marketingUrl={if (a "marketingUrl").isEmpty then "none" else a "marketingUrl"} screenshotSets={if kinds.isEmpty then "none" else ",".intercalate kinds.toList}"
    if a "locale" == "en-US" then enUSRow := some row
  match enUSRow with
  | none => missing := missing.push "en-US localization"
  | some row =>
    for k in ["whatsNew", "description", "keywords", "supportUrl"] do
      if (strOf (attr row k)).isEmpty then missing := missing.push k
  let infoRows := rows infos
  let infoIncluded := arrOf (infos.getObjValD "included")
  let active := (infoRows.find? (fun r => strOf (attr r "state") == strOf (attr data "appVersionState"))).orElse fun _ =>
    if infoRows.size == 1 then infoRows[0]? else none
  match active with
  | none => missing := missing.push "appInfo"
  | some info =>
    let category := idOf (at? info ["relationships", "primaryCategory", "data"])
    let rating := strOf (attr info "appStoreAgeRating")
    say s!"  appInfo state={strOf (attr info "state")} ageRating={if rating.isEmpty then "unset" else rating} primaryCategory={if category.isEmpty then "none" else category}"
    if category.isEmpty then missing := missing.push "primaryCategory"
    if rating.isEmpty then missing := missing.push "appStoreAgeRating"
    let mut named := false
    for ref in arrOf (at? info ["relationships", "appInfoLocalizations", "data"]) do
      let some row := infoIncluded.find? fun r => strOf (r.getObjValD "type") == "appInfoLocalizations" && idOf r == idOf ref
        | continue
      let a (k : String) := strOf (attr row k)
      say s!"  appInfo locale={a "locale"} name={a "name"} subtitle={a "subtitle"} privacyPolicyUrl={a "privacyPolicyUrl"}"
      if a "locale" == "en-US" then
        named := !(a "name").isEmpty
        if (a "privacyPolicyUrl").isEmpty then missing := missing.push "privacyPolicyUrl"
    if !named then missing := missing.push "name"
  say s!"  openReviewSubmissions={submissions.size}{String.join (submissions.toList.map fun r => s!" {idOf r}:{strOf (attr r "state")}")}"
  unless missing.isEmpty do fail s!"appstore: missing {", ".intercalate missing.toList}"
  say "appstore: metadata complete"

def Config.appStoreSubmit (c : Config) : IO Unit := do
  unless c.confirmSubmit do fail "appstore: refusing to submit without APPSTORE_CONFIRM_SUBMIT=yes"
  let vid ← c.versionId
  let aid ← c.appId
  if (attachedBuild (← c.versionJson vid)).isEmpty then
    fail s!"appstore: version {vid} has no build attached; run appstore-attach first"
  let whatsNew := ((← enUS (rows (← c.get s!"/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=200"))).map
    (fun r => strOf (attr r "whatsNew"))).getD ""
  if whatsNew.isEmpty then fail s!"appstore: version {vid} has no en-US What's New; run appstore-notes first"
  let rs ← match (← c.openSubmissions)[0]? with
    | some row =>
      let state := strOf (attr row "state")
      if state == "WAITING_FOR_REVIEW" || state == "IN_REVIEW" then
        say s!"appstore: submission {idOf row} is already {state}"
        return
      if state == "UNRESOLVED_ISSUES" then
        fail s!"appstore: submission {idOf row} has unresolved issues; resolve them in App Store Connect"
      say s!"appstore: reusing open submission {idOf row}"
      pure (idOf row)
    | none =>
      let created ← c.call "POST" "/reviewSubmissions" (Json.mkObj [("data", Json.mkObj [("type", "reviewSubmissions"),
        ("attributes", Json.mkObj [("platform", "IOS")]),
        ("relationships", Json.mkObj [("app", Json.mkObj [("data", resource "apps" aid)])])])])
      say s!"appstore: created submission {idOf (created.getObjValD "data")}"
      pure (idOf (created.getObjValD "data"))
  try
    discard <| c.call "POST" "/reviewSubmissionItems" (Json.mkObj [("data", Json.mkObj [("type", "reviewSubmissionItems"),
      ("relationships", Json.mkObj [("reviewSubmission", Json.mkObj [("data", resource "reviewSubmissions" rs)]),
        ("appStoreVersion", Json.mkObj [("data", resource "appStoreVersions" vid)])])])])
  catch _ => warn s!"appstore: the version could not be added to submission {rs} (already there, or not ready)"
  discard <| c.call "PATCH" s!"/reviewSubmissions/{rs}" (Json.mkObj [("data", Json.mkObj [("type", "reviewSubmissions"),
    ("id", rs), ("attributes", Json.mkObj [("submitted", true)])])])
  for _ in [0:12] do
    let state := strOf (at? (← c.get s!"/reviewSubmissions/{rs}") ["data", "attributes", "state"])
    say s!"appstore: submission {rs} is {state}"
    if state == "WAITING_FOR_REVIEW" || state == "IN_REVIEW" then return
    if state == "UNRESOLVED_ISSUES" then fail "appstore: the submission has unresolved issues"
    sleepSeconds 15
  fail s!"appstore: submission {rs} did not reach WAITING_FOR_REVIEW"

/-! ## Steps by name -/

def steps : List String :=
  ["register-bundle-id", "create-app", "upload", "wait-processing", "notes", "check-notes", "internal",
   "external", "status", "check", "appstore-status", "appstore-attach", "appstore-notes", "appstore-submit", "all"]

def Config.step (c : Config) : String → IO Unit
  | "register-bundle-id" => c.registerBundleId
  | "create-app" => c.createApp
  | "upload" => c.upload
  | "wait-processing" => do c.waitProcessing (← c.findBuild)
  | "notes" => do c.notes (← c.findBuild)
  | "check-notes" => do
    let some file := c.notesFile | fail "set TESTFLIGHT_WHATS_NEW_FILE"
    say s!"notes: {(← notesText file).length} of {notesLimit} characters"
  | "internal" => do c.internal (← c.findBuild)
  | "external" => do c.external (← c.findBuild)
  | "status" => do c.status (← c.findBuild)
  | "check" => c.check
  | "appstore-status" => c.appStoreStatus
  | "appstore-attach" => c.appStoreAttach
  | "appstore-notes" => c.appStoreNotes
  | "appstore-submit" => c.appStoreSubmit
  | "all" => do
    c.registerBundleId; c.createApp; c.upload
    let bid ← c.findBuild
    c.waitProcessing bid; c.notes bid; c.internal bid; c.external bid
  | other => fail s!"unknown step {other}; one of {", ".intercalate steps}"

end LeanNativeRelease.Asc
