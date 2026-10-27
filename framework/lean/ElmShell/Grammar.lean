import ElmShell.Swift
import ElmLean.Json

/-!
# ElmShell.Grammar

The node grammar of PROTOCOL.md as one table, the source of everything in the shell that follows the
grammar: the cases of `NativeNode` and their decoding (`ElmShell.Node`), the renderer's dispatch with one
arm per kind (`ElmShell.View`), which kinds take no room in a layout, the three string enums and the
events. `ElmShell.Check` holds the table to `Wire.toJson` and `Event.fromJson?`.
-/

namespace ElmShell
open ElmLean

/-- How a field crosses the wire and what it is in Swift. -/
inductive FTy where
  | str
  /-- a `Bool`, `false` when absent (`dflt`: what an absent field means) -/
  | bool (dflt : Bool := false)
  | int
  | strs
  /-- one of a string enum's raw values, `dflt` when absent or unknown -/
  | enum (swiftTy : String) (dflt : String)
  /-- the children, under the wire key `c` -/
  | kids
  deriving BEq, Repr

structure Field where
  /-- the wire key (and the Swift label and binding name; `c` for the children) -/
  key : String
  ty : FTy
  /-- whether the Swift associated value carries the key as its label -/
  labelled : Bool := true

def Field.swiftTy : Field → String
  | ⟨_, .str, _⟩ => "String"
  | ⟨_, .bool _, _⟩ => "Bool"
  | ⟨_, .int, _⟩ => "Int"
  | ⟨_, .strs, _⟩ => "[String]"
  | ⟨_, .enum t _, _⟩ => t
  | ⟨_, .kids, _⟩ => "[NativeNode]"

/-- The name an arm binds the field to. -/
def Field.bind (f : Field) : String := if f.ty == .kids then "nodes" else f.key

structure NodeKind where
  /-- the wire tag `t`, which is also the Swift case name -/
  tag : String
  fields : List Field := []
  /-- the renderer's arm; it sees the fields under their `bind` names, and `node`, `path`, `store` -/
  render : List Stmt
  /-- whether the arm binds the fields (`case .screen:` hands the whole node on) -/
  binds : Bool := true
  /-- presentations and spacers: they take no room in a screen's layout -/
  overlay : Bool := false

def str (k : String) (labelled := true) : Field := { key := k, ty := .str, labelled }
def bool (k : String) (dflt := false) : Field := { key := k, ty := .bool dflt }
def int (k : String) : Field := { key := k, ty := .int }
def strs (k : String) : Field := { key := k, ty := .strs }
def kids : Field := { key := "c", ty := .kids, labelled := false }

/-- `VStack(alignment: .leading, spacing: 12) { children(nodes) }` -/
def column (content : List Stmt := [s "children(nodes)"]) : Expr := cb "VStack" ["alignment: .leading", "spacing: 12"] "" content

