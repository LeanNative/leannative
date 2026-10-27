import ElmShell.Grammar

/-! # ElmShell.View: `NativeView.swift`, the generic renderer

`NativeView`'s switch has one arm per kind of the grammar table (its `render`); `isOverlay` is the
table's `overlay` column. The rest is the layout around the tree: the root, tabs, screens, text, fields,
QR codes and bundled pages. -/

namespace ElmShell

def forEachChild (xs : String) (head : String) (path : String) : Expr :=
  cb "ForEach" [xs, "id: \\.offset"] head [s s!"NativeView(node: c, path: {path})"]

def root : Decl :=
  .doc "The top of the tree: tabs and screens get the platform's tab bar and navigation stack; anything else
is shown in a scrolling page."
  (.ty "struct NativeRoot: View"
    [ .prop "let node: NativeNode" none, .blank
    , .fn "var body: some View"
      [.switchS (r "node")
        [ ((kind! "tabs").pattern "children", [s "NativeTabs(labels: labels, icons: icons, selected: selected, children: children)"])
        , (".screen", [.e (cb "NavigationStack" [] "" [s "NativeScreen(node: node, path: [])"])])
        , ("default", [.e (cb "NavigationStack" [] ""
            [.e (m (cb "ScrollView" [] "" [s "NativeView(node: node, path: []).padding()"]) ["scrollDismissesKeyboard(.interactively)"])])]) ]] ])

def tabs : Decl :=
  .ty "struct NativeTabs: View"
    [ .prop "@Environment(NativeStore.self) private var store" none
    , .prop "let labels: [String]" none, .prop "let icons: [String]" none, .prop "let selected: Int" none
    , .prop "let children: [NativeNode]" none, .blank
    , .fn "var body: some View"
      [.e (cb "TabView" ["selection: Binding(get: { selected }, set: { store.send(path: [], event: .select($0)) })"] ""
        [.e (cb "ForEach" ["Array(labels.enumerated())", "id: \\.offset"] "i, label"
          [.e (m (cb "Group" [] "" [.ifS ["i == selected"] [s "content"] [s "Color.clear"]])
            ["tabItem { Label(label, systemImage: icons.indices.contains(i) ? icons[i] : \"circle\") }", "tag(i)"])])])]
    , .blank
    , .fn "@ViewBuilder private var content: some View"
      [.ifS ["children.count == 1", "case .screen = children[0]"]
        [.e (cb "NavigationStack" [] "" [s "NativeScreen(node: children[0], path: [0])"])]
        [.e (cb "NavigationStack" [] ""
          [.e (cb "ScrollView" [] ""
            [.e (m (column [.e (cb "ForEach" ["Array(children.enumerated())", "id: \\.offset"] "i, c" [s "NativeView(node: c, path: [i])"])])
              ["padding()"])])])]] ]

def screen : Decl :=
  let contentColumn := column [.e (forEachChild "content" "i, c" "path + [i]")]
  .doc "A `screen`: title, back button (`dismiss`), toolbar children in the navigation bar, the content in a
list when it is one, in a scrolling page otherwise."
  (.ty "struct NativeScreen: View"
    [ .prop "@Environment(NativeStore.self) private var store" none
    , .prop "let node: NativeNode" none, .prop "let path: [Int]" none, .blank
    , .fn "var body: some View"
      [.ifS [s!"case {(kind! "screen").pattern "children"} = node"]
        [ .letS "indexed" (r "Array(children.enumerated())")
        , .letS "toolbars" (r "indexed.filter { if case .toolbar = $0.element { return true }; return false }")
        , .letS "content" (r "indexed.filter { if case .toolbar = $0.element { return false }; return true }")
        , .comment "sheets, alerts and spacers present themselves or take no room: a screen whose only other\nchild is a list is shown as a native grouped list"
        , .letS "overlays" (r "content.filter { $0.element.isOverlay }")
        , .letS "main" (r "content.filter { !$0.element.isOverlay }")
        , .e (.chain (cb "Group" [] ""
            [.ifS ["main.count == 1", "case .list(let items) = main[0].element"]
              [.e (.chain (cb "List" [] ""
                  [.e (cb "ForEach" ["Array(items.enumerated())", "id: \\.offset"] "i, c" [s "NativeView(node: c, path: path + [main[0].offset, i])"])])
                [ .call (r "background") [] [(none, .lam "" [.e (forEachChild "overlays" "i, c" "path + [i]")])]
                , r "modifier(PullToRefresh(enabled: refreshable) { await refresh() })" ])]
              [.ifS ["main.contains(where: { $0.element.isPage })"]
                [.e (m contentColumn ["padding([.horizontal, .top])"])]
                [.e (m (cb "ScrollView" [] "" [.e (m contentColumn ["padding()"])])
                  ["scrollDismissesKeyboard(.interactively)", "modifier(PullToRefresh(enabled: refreshable) { await refresh() })"])]]])
            [ r "id(title)", r "navigationTitle(title)", r "navigationBarBackButtonHidden(true)"
            , .call (r "toolbar") [] [(none, .lam ""
                [ .ifS ["back"] [.e (cb "ToolbarItem" ["placement: .topBarLeading"] ""
                    [.e (.call (r "Button") [] [(none, .lam "" [s "store.send(path: path, event: .dismiss)"]),
                      (some "label", .lam "" [s "Label(\"Back\", systemImage: \"chevron.backward\")"])])])] []
                , .e (cb "ForEach" ["toolbars", "id: \\.offset"] "i, t"
                    [.ifS [s!"case {(kind! "toolbar").pattern "items"} = t"]
                      [.e (cb "ToolbarItemGroup" ["placement: .topBarTrailing"] ""
                        [.e (cb "ForEach" ["Array(items.enumerated())", "id: \\.offset"] "j, item"
                          [s "NativeView(node: item, path: path + [i, j])"])])] []]) ])] ]) ] []] ])

