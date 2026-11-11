# Capabilities that need a bridge

The shell's capability table (`framework/lean/LeanNativeShell/Capabilities.lean`) is Objective-C printed
from Lean, and it reaches whatever Apple offers in Objective-C or C. Some of what Apple offers is Swift
only: the SDK ships a `.swiftmodule` and no headers, or one umbrella header with nothing behind it. A
LeanNative app can still use those, through a bridge the app owns: one Swift file behind `app.invoke`.
This page lists the capabilities that need one, what each bridge has to get right, and how each has to be
tested, because none of them is covered by the shell's own tests.

Surveyed against Xcode 27.2 (iOS 27.2 SDK), 2026-11-10. Only the Foundation Models bridge has been built
and run. Every other row is from the SDK's headers and Swift interfaces and from each framework's
documentation, not from a working bridge: read a row as where to start, and correct it when its bridge is built.

## What a bridge is

The shell's `app.invoke` looks up a class named `LeanNativeAppCapabilities` at run time and calls
`+run:answer:` with the request's JSON object. The class can be Swift:

```swift
import Foundation
import FoundationModels

@objc(LeanNativeAppCapabilities)            // the Objective-C name the shell looks up
final class LeanNativeAppCapabilities: NSObject {
  @objc(run:answer:)
  static func run(_ args: NSDictionary, answer: @escaping @Sendable (NSDictionary) -> Void) {
    let reply: @Sendable (NSDictionary) -> Void = { d in DispatchQueue.main.async { answer(d) } }
    guard #available(iOS 26.0, *) else { reply(["error": "unsupported"]); return }
    switch args["op"] as? String {
    case "llm.respond":
      let prompt = args["prompt"] as? String ?? ""
      Task {
        do { reply(["ok": true, "text": try await LanguageModelSession().respond(to: prompt).content]) }
        catch { reply(["error": String(describing: error)]) }
      }
    default: reply(["error": "badArgs"])
    }
  }
}
```

The manifest lists the file and the capability (`swiftSources := ["Bridge.swift"]`,
`uses := [..., "app.invoke"]`), and Lean asks with `fx.cap "app.invoke" (Json.mkObj [("op", "llm.respond"), …]) k`.

**Tried on 2026-11-10**, in a scratch copy of `examples/simple` with that file (iPhone 17 Pro simulator, iOS
26.5): the manifest and `ci/build-ios` needed no change, XcodeGen compiled the Swift (`SWIFT_VERSION` 5.0,
its default), the app linked Swift's libraries from `/usr/lib/swift` and bundled none, FoundationModels was
weak-linked (the deployment target is 17.0), and a button in the Lean view sent the request and showed the
answer from the Lean model. The answer on that simulator was the framework's own `GenerationError`
(underneath it `SensitiveContentAnalysisML` 15 and `ModelManagerError` 1001), not generated text: the
round trip is shown, a generation is not. That needs a device with Apple Intelligence on.

What every bridge has to get right:

- **The names.** `@objc(LeanNativeAppCapabilities)` and `@objc(run:answer:)`. Without the explicit name a
  Swift class is registered under its module's name, the shell finds nothing and answers `unsupported`.
- **One class per app.** `app.invoke` is one capability, so an app with two bridges dispatches on a field
  of the request (`op` above).
- **Answer once, on the main queue, with JSON.** Strings, numbers, booleans, arrays, dictionaries and
  `NSNull`; bytes as hex, as the shell's capabilities do. A Swift `async` call answers from a `Task`.
- **Availability.** The frameworks here are newer than the deployment target, so each call is behind
  `#available`, and the older system answers `unsupported` like a missing class does.
- **Errors as names.** An `Error`'s description is not an interface. A bridge that an app's `update`
  branches on answers the case as a name and a code, as `auth` and `cloudkit.*` do.

**The no-Swift checks.** `ci/check-no-swift` (run by `check.yml`, `ios-app.yml` and `ios-release.yml`) and
`leannative-release verify-app` refuse a `.swift` file in the tree, a Swift compile step and a linked Swift
library, unless the app declares its Swift. `swiftSources` is the declaration: the manifest writes the
list into Info.plist (`LNSwiftSources`), and the checks read it from the built app and allow exactly those
files and the system's Swift libraries. Any other Swift file tracked or compiled, a Swift library that is
not the system's, and one bundled in the app are still refused, so a Swift package among the app's
dependencies does not pass. A `.swift` file in `nativeSources` is refused when the project is generated.
The scratch app above passes `check-no-swift` in Debug and Release for the simulator; no app with a bridge
has been archived, exported or uploaded, so `verify-app` on a real one is untried.

## The list

"Test" is what the shell's tests and a headless journey cannot show, so what the bridge's own test has to.

### Swift only: no Objective-C interface at all