def nodes : List NodeKind :=
  [ { tag := "text", fields := [str "s" false, { key := "style", ty := .enum "Style" "body", labelled := false }],
      render := [s "NativeText(s: s, style: style)"] }
  , { tag := "col", fields := [kids], render := [.e column] }
  , { tag := "row", fields := [kids], render := [.e (m (cb "HStack" ["spacing: 12"] "" [s "children(nodes)"]) ["frame(minHeight: 44)"])] }
  , { tag := "button", fields := [str "label", { key := "role", ty := .enum "Role" "plain" }, bool "enabled" true],
      render :=
        [ .letS "b" (m (cb "Button" ["label", "role: role == .destructive ? .destructive : nil"] "" [s "store.send(path: path, event: .click)"])
            ["disabled(!enabled)"])
        , .ifS ["role == .primary"] [s "b.buttonStyle(.borderedProminent).controlSize(.large)"] [s "b.buttonStyle(.bordered)"] ] }
  , { tag := "field", fields := [str "placeholder", str "value", bool "submits"],
      render := [s "NativeField(path: path, kind: .plain, label: \"\", placeholder: placeholder, serverValue: value, submits: submits)"] }
  , { tag := "toggle", fields := [str "label", bool "on"],
      render := [s "Toggle(label, isOn: Binding(get: { on }, set: { store.send(path: path, event: .toggle($0)) }))"] }
  , { tag := "divider", render := [s "Divider()"] }
  , { tag := "spacer", render := [s "Spacer(minLength: 0)"], overlay := true }
  , { tag := "input",
      fields := [{ key := "kind", ty := .enum "InputKind" "plain" }, str "label", str "placeholder", str "value", bool "submits"],
      render := [s "NativeField(path: path, kind: kind, label: label, placeholder: placeholder, serverValue: value, submits: submits)"] }
  , { tag := "list", fields := [kids], render := [.e column] }
  , { tag := "section", fields := [str "header", str "footer", kids],
      render := [.e (.call (r "Section") [] [(none, .lam "" [s "children(nodes)"]),
                  (some "header", .lam "" [.ifS ["!header.isEmpty"] [s "Text(header)"] []]),
                  (some "footer", .lam "" [.ifS ["!footer.isEmpty"] [s "Text(footer)"] []])])] }
  , { tag := "labeled", fields := [str "label", str "value"],
      render := [.e (cb "LabeledContent" ["label"] "" [s "NativeText(s: value, style: .body)"])] }
  , { tag := "screen", fields := [str "title", bool "back", bool "refreshable", kids], binds := false,
      render := [s "NativeScreen(node: node, path: path)"] }
  , { tag := "toolbar", fields := [kids], render := [.e (cb "HStack" [] "" [s "children(nodes)"])] }
  , { tag := "tabs", fields := [strs "labels", strs "icons", int "selected", kids],
      render := [s "NativeTabs(labels: labels, icons: icons, selected: selected, children: nodes)"] }
  , { tag := "sheet", fields := [str "title", bool "dismissable", kids], overlay := true,
      render :=
        [ .e (.chain (m (r "Color.clear") ["frame(height: 0)"])
            [.call (r "sheet") [(some "isPresented", .call (r "Binding") [(some "get", .lam "" [s "true"]),
                (some "set", .lam "shown" [.ifS ["!shown && dismissable"] [s "store.send(path: path, event: .dismiss)"] []])] [])]
              [(none, .lam ""
                [ .e (.chain (cb "NavigationStack" [] ""
                    [ .e (.chain (cb "Group" [] ""
                        [ .comment "a sheet holding a page gives the page the rest of the sheet; it scrolls itself"
                        , .ifS ["nodes.contains(where: \\.isPage)"]
                            [.e (m column ["padding([.horizontal, .top])"])]
                            [.e (cb "ScrollView" [] "" [.e (m column ["padding()"])])] ])
                        [r "navigationTitle(title)", r "navigationBarTitleDisplayMode(.inline)"]) ])
                    [r "interactiveDismissDisabled(!dismissable)", r "environment(store)"]) ])]]) ] }
  , { tag := "alert", fields := [str "title", str "message", kids], overlay := true,
      render :=
        [ .e (.chain (m (r "Color.clear") ["frame(height: 0)"])
            [.call (r "alert") [(none, r "title"), (some "isPresented", r ".constant(true)")]
              [ (none, .lam "" [.e (cb "ForEach" ["Array(nodes.enumerated())", "id: \\.offset"] "i, n"
                  [.ifS ["case .button(let label, let role, _) = n"]
                    [.e (cb "Button" ["label", "role: role == .destructive ? .destructive : nil"] ""
                      [s "store.send(path: path + [i], event: .click)"])] []])])
              , (some "message", .lam "" [s "Text(message)"]) ]]) ] }
  , { tag := "picker", fields := [str "label", strs "options", int "selected"],
      render := [.e (cb "Picker" ["label", "selection: Binding(get: { selected }, set: { store.send(path: path, event: .select($0)) })"] ""
                  [.e (cb "ForEach" ["Array(options.enumerated())", "id: \\.offset"] "i, o" [s "Text(o).tag(i)"])])] }
  , { tag := "progress", fields := [str "label" false], render := [s "ProgressView(label)"] }
  , { tag := "icon", fields := [str "name" false], render := [s "Image(systemName: name)"] }
  , { tag := "qr", fields := [str "text" false], render := [s "NativeQR(text: text)"] }
  , { tag := "share", fields := [str "label", str "text", bool "file"],
      render := [.ifS ["file"]
        [.e (cb "ShareLink" ["item: URL(fileURLWithPath: text)"] "" [s "Label(label, systemImage: \"square.and.arrow.up\")"])]
        [.e (cb "ShareLink" ["item: text"] "" [s "Label(label, systemImage: \"square.and.arrow.up\")"])]] }
  , { tag := "link", fields := [str "label", str "url"],
      render := [.ifS ["let u = URL(string: url)"] [s "Link(label, destination: u)"] [s "Text(label)"]] }
  , { tag := "page", fields := [str "path" false], render := [s "NativePage(path: path).frame(maxWidth: .infinity, maxHeight: .infinity)"] }
  , { tag := "empty", fields := [str "title", str "icon", str "message", kids],
      render := [.e (.call (r "ContentUnavailableView") []
        [(none, .lam "" [s "Label(title, systemImage: icon)"]), (some "description", .lam "" [s "Text(message)"]),
         (some "actions", .lam "" [s "children(nodes)"])])] }
  , { tag := "disclosure", fields := [str "title", bool "expanded", kids],
      render := [.e (cb "DisclosureGroup" ["title", "isExpanded: Binding(get: { expanded }, set: { store.send(path: path, event: .toggle($0)) })"] ""
                  [s "children(nodes)"])] }
  , { tag := "stepper", fields := [str "label", int "value", int "lo", int "hi", str "detail"],
      render :=
        [ .letS "binding" (r "Binding(get: { value }, set: { store.send(path: path, event: .select($0)) })")
        , .ifS ["detail.isEmpty"] [s "Stepper(\"\\(label): \\(value)\", value: binding, in: lo...max(lo, hi))"]
            [.e (cb "Stepper" ["value: binding", "in: lo...max(lo, hi)"] "" [s "LabeledContent(label, value: detail)"])] ] } ]

