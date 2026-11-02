import LeanNativeRelease.Bundle
import LeanNativeRelease.Asc

/-! # `leannative-release`: the release workflow's steps

    leannative-release policy <notes file> [tag]          a stable tag and What to Test that fits
    leannative-release append-notes <notes file> <line>   a last paragraph for What to Test, checked again
    leannative-release verify-app <app> [--distribution]  identity, signature, iCloud, arm64, no Swift
    leannative-release verify-ipa <ipa>                   the exported package's app, its SHA-256 recorded
    leannative-release jwt                                an App Store Connect token, for a person's own calls
    leannative-release testflight <step>                  App Store Connect (LeanNativeRelease.Asc)

The app's identity and the App Store Connect key come from the environment: APP_BUNDLE_ID, APP_TEAM_ID,
APP_ICLOUD_CONTAINER (when the app has iCloud), TESTFLIGHT_MARKETING_VERSION and TESTFLIGHT_BUILD_NUMBER,
ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH; the steps' own variables are in `LeanNativeRelease.Asc`. The
release workflow (.github/workflows/ios-release.yml) builds it from the app's LeanNative package:
`lake build leannative/leannative-release` in the app's directory. -/

open LeanNativeRelease

def usage : String :=
  "usage: leannative-release policy <notes> [tag] | append-notes <notes> <line> | verify-app <app> [--distribution] | verify-ipa <ipa> | jwt | testflight <step>"

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["policy", notes] => policy notes none
    | ["policy", notes, tag] => policy notes (if tag.isEmpty then none else some tag)
    | ["append-notes", notes, line] => appendNotes notes line
    | ["verify-app", app] => verifyApp app (← Identity.fromEnv) false
    | ["verify-app", app, "--distribution"] => verifyApp app (← Identity.fromEnv) true
    | ["verify-ipa", ipa] => verifyIpa ipa (← Identity.fromEnv)
    | ["jwt"] =>
      let keyId ← need "ASC_KEY_ID"
      let keyPath := (← env? "ASC_KEY_PATH").getD s!"{(← IO.getEnv "HOME").getD ""}/.appstoreconnect/private_keys/AuthKey_{keyId}.p8"
      IO.println (← Jwt.mint keyPath keyId (← need "ASC_ISSUER_ID"))
    | ["testflight", step] => (← Asc.Config.fromEnv).step step
    | _ => IO.eprintln usage; return 2
    return 0
  catch e =>
    IO.eprintln s!"leannative-release: {e}"
    return 1