def screenRefresh : Decl :=
  .ty "extension NativeScreen"
    [.doc "Pull-to-refresh: a `click` on the screen. The click's own reply comes back at once; the spinner stays
until a later view arrives (the work the click started reporting back), at most 10 s."
      (.fn "func refresh() async"
        [ s "store.send(path: path, event: .click)"
        , .letS "answered" (r "store.seq")
        , .forS "_ in 0..<100 where store.seq == answered" [s "try? await Task.sleep(for: .milliseconds(100))"] ])]

def pullToRefresh : Decl :=
  .ty "private struct PullToRefresh: ViewModifier"
    [ .prop "let enabled: Bool" none, .prop "let action: () async -> Void" none
    , .fn "func body(content: Content) -> some View"
      [.ifS ["enabled"] [s "content.refreshable { await action() }"] [s "content"]] ]

def nodeExtension : Decl :=
  .ty "extension NativeNode"
    [ .doc "Nodes that take no room in a layout: presentations and spacers."
        (.fn "var isOverlay: Bool"
          [.switchS (r "self")
            [ (", ".intercalate ((nodes.filter (·.overlay)).map ("." ++ ·.tag)), [.ret (r "true")])
            , ("default", [.ret (r "false")]) ]])
    , .fn "var isPage: Bool" [s "if case .page = self { return true }; return false"] ]

def renderArm (k : NodeKind) : String × List Stmt :=
  (if k.binds then k.pattern else "." ++ k.tag, k.render)

def nativeView : Decl :=
  .doc "Recursive, generic renderer of a `NativeNode`. Child `i` of a container lives at `path + [i]`."
  (.ty "struct NativeView: View"
    [ .prop "@Environment(NativeStore.self) private var store" none
    , .prop "let node: NativeNode" none, .prop "let path: [Int]" none, .blank
    , .fn "var body: some View"
      [.switchS (r "node") (nodes.map renderArm ++
        [(".unknown(let t)", [s "Text(\"Unsupported node: \\(t)\").font(.footnote).foregroundStyle(.secondary)"])])]
    , .blank
    , .fn "@ViewBuilder private func children(_ nodes: [NativeNode]) -> some View"
      [.e (cb "ForEach" ["Array(nodes.enumerated())", "id: \\.offset"] "i, child" [s "NativeView(node: child, path: path + [i])"])] ])

def text : Decl :=
  .doc "Text; a word of 20 or more characters (an address, a txid) wraps at characters instead of being
hyphenated, so the screen never shows a character the string does not contain."
  (.ty "struct NativeText: View"
    [ .prop "let s: String" none, .prop "let style: NativeNode.Style" none
    , .fn "var body: some View"
      [ .letS "t" (r "Text(Self.breakable(s)).textSelection(.enabled)")
      , .switchS (r "style")
        [ (".title", [s "t.font(.title2.bold())"]), (".body", [s "t.font(.body)"])
        , (".caption", [s "t.font(.caption).foregroundStyle(.secondary)"]) ] ]
    , .doc "Zero-width spaces inside long runs let SwiftUI break there without inserting a hyphen."
      (.fn "static func breakable(_ s: String) -> String"
        [ .guardS ["s.split(whereSeparator: \\.isWhitespace).contains(where: { $0.count >= 20 })"] [.ret (r "s")]
        , .varS "out" (r "\"\""), .varS "run" (r "0")
        , .forS "ch in s"
          [ .set "run" (r "ch.isWhitespace ? 0 : run + 1")
          , .ifS ["run > 1"] [s "out.append(\"\\u{200B}\")"] []
          , s "out.append(ch)" ]
        , .ret (r "out") ]) ])

