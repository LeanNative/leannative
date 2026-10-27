import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

/// The top of the tree: tabs and screens get the platform's tab bar and navigation stack; anything else
/// is shown in a scrolling page.
struct NativeRoot: View {
    let node: NativeNode

    var body: some View {
        switch node {
        case .tabs(let labels, let icons, let selected, let children):
            NativeTabs(labels: labels, icons: icons, selected: selected, children: children)
        case .screen:
            NavigationStack { NativeScreen(node: node, path: []) }
        default:
            NavigationStack {
                ScrollView { NativeView(node: node, path: []).padding() }
                    .scrollDismissesKeyboard(.interactively)
            }
        }
    }
}

struct NativeTabs: View {
    @Environment(NativeStore.self) private var store
    let labels: [String]
    let icons: [String]
    let selected: Int
    let children: [NativeNode]

    var body: some View {
        TabView(selection: Binding(get: { selected }, set: { store.send(path: [], event: .select($0)) })) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                Group {
                    if i == selected {
                        content
                    } else {
                        Color.clear
                    }
                }
                .tabItem { Label(label, systemImage: icons.indices.contains(i) ? icons[i] : "circle") }
                .tag(i)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if children.count == 1, case .screen = children[0] {
            NavigationStack { NativeScreen(node: children[0], path: [0]) }
        } else {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(children.enumerated()), id: \.offset) { i, c in NativeView(node: c, path: [i]) }
                    }
                    .padding()
                }
            }
        }
    }
}

/// A `screen`: title, back button (`dismiss`), toolbar children in the navigation bar, the content in a
/// list when it is one, in a scrolling page otherwise.
struct NativeScreen: View {
    @Environment(NativeStore.self) private var store
    let node: NativeNode
    let path: [Int]

    var body: some View {
        if case .screen(let title, let back, let refreshable, let children) = node {
            let indexed = Array(children.enumerated())
            let toolbars = indexed.filter { if case .toolbar = $0.element { return true }; return false }
            let content = indexed.filter { if case .toolbar = $0.element { return false }; return true }
            // sheets, alerts and spacers present themselves or take no room: a screen whose only other
            // child is a list is shown as a native grouped list
            let overlays = content.filter { $0.element.isOverlay }
            let main = content.filter { !$0.element.isOverlay }
            Group {
                if main.count == 1, case .list(let items) = main[0].element {
                    List {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, c in
                            NativeView(node: c, path: path + [main[0].offset, i])
                        }
                    }
                    .background { ForEach(overlays, id: \.offset) { i, c in NativeView(node: c, path: path + [i]) } }
                    .modifier(PullToRefresh(enabled: refreshable) { await refresh() })
                } else if main.contains(where: { $0.element.isPage }) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(content, id: \.offset) { i, c in NativeView(node: c, path: path + [i]) }
                    }
                    .padding([.horizontal, .top])
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(content, id: \.offset) { i, c in NativeView(node: c, path: path + [i]) }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .modifier(PullToRefresh(enabled: refreshable) { await refresh() })
                }
            }
            // a different screen at the same place starts at its top, not at the last one's offset
            .id(title)
            .navigationTitle(title)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if back {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { store.send(path: path, event: .dismiss) } label: { Label("Back", systemImage: "chevron.backward") }
                    }
                }
                ForEach(toolbars, id: \.offset) { i, t in
                    if case .toolbar(let items) = t {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            ForEach(Array(items.enumerated()), id: \.offset) { j, item in
                                NativeView(node: item, path: path + [i, j])
                            }
                        }
                    }
                }
            }
        }
    }
}

extension NativeScreen {
    /// Pull-to-refresh: a `click` on the screen. The click's own reply comes back at once; the spinner stays
    /// until a later view arrives (the work the click started reporting back), at most 10 s.
    func refresh() async {
        store.send(path: path, event: .click)
        let answered = store.seq
        for _ in 0..<100 where store.seq == answered { try? await Task.sleep(for: .milliseconds(100)) }
    }
}

private struct PullToRefresh: ViewModifier {
    let enabled: Bool
    let action: () async -> Void
    func body(content: Content) -> some View {
        if enabled { content.refreshable { await action() } } else { content }
    }
}

