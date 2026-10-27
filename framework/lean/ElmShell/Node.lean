import ElmShell.Grammar

/-! # ElmShell.Node: `NativeNode.swift`, printed from the grammar table -/

namespace ElmShell

/-- `case tag(label: T, …)` -/
def caseDecl (k : NodeKind) : Decl :=
  if k.fields.isEmpty then .caseD k.tag
  else .caseD (k.tag ++ "(" ++ ", ".intercalate (k.fields.map fun f =>
    if f.labelled then f.key ++ ": " ++ f.swiftTy else f.swiftTy) ++ ")")

/-- The decoding of one field from the JSON object `o`. -/
def Field.decode (f : Field) : String :=
  let v := match f.ty with
    | .str => s!"s(\"{f.key}\")"
    | .bool false => s!"b(\"{f.key}\")"
    | .bool true => s!"o[\"{f.key}\"] as? Bool ?? true"
    | .int => s!"n(\"{f.key}\")"
    | .strs => s!"ss(\"{f.key}\")"
    | .enum t d => s!"{t}(rawValue: s(\"{f.key}\")) ?? .{d}"
    | .kids => "kids()"
  if f.labelled then f.key ++ ": " ++ v else v

def decodeArm (k : NodeKind) : String × List Stmt :=
  (s!"\"{k.tag}\"", [.set "self" (r ("." ++ k.tag ++
    (if k.fields.isEmpty then "" else "(" ++ ", ".intercalate (k.fields.map (·.decode)) ++ ")")))])

def nodeFile : List Decl :=
  [ .imp "Foundation"
  , .doc "The view tree an ElmLean app emits (PROTOCOL.md, \"Node grammar\"), decoded from JSON. The renderer
knows only this grammar, never the app. An unknown `t` decodes as `.unknown` and renders as a visible
placeholder. Child `i` of a container is at `path + [i]`, in the order of `c`."
    (.ty "indirect enum NativeNode: Equatable, Sendable" <|
      stringEnums.map (fun (n, vs) => .prop s!"enum {n}: String, Sendable \{ case {", ".intercalate vs} }" none) ++
      [.blank] ++ nodes.map caseDecl ++ [.caseD "unknown(String)", .blank] ++
      [ .fn "init(json: Any?)"
        [ .guardS ["let o = json as? [String: Any]"] [s "self = .unknown(\"not an object\")", .ret none]
        , .letS "t" (r "o[\"t\"] as? String ?? \"?\"")
        , s "func s(_ k: String) -> String { o[k] as? String ?? \"\" }"
        , s "func b(_ k: String) -> Bool { o[k] as? Bool ?? false }"
        , s "func n(_ k: String) -> Int { o[k] as? Int ?? 0 }"
        , s "func ss(_ k: String) -> [String] { o[k] as? [String] ?? [] }"
        , s "func kids() -> [NativeNode] { (o[\"c\"] as? [Any] ?? []).map { NativeNode(json: $0) } }"
        , .switchS (r "t") (nodes.map decodeArm ++ [("default", [s "self = .unknown(t)"])]) ] ])
  , .doc "Events the renderer sends (PROTOCOL.md, \"Client → CLI\")."
    (.ty "enum NativeEvent" <|
      [.caseD (", ".intercalate ((events.filter (·.2.isNone)).map (·.1)))] ++
      (events.filterMap fun (n, t) => t.map fun t => .caseD s!"{n}({t})") ++
      [ .blank
      , .fn "var json: [String: Any]"
        [.switchS (r "self") (events.map fun (n, t) => match t with
          | none => ("." ++ n, [.ret (r s!"[\"k\": \"{n}\"]")])
          | some _ => (s!".{n}(let v)", [.ret (r s!"[\"k\": \"{n}\", \"value\": v]")]))] ]) ]

end ElmShell