def field : Decl :=
  .doc "A text input: local text while typing, the app's value whenever it differs from the last one sent."
  (.ty "struct NativeField: View"
    [ .prop "@Environment(NativeStore.self) private var store" none
    , .prop "let path: [Int]" none, .prop "let kind: NativeNode.InputKind" none, .prop "let label: String" none
    , .prop "let placeholder: String" none, .prop "let serverValue: String" none, .prop "let submits: Bool" none
    , .prop "@State private var text" (some (r "\"\"")), .blank
    , .fn "var body: some View"
      [.e (cb "VStack" ["alignment: .leading", "spacing: 4"] ""
        [ .ifS ["!label.isEmpty"] [s "Text(label).font(.caption).foregroundStyle(.secondary)"] []
        , .e (m (r "control")
            [ "textInputAutocapitalization(.never)", "autocorrectionDisabled()"
            , "keyboardType(kind == .number ? .numberPad : kind == .decimal ? .decimalPad : .default)"
            , "frame(minHeight: 44)", "onAppear { text = serverValue }"
            , "onChange(of: text) { _, new in if new != serverValue { store.send(path: path, event: .input(new)) } }"
            , "onChange(of: serverValue) { _, new in if new != text { text = new } }"
            , "onSubmit { if submits { store.send(path: path, event: .submit) } }" ]) ])]
    , .blank
    , .fn "@ViewBuilder private var control: some View"
      [.switchS (r "kind")
        [ (".secure", [s "SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder)"])
        , (".multiline", [s "TextField(placeholder, text: $text, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)"])
        , (".plain, .number, .decimal", [s "TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)"]) ]] ])

def qr : Decl :=
  .doc "A QR code of the text (CoreImage), drawn with sharp modules."
  (.ty "struct NativeQR: View"
    [ .prop "let text: String" none
    , .fn "var body: some View"
      [ .letS "filter" (r "CIFilter.qrCodeGenerator()")
      , .set "filter.message" (r "Data(text.utf8)")
      , .set "filter.correctionLevel" (r "\"M\"")
      , .letS "context" (r "CIContext()")
      , .ifS ["let out = filter.outputImage", "let cg = context.createCGImage(out, from: out.extent)"]
        [.ret (some (r "AnyView(Image(decorative: cg, scale: 1).interpolation(.none).resizable().scaledToFit()\n                .frame(maxWidth: 240).accessibilityLabel(\"QR code\"))"))] []
      , .ret (some (r "AnyView(Text(text))")) ] ])

def page : Decl :=
  .doc "A bundled HTML page with the page's own scripts off and every load outside the bundle refused; its
`<body>` gets the class `embedded`."
  (.ty "struct NativePage: UIViewRepresentable"
    [ .prop "let path: String" none, .blank
    , .ty "final class Coordinator: NSObject, WKNavigationDelegate"
      [.fn "func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,\n             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void)"
        [s "decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)"]]
    , .blank
    , .fn "func makeCoordinator() -> Coordinator" [s "Coordinator()"]
    , .blank
    , .fn "func makeUIView(context: Context) -> WKWebView"
      [ .letS "config" (r "WKWebViewConfiguration()")
      , .set "config.defaultWebpagePreferences.allowsContentJavaScript" (r "false")
      , .comment "pages shown inside an app get `embedded` on <body>, so a site's stylesheet can hide its own chrome"
      , s "config.userContentController.addUserScript(WKUserScript(source: \"document.body.classList.add('embedded')\",\n                                                                injectionTime: .atDocumentEnd, forMainFrameOnly: true))"
      , .letS "view" (r "WKWebView(frame: .zero, configuration: config)")
      , .set "view.navigationDelegate" (r "context.coordinator")
      , .set "view.isOpaque" (r "false")
      , .set "view.backgroundColor" (r ".systemBackground")
      , .guardS ["let url = Bundle.main.url(forResource: path, withExtension: nil)"] [.ret (some (r "view"))]
      , .comment "subresources are blocked as well as navigations: a bundled page never reaches the network"
      , .letS "rules" (r "#\"[{\"trigger\":{\"url-filter\":\"^[a-zA-Z][a-zA-Z0-9+.-]*:\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{\"url-filter\":\"^file:\"},\"action\":{\"type\":\"ignore-previous-rules\"}}]\"#")
      , .e (.call (r "WKContentRuleListStore.default().compileContentRuleList")
          [(some "forIdentifier", .lit "elmlean-offline-pages-v1"), (some "encodedContentRuleList", r "rules")]
          [(none, .lam "list, _"
            [ .comment "fail closed: no rules, no page"
            , .guardS ["let list"] [.ret none]
            , s "view.configuration.userContentController.add(list)"
            , s "view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())" ])])
      , .ret (some (r "view")) ]
    , .blank
    , .fn "func updateUIView(_ view: WKWebView, context: Context)" [] ])

def viewFile : List Decl :=
  [ .imp "CoreImage.CIFilterBuiltins", .imp "SwiftUI", .imp "WebKit"
  , root, tabs, screen, screenRefresh, pullToRefresh, nodeExtension, nativeView, text, field, qr, page ]

end ElmShell