extension NativeNode {
    /// Nodes that take no room in a layout: presentations and spacers.
    var isOverlay: Bool {
        switch self {
        case .sheet, .alert, .spacer: return true
        default: return false
        }
    }
    var isPage: Bool { if case .page = self { return true }; return false }
}

/// Recursive, generic renderer of a `NativeNode`. Child `i` of a container lives at `path + [i]`.
struct NativeView: View {
    @Environment(NativeStore.self) private var store
    let node: NativeNode
    let path: [Int]

    var body: some View {
        switch node {
        case .text(let s, let style):
            NativeText(s: s, style: style)
        case .col(let nodes):
            VStack(alignment: .leading, spacing: 12) { children(nodes) }
        case .row(let nodes):
            HStack(spacing: 12) { children(nodes) }.frame(minHeight: 44)
        case .button(let label, let role, let enabled):
            let b = Button(label, role: role == .destructive ? .destructive : nil) { store.send(path: path, event: .click) }
                .disabled(!enabled)
            if role == .primary { b.buttonStyle(.borderedProminent).controlSize(.large) } else { b.buttonStyle(.bordered) }
        case .field(let placeholder, let value, let submits):
            NativeField(path: path, kind: .plain, label: "", placeholder: placeholder, serverValue: value, submits: submits)
        case .input(let kind, let label, let placeholder, let value, let submits):
            NativeField(path: path, kind: kind, label: label, placeholder: placeholder, serverValue: value, submits: submits)
        case .toggle(let label, let on):
            Toggle(label, isOn: Binding(get: { on }, set: { store.send(path: path, event: .toggle($0)) }))
        case .divider:
            Divider()
        case .spacer:
            Spacer(minLength: 0)
        case .list(let nodes):
            VStack(alignment: .leading, spacing: 12) { children(nodes) }
        case .section(let header, let footer, let nodes):
            Section {
                children(nodes)
            } header: {
                if !header.isEmpty { Text(header) }
            } footer: {
                if !footer.isEmpty { Text(footer) }
            }
        case .labeled(let label, let value):
            LabeledContent(label) { NativeText(s: value, style: .body) }
        case .screen:
            NativeScreen(node: node, path: path)
        case .toolbar(let nodes):
            HStack { children(nodes) }
        case .tabs(let labels, let icons, let selected, let nodes):
            NativeTabs(labels: labels, icons: icons, selected: selected, children: nodes)
        case .sheet(let title, let dismissable, let nodes):
            Color.clear.frame(height: 0)
                .sheet(isPresented: Binding(get: { true }, set: { shown in
                    if !shown && dismissable { store.send(path: path, event: .dismiss) }
                })) {
                    NavigationStack {
                        Group {
                            // a sheet holding a page gives the page the rest of the sheet; it scrolls itself
                            if nodes.contains(where: \.isPage) {
                                VStack(alignment: .leading, spacing: 12) { children(nodes) }.padding([.horizontal, .top])
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) { children(nodes) }.padding()
                                }
                            }
                        }
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .interactiveDismissDisabled(!dismissable)
                    .environment(store)
                }
        case .alert(let title, let message, let nodes):
            Color.clear.frame(height: 0)
                .alert(title, isPresented: .constant(true)) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { i, n in
                        if case .button(let label, let role, _) = n {
                            Button(label, role: role == .destructive ? .destructive : nil) {
                                store.send(path: path + [i], event: .click)
                            }
                        }
                    }
                } message: {
                    Text(message)
                }
        case .picker(let label, let options, let selected):
            Picker(label, selection: Binding(get: { selected }, set: { store.send(path: path, event: .select($0)) })) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in Text(o).tag(i) }
            }
        case .progress(let label):
            ProgressView(label)
        case .icon(let name):
            Image(systemName: name)
        case .qr(let text):
            NativeQR(text: text)
        case .share(let label, let text, let file):
            if file {
                ShareLink(item: URL(fileURLWithPath: text)) { Label(label, systemImage: "square.and.arrow.up") }
            } else {
                ShareLink(item: text) { Label(label, systemImage: "square.and.arrow.up") }
            }
        case .link(let label, let url):
            if let u = URL(string: url) { Link(label, destination: u) } else { Text(label) }
        case .page(let path):
            NativePage(path: path).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty(let title, let icon, let message, let nodes):
            ContentUnavailableView {
                Label(title, systemImage: icon)
            } description: {
                Text(message)
            } actions: {
                children(nodes)
            }
        case .disclosure(let title, let expanded, let nodes):
            DisclosureGroup(title, isExpanded: Binding(get: { expanded }, set: { store.send(path: path, event: .toggle($0)) })) {
                children(nodes)
            }
        case .stepper(let label, let value, let lo, let hi, let detail):
            let binding = Binding(get: { value }, set: { store.send(path: path, event: .select($0)) })
            if detail.isEmpty {
                Stepper("\(label): \(value)", value: binding, in: lo...max(lo, hi))
            } else {
                Stepper(value: binding, in: lo...max(lo, hi)) { LabeledContent(label, value: detail) }
            }
        case .unknown(let t):
            Text("Unsupported node: \(t)").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func children(_ nodes: [NativeNode]) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { i, child in
            NativeView(node: child, path: path + [i])
        }
    }
}