/-- `.tag(let a, let b, …)` binding every field (the children as `kidsName`), or `.tag` when it has none. -/
def NodeKind.pattern (k : NodeKind) (kidsName := "nodes") : String :=
  if k.fields.isEmpty then "." ++ k.tag
  else "." ++ k.tag ++ "(" ++ ", ".intercalate (k.fields.map fun f => "let " ++ (if f.ty == .kids then kidsName else f.bind)) ++ ")"

def kind! (tag : String) : NodeKind := (nodes.find? (·.tag == tag)).getD { tag, render := [] }

/-! The string enums, from the Lean types (`ElmShell.Check` proves the lists complete). -/

def allStyles : List TextStyle := [.title, .body, .caption]
def allRoles : List ButtonRole := [.plain, .primary, .destructive]
def allInputKinds : List InputKind := [.plain, .secure, .multiline, .number, .decimal]

/-- (Swift name, raw values) of each string enum `NativeNode` nests. -/
def stringEnums : List (String × List String) :=
  [ ("Role", allRoles.map (·.str)), ("Style", allStyles.map (·.str)), ("InputKind", allInputKinds.map (·.str)) ]

/-! The events (PROTOCOL.md, "Client → CLI"): name and the Swift type of `value`, if any. -/

def events : List (String × Option String) :=
  [ ("click", none), ("submit", none), ("dismiss", none), ("input", some "String"), ("toggle", some "Bool"), ("select", some "Int") ]

end ElmShell