| Capability | Framework (since) | The bridge has to | Test |
|---|---|---|---|
| On-device language model | FoundationModels (iOS 26) | hold a session across requests if the app wants a conversation; answer `availability` with its reason (not eligible, not enabled, model not ready) before any prompt; map `GenerationError` cases to names | on a device with Apple Intelligence on, and with it off: the simulator answered an error, not text. The text is not deterministic: assert the answer's shape and the unavailable cases, never the words |
| Translation | Translation (iOS 18) | start a `TranslationSession` itself (`init(installedSource:target:)`, iOS 26), which works only for languages already installed: a download goes through SwiftUI's `.translationTask`, so that case answers `notInstalled` | a device, with a pair that is installed, one that is not, and one that is unsupported |
| Live Activities | ActivityKit (iOS 16.1) | start, update and end an activity; **and** a widget extension in SwiftUI that draws it, which is a second target in the manifest's `spec`, not a file | a device or simulator's lock screen and Dynamic Island, by screenshot; push updates need APNs |
| Widgets | WidgetKit (iOS 14) | the same extension; the app side only reloads timelines and shares data through an app group | the home screen, by screenshot; a timeline's later entries need the clock moved |
| App Intents (Shortcuts, Siri, Spotlight actions) | AppIntents (iOS 16) | declare each intent as a Swift type at compile time (the system reads them from the binary's metadata), then hand its parameters to Lean and wait for the model's answer | run the intent from Shortcuts with the app running and not running; an intent launches the app in the background |
| In-app purchase, current API | StoreKit 2 (iOS 15); the original API is Objective-C, deprecated since iOS 18 | listen to `Transaction.updates` for the app's whole life, verify each transaction, finish it only after Lean has recorded it | a StoreKit configuration file in Xcode, then the sandbox on a device: purchase, interrupted purchase, refund, a renewal while the app is closed |
| Weather | WeatherKit (iOS 16) | nothing an `http.request` to the WeatherKit REST API with a signed token does not do; a bridge saves the token | needs the WeatherKit entitlement and a signed build, so no ad-hoc simulator build |
| Apple Music catalog and playback | MusicKit (iOS 15); MediaPlayer is Objective-C | ask for authorization, then requests; playback through `MPMusicPlayerController` needs no Swift | a device with a subscription for playback; authorization is a system prompt |
| Alarms | AlarmKit (iOS 26) | schedule and cancel; its alert is a Live Activity, so the extension above | a device, the alarm firing with the app closed and the phone locked |
| Speech to text, current API | Speech: `SpeechAnalyzer` (iOS 26); `SFSpeechRecognizer` is Objective-C | stream audio in and results out: one request cannot carry it, so results come as repeated answers to a `read`, as `ble.read` does | a device microphone, or an audio file in the bundle for a repeatable run |
| Image generation | ImagePlayground (iOS 18.1) | present the system's sheet, or `ImageCreator` for no UI; answer a file path, not hex | a device with Apple Intelligence; not deterministic |
| Tap to Pay | ProximityReader (iOS 15.4) | a reader session with a payment provider's token | an entitlement Apple grants per developer, a device, a real or test card |
| Screen Time | FamilyControls, ManagedSettings, DeviceActivity (iOS 15) | authorization, a SwiftUI picker for the apps (there is no other), and a monitor extension | an entitlement Apple grants, a device, a family or individual authorization |
| SharePlay | GroupActivities (iOS 15) | define the activity as a Swift type, join sessions, carry the app's messages | two devices in a FaceTime call |
| Financial data | FinanceKit (iOS 17.4) | queries over accounts and transactions | an entitlement Apple grants, a device with Wallet data |
| Room scanning | RoomPlan (iOS 16) | present the capture view, answer the model as a file | a device with LiDAR, a room |
| Workouts | WorkoutKit (iOS 17) | compose and schedule a workout; HealthKit itself is Objective-C | a paired Apple Watch for scheduling |
| Age range, permission to contact | DeclaredAgeRange (iOS 26.2), PermissionKit (iOS 26) | present the system's request, answer the range or the decision | a device, a child account in a family for the real answers |
| Nearby Wi-Fi peers | WiFiAware (iOS 26) | pair, publish and subscribe; a connection's bytes then go through Network.framework | two devices |
| Journaling suggestions, energy guidance, call UI for VoIP | JournalingSuggestions (17.2), EnergyKit (26), LiveCommunicationKit (17.4; CallKit is Objective-C) | each a picker or a query | a device; entitlements for the first two |

### Swift only, and a bridge is not enough

These are views, not requests. The renderer (`LNRender.m`) draws a tree of UIKit views from Lean's wire
grammar, and a SwiftUI view is not a node in it. Each would be a new kind of node whose view is a
`UIHostingController`'s, which is renderer work and a `Wire` constructor, beyond `app.invoke`.

| Capability | Framework | Instead, today |
|---|---|---|
| Charts | Charts (iOS 16) | draw with the nodes the renderer has |
| Tips | TipKit (iOS 17) | a sheet or a row in the Lean view |
| A SwiftUI view of any kind, the SwiftUI-only pickers (`PhotosPicker`, `ShareLink`, `Map`) | SwiftUI and its `_X_SwiftUI` overlays | the UIKit equivalents are Objective-C (`PHPickerViewController`, `UIActivityViewController`, `MKMapView`): shell work, no Swift |
| 3D and AR content | RealityKit's Swift API (RealityFoundation) | ARKit and SceneKit are Objective-C |

### Swift only, and not needed

| Framework | Why an app does without it |
|---|---|
| CryptoKit | its primitives are in Security and CommonCrypto (C), and an app can have its cryptography in Lean, where it can be proved (Winnow does) |
| SwiftData | the model is Lean's; Core Data is Objective-C, and the shell has the keychain, files and CloudKit |
| Combine, Observation, TabularData | Swift's own plumbing: nothing for Lean to call |

### Objective-C, no Swift, and still a bridge to build and test with care

These have complete Objective-C interfaces, so they go behind `app.invoke` in a `.m` file and pass every
check as they are. They are here because the shell's tests cover none of them and a simulator shows little.

| Capability | Framework | The bridge has to | Test |
|---|---|---|---|
| Running a model | Core ML | load a compiled model (`.mlmodelc` in `resources`) once and keep it; predict off the main thread; inputs and outputs as `MLMultiArray` from numbers or hex | fixed inputs and expected outputs to a tolerance; compute units differ by device (Neural Engine, GPU, CPU), so a device run as well as the simulator |
| Text, faces, barcodes, classification in an image | Vision | take the image as a file path or hex; one request at a time or a queue | fixture images in the bundle and their expected observations; results change between OS versions, so assert loosely |
| Language, tags, embeddings | NaturalLanguage | nothing unusual | fixture sentences; embeddings are downloaded assets and can be absent |
| Speech to text | Speech (`SFSpeechRecognizer`) | authorization, then streamed results as above | an audio file in the bundle; on-device recognition per locale |
| Sound classification | SoundAnalysis | a stream of results | an audio file in the bundle |
| Camera frames to any of these | AVFoundation | keep the frames in Objective-C and send Lean only results: JSON with hex does not carry video | a device; the simulator has no camera |
| Health data | HealthKit | authorization per type, queries, observer queries for the app's life | the simulator's Health app for seeded data; a device for real sources |
| Notifications | UserNotifications | authorization, schedule, and deliver a tap on one to Lean as a message | local notifications in the simulator; remote ones need APNs and a device |
| Location | CoreLocation | authorization in its two steps, a stream of fixes | the simulator's simulated locations; background delivery on a device |

## The survey

Frameworks in the iOS 27.2 SDK with a Swift module and no header, leaving out the cross-import overlays
(`_X_Y`):

AccessoryNotifications, AccessoryTransportExtension, AudioAccessoryKit, AutomatedDeviceEnrollment, CarKey,
Charts, Combine, CoreAI, CrashReportExtension, CreateML, CreateMLComponents, CryptoKit, DeclaredAgeRange,
DeveloperToolsSupport, DeviceActivity, EnergyKit, FamilyControls, FinanceKit, FinanceKitUI,
FoundationModels, GeoToolbox, GroupActivities, IdentityDocumentServices, IdentityDocumentServicesUI,
ImmersiveMediaSupport, JournalingSuggestions, LightweightCodeRequirements, LiveCommunicationKit, ManagedApp,
ManagedAppDistribution, ManagedSettings, ManagedSettingsUI, MediaIntelligence, MediaIntents, MusicKit,
MusicUnderstanding, NowPlaying, PaperKit, PermissionKit, RealityFoundation, SecureElementCredential,
SuggestedActions, SwiftData, TabularData, TelephonyMessagingKit, TipKit, TrustInsights, USDKit,
VisualIntelligence, WeatherKit, WiFiAware, WiFiInfrastructure, WirelessInsights, WorkoutKit.

With one umbrella header and a Swift module behind it, Swift only in practice: ActivityKit, AdAttributionKit,
AlarmKit, AppIntents, AppMigrationKit, CoreTransferable, DockKit, ImagePlayground, LockedCameraCapture,
MarketplaceKit, MatterSupport, ProximityReader, RelevanceKit, RoomPlan, SwiftUI, Translation, WidgetKit.

To repeat the survey against another Xcode:

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks; for d in $SDK/*.framework; do [ -z "$(ls $d/Headers 2>/dev/null)" ] && ls -d $d/Modules/*.swiftmodule >/dev/null 2>&1 && basename $d .framework; done
```

Frameworks in the survey that no table above names have not been looked at.
