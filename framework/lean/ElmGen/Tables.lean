import Lean
/-!
# ElmGen.Tables

Hand-maintained tables: Swift keywords, the names the Swift side already owns (so a user type or
definition that would shadow them is rejected at translation time), the `Html` constructors whose
Swift mirror uses argument labels, and the text of the shims the translation may request.
Everything here is a claim about `framework/swift/Runtime.swift`, `framework/swift/Elements.swift` and
SwiftUI, not something derivable from Lean.
-/

namespace ElmGen
open Lean

def swiftKeywords : List String :=
  ["as", "associatedtype", "break", "case", "catch", "class", "continue", "default", "defer", "deinit",
   "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if",
   "import", "in", "init", "inout", "internal", "is", "let", "nil", "open", "operator", "private",
   "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "static", "struct", "subscript",
   "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while", "Any",
   "Type", "some", "any", "await", "actor", "async", "final", "lazy", "mutating", "nonisolated",
   "override", "required", "indirect", "consuming", "borrowing"]

/-- Swift identifiers the generated files must not introduce at top level or as app members:
declarations of Runtime.swift and Elements.swift, the SwiftUI/stdlib names they and the screen use
(a user type with one of these names would shadow the library for the whole module), and the two member names of the screen struct (shims claim their names when requested). -/
def reservedSwiftNames : List String :=
  [ -- Runtime.swift
    "TextStyle", "ButtonRole", "Html", "Event", "q", "ElmApp", "JNum", "JSON", "JSONReader", "Request",
    "Parsed", "parseLine", "Session", "emit", "runElmCli", "CmdElmApp", "LeanCodable", "CmdSession",
    "runCmdElmCli", "CmdHost", "Task",
    -- Elements.swift (the iOS app shell `<Name>GenApp` is derived from the app name: see `claimName`)
    "Store", "ElmText", "RoleButton", "ElmField", "ElmToggle",
    -- (shims are claimed by `requestShim`, so a user definition with a shim's name is caught there)
    -- Swift standard library
    "Int", "String", "Bool", "Array", "Optional", "Set", "Dictionary", "Character", "Substring",
    "Unicode", "Double", "Float", "Error", "Result", "Never", "Void", "AnyObject", "Equatable",
    "Hashable", "Comparable", "Sequence", "Collection", "Foundation", "Swift", "print", "max", "min",
    "abs", "Data", "FileHandle",
    -- SwiftUI (used by Elements.swift, the app shell and the generated screen)
    "SwiftUI", "View", "ViewBuilder", "Text", "Button", "Toggle", "TextField", "VStack", "HStack",
    "ZStack", "Divider", "Spacer", "Group", "ForEach", "EmptyView", "Binding", "State", "Observable",
    "MainActor", "App", "Scene", "WindowGroup", "NavigationStack", "ScrollView", "Font", "Color",
    "Image", "Label", "List", "Section", "Form",
    -- members of the screen struct
    "body", "store" ]

/-- Local variable names that must never be chosen (they would shadow screen-struct members or `self`). -/
def reservedLocalNames : List String := ["store", "body", "self", "Self"]

/-- `Html` constructors whose Swift mirror in Runtime.swift uses argument labels (the labels are the Lean
binder names, printed by `ctorFieldNames`). -/
def htmlLabeled : List Name := [`ElmLean.Html.button, `ElmLean.Html.field, `ElmLean.Html.toggle]

/-- Swift text of a shim (a library function with no Swift counterpart), keyed by `requestShim`. -/
def shimText : String → String
  | "trimAscii" =>
    "/// Lean `String.trimAscii`: strips ' ', '\\t', '\\r', '\\n' at both ends, by code point.\n" ++
    "func leanTrimAscii(_ s: String) -> String {\n" ++
    "    let ws: Set<UInt32> = [0x20, 0x09, 0x0d, 0x0a]\n" ++
    "    var sc = Substring.UnicodeScalarView(s.unicodeScalars)\n" ++
    "    while let f = sc.first, ws.contains(f.value) { sc = sc.dropFirst() }\n" ++
    "    while let l = sc.last, ws.contains(l.value) { sc = sc.dropLast() }\n" ++
    "    return String(sc)\n}\n"
  | s => s!"// unknown shim {s}\n"

/-- The Swift top-level name a shim declares (for the collision table). -/
def shimSwiftName : String → String
  | "trimAscii" => "leanTrimAscii"
  | s => s

/-- A Lean name as a Swift identifier: components joined by `_`, non-alphanumerics replaced, keywords suffixed. -/
def sanitize (n : Name) : String :=
  let s := (n.eraseMacroScopes.components.map fun c => c.toString).foldl
    (fun acc c => if acc == "" then c else acc ++ "_" ++ c) ""
  let s := String.ofList (s.toList.map fun c => if c.isAlphanum || c == '_' then c else '_')
  let s := if s == "" || s.front.isDigit then "a_" ++ s else s
  if swiftKeywords.contains s then s ++ "_" else s

def freshName (base : String) (used : List String) : String := Id.run do
  if !used.contains base then return base
  let mut i := 1
  while used.contains s!"{base}_{i}" do i := i + 1
  return s!"{base}_{i}"

end ElmGen