/// Text; a word of 20 or more characters (an address, a txid) wraps at characters instead of being
/// hyphenated, so the screen never shows a character the string does not contain.
struct NativeText: View {
    let s: String
    let style: NativeNode.Style
    var body: some View {
        let t = Text(Self.breakable(s)).textSelection(.enabled)
        switch style {
        case .title: t.font(.title2.bold())
        case .body: t.font(.body)
        case .caption: t.font(.caption).foregroundStyle(.secondary)
        }
    }
    /// Zero-width spaces inside long runs let SwiftUI break there without inserting a hyphen.
    static func breakable(_ s: String) -> String {
        guard s.split(whereSeparator: \.isWhitespace).contains(where: { $0.count >= 20 }) else { return s }
        var out = ""
        var run = 0
        for ch in s {
            run = ch.isWhitespace ? 0 : run + 1
            if run > 1 { out.append("\u{200B}") }
            out.append(ch)
        }
        return out
    }
}

/// A text input: local text while typing, the app's value whenever it differs from the last one sent.
struct NativeField: View {
    @Environment(NativeStore.self) private var store
    let path: [Int]
    let kind: NativeNode.InputKind
    let label: String
    let placeholder: String
    let serverValue: String
    let submits: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !label.isEmpty { Text(label).font(.caption).foregroundStyle(.secondary) }
            control
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(kind == .number ? .numberPad : kind == .decimal ? .decimalPad : .default)
                .frame(minHeight: 44)
                .onAppear { text = serverValue }
                .onChange(of: text) { _, new in if new != serverValue { store.send(path: path, event: .input(new)) } }
                .onChange(of: serverValue) { _, new in if new != text { text = new } }
                .onSubmit { if submits { store.send(path: path, event: .submit) } }
        }
    }

    @ViewBuilder private var control: some View {
        switch kind {
        case .secure: SecureField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        case .multiline: TextField(placeholder, text: $text, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
        case .plain, .number, .decimal: TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

/// A QR code of the text (CoreImage), drawn with sharp modules.
struct NativeQR: View {
    let text: String
    var body: some View {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let context = CIContext()
        if let out = filter.outputImage, let cg = context.createCGImage(out, from: out.extent) {
            return AnyView(Image(decorative: cg, scale: 1).interpolation(.none).resizable().scaledToFit()
                .frame(maxWidth: 240).accessibilityLabel("QR code"))
        }
        return AnyView(Text(text))
    }
}

/// A bundled HTML page with the page's own scripts off and every load outside the bundle refused; its
/// `<body>` gets the class `embedded`.
struct NativePage: UIViewRepresentable {
    let path: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // pages shown inside an app get `embedded` on <body>, so a site's stylesheet can hide its own chrome
        config.userContentController.addUserScript(WKUserScript(source: "document.body.classList.add('embedded')",
                                                                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        guard let url = Bundle.main.url(forResource: path, withExtension: nil) else { return view }
        // subresources are blocked as well as navigations: a bundled page never reaches the network
        let rules = #"[{"trigger":{"url-filter":"^[a-zA-Z][a-zA-Z0-9+.-]*:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "elmlean-offline-pages-v1",
                                                                encodedContentRuleList: rules) { list, _ in
            guard let list else { return } // fail closed: no rules, no page
            view.configuration.userContentController.add(list)
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
