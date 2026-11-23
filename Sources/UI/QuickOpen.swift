import AppKit
import SwiftUI

/// ⌘P 跳转或新建: one field to find an open session, any server (folded or
/// hidden ones too), a recent folder to open with a shell or an agent, or a
/// command. Replaces digging through the nested new-session menus.
enum QuickOpen {
    enum Section: Int, CaseIterable {
        case open, servers, folders, commands

        var title: String {
            switch self {
            case .open: return "已打开"
            case .servers: return "服务器"
            case .folders: return "文件夹"
            case .commands: return "操作"
            }
        }
    }

    struct Action: Identifiable {
        let id: String
        let label: String
        let run: @MainActor () -> Void
    }

    struct Item: Identifiable {
        let id: String
        let section: Section
        let symbol: String
        let title: String
        let subtitle: String
        /// The first is what Return does; Tab steps through the rest.
        let actions: [Action]
        /// Where the query matched in `title`, for highlighting.
        var match: Range<String.Index>?
        var score: Int
    }

    // MARK: Matching

    /// How well `query` fits `text`: a substring beats letters in order; at
    /// the start or after a separator beats the middle. nil: no match.
    static func score(_ query: String, in text: String, inOrder: Bool = true) -> (score: Int, range: Range<String.Index>?)? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return (0, nil) }
        if let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            let offset = text.distance(from: text.startIndex, to: r.lowerBound)
            var s = 1000 - min(offset, 200)
            if offset == 0 { s += 300 }
            else if let before = text[..<r.lowerBound].last, " /-_.@·:".contains(before) { s += 150 }
            return (s, r)
        }
        // Letters in order ("hnas" → huapai-nas).
        guard inOrder else { return nil }
        var it = text.lowercased().makeIterator()
        for ch in q.lowercased() where ch != " " {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return nil }
        }
        return (100, nil)
    }

    // MARK: Items

    @MainActor
    static func items(for query: String, workspace: Workspace, catalog: AgentCatalog) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Item] = []

        func add(_ section: Section, id: String, symbol: String, title: String, subtitle: String,
                 searchable extra: [String] = [], actions: [Action]) {
            guard !actions.isEmpty else { return }
            if q.isEmpty {
                out.append(Item(id: id, section: section, symbol: symbol, title: title, subtitle: subtitle,
                                actions: actions, match: nil, score: 0))
                return
            }
            var best: (Int, Range<String.Index>?)?
            if let m = score(q, in: title) { best = (m.score + 200, m.range) }
            // Details only count as a whole word: letters in order there match almost anything.
            for text in [subtitle] + extra {
                if let m = score(q, in: text, inOrder: false), m.score > (best?.0 ?? -1) { best = (m.score, nil) }
            }
            guard let best else { return }
            out.append(Item(id: id, section: section, symbol: symbol, title: title, subtitle: subtitle,
                            actions: actions, match: best.1, score: best.0))
        }

        // Open sessions, in sidebar order.
        for s in workspace.orderedSessions {
            let isShell = s.agentPanes.isEmpty
            let title = isShell ? s.shellName : s.displayName
            var bits: [String] = []
            if let host = workspace.host(for: s) { bits.append(host.name) }
            if let name = s.remote?.sessionName { bits.append(name) }
            if s.remote == nil { bits.append(s.directory.abbreviatingHome) }
            if !isShell { bits.append(s.kind.name) }
            if let git = s.git { bits.append(git.branch) }
            if let cmd = s.shellCommand { bits.append(cmd.text) }
            add(.open, id: "session:\(s.id)", symbol: s.remote != nil && isShell ? "terminal" : s.kind.symbol,
                title: title, subtitle: bits.joined(separator: " · "),
                actions: [Action(id: "go", label: "切过去") { workspace.select(s) }])
        }

        // Servers: saved ones and ~/.ssh/config aliases. Without a query only
        // the ones the sidebar shows, so the list stays short.
        let inSidebar = Set(workspace.sidebarServers.map(\.id))
        let hosts = q.isEmpty ? workspace.sidebarServers : workspace.hosts
        for host in hosts {
            var actions = [Action(id: "new", label: "新会话") { workspace.connect(host) }]
            if case .sessions(let names, _, _)? = workspace.remoteListings[host.id] {
                let attached = Set(workspace.sessions(on: host).compactMap { $0.remote?.sessionName })
                for name in names where !attached.contains(name) {
                    actions.append(Action(id: "attach:\(name)", label: "附加 \(name)") {
                        workspace.connect(host, sessionName: name)
                    })
                }
            } else if host.persistence.usesSessionName {
                actions.append(Action(id: "pick", label: "附加…") { workspace.pickingSessionFor = host })
            }
            var subtitle = workspace.address(of: host)
            if !inSidebar.contains(host.id) {
                subtitle += host.visibility == .hidden ? " · 已隐藏" : " · 在“其他服务器”里"
            }
            add(.servers, id: "host:\(host.id)", symbol: host.symbol, title: host.name, subtitle: subtitle,
                searchable: [host.host], actions: actions)
        }
        if !q.isEmpty {
            // Hidden ones too: ⌘P is where they can still be found.
            for alias in workspace.sshConfigAliases + workspace.hiddenSSHConfigAliases {
                let git = workspace.isGitHosting(alias: alias)
                let note = git ? " · git 托管" : workspace.visibility(ofAlias: alias) == .hidden ? " · 已隐藏" : " · ~/.ssh/config"
                add(.servers, id: "alias:\(alias)", symbol: "server.rack", title: alias,
                    subtitle: workspace.address(ofAlias: alias) + note,
                    actions: [Action(id: "new", label: "新会话") { workspace.connect(alias: alias) }])
            }
        }

        // Folders: recent ones, plus a path you typed if it exists.
        var folders = workspace.recentDirectories
        let typed = (q as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if q.hasPrefix("/") || q.hasPrefix("~"),
           FileManager.default.fileExists(atPath: typed, isDirectory: &isDir), isDir.boolValue,
           !folders.contains(typed) {
            folders.insert(typed, at: 0)
        }
        let kinds = [AgentKind.shell] + catalog.available.filter(\.isAgent)
        for dir in folders.prefix(q.isEmpty ? 5 : 12) {
            let actions = kinds.map { kind in
                Action(id: kind.id, label: kind.name) { workspace.open(kind: kind, directory: dir) }
            }
            add(.folders, id: "dir:\(dir)", symbol: "folder", title: dir.abbreviatingHome,
                subtitle: dir == typed && !workspace.recentDirectories.contains(dir) ? "你输入的路径" : "最近用过",
                actions: actions)
        }

        // Commands.
        if !q.isEmpty {
            var host = RemoteHost.new()
            host.name = q
            host.host = q
            add(.commands, id: "cmd:addhost", symbol: "plus", title: "添加服务器“\(q)”…", subtitle: "",
                searchable: [q, "添加服务器"],
                actions: [Action(id: "go", label: "添加") { workspace.editingHost = host }])
        }
        add(.commands, id: "cmd:dashboard", symbol: "list.bullet.rectangle", title: "Agent 总览", subtitle: "⇧⌘A",
            searchable: ["dashboard", "agents"],
            actions: [Action(id: "go", label: "打开") { workspace.showingDashboard = true }])
        add(.commands, id: "cmd:resume", symbol: "clock.arrow.circlepath", title: "恢复之前的对话…", subtitle: "⇧⌘O",
            searchable: ["resume"], actions: [Action(id: "go", label: "打开") { workspace.showResume() }])
        add(.commands, id: "cmd:servers", symbol: "server.rack", title: "管理服务器…", subtitle: "",
            searchable: ["servers", "ssh", "hosts", "服务器"],
            actions: [Action(id: "go", label: "打开") { workspace.managingServers = true }])
        add(.commands, id: "cmd:agents", symbol: "gearshape", title: "管理 Agent…", subtitle: "",
            searchable: ["agents", "settings"], actions: [Action(id: "go", label: "打开") { workspace.managingAgents = true }])

        // With a query, best first within each section; sections keep their order.
        let limits: [Section: Int] = [.open: 8, .servers: 6, .folders: 6, .commands: q.isEmpty ? 0 : 4]
        return Section.allCases.flatMap { section -> [Item] in
            let list = out.filter { $0.section == section }
            let sorted = q.isEmpty ? list : list.sorted { $0.score > $1.score }
            return Array(sorted.prefix(limits[section] ?? 6))
        }
    }
}

/// The ⌘P panel, over the whole window.
struct QuickOpenView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var catalog: AgentCatalog
    @State private var query = ""
    @State private var selected = 0
    @State private var actionIndex = 0

    private var items: [QuickOpen.Item] {
        QuickOpen.items(for: query, workspace: workspace, catalog: catalog)
    }

    var body: some View {
        let items = self.items
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    QuickOpenField(text: $query, onCommand: { handle($0, items: items) })
                        .frame(height: 22)
                    Text("会话 · 服务器 · 文件夹").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                Divider()
                if items.isEmpty {
                    Text("没有匹配“\(query)”的会话、服务器或文件夹")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                    if i == 0 || items[i - 1].section != item.section {
                                        Text(item.section.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 14)
                                            .padding(.top, 10)
                                            .padding(.bottom, 3)
                                    }
                                    row(item, index: i)
                                        .id(item.id)
                                }
                            }
                            .padding(.bottom, 6)
                        }
                        .frame(maxHeight: 440)
                        .onChange(of: selected) { _, new in
                            if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                        }
                    }
                }
                Divider()
                HStack(spacing: 14) {
                    hint("↩", "打开")
                    hint("↑↓", "选择")
                    hint("⇥", "换一个动作（用哪个 Agent、附加哪个会话）")
                    Spacer()
                    hint("esc", "关闭")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(width: 660)
            .background(Color(red: 0.067, green: 0.11, blue: 0.19), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .padding(.top, 60)
        }
        .onChange(of: query) { _, _ in
            selected = 0
            actionIndex = 0
        }
        .onAppear {
            if !workspace.quickOpenSeed.isEmpty {
                query = workspace.quickOpenSeed
                workspace.quickOpenSeed = ""
            }
        }
    }

    private func row(_ item: QuickOpen.Item, index: Int) -> some View {
        let isSelected = index == selected
        return HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            highlighted(item)
                .lineLimit(1)
                .layoutPriority(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.actions.count == 1 {
                if isSelected {
                    Text(item.actions[0].label).font(.caption).foregroundStyle(.secondary)
                    Text("↩").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(item.actions.enumerated()), id: \.element.id) { j, action in
                        Button(action.label) { run(action) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(isSelected && j == actionIndex ? Color.accentColor.opacity(0.35)
                                        : Color.white.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12)))
                    }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { run(item.actions[0]) }
        .onHover { if $0 && selected != index { selected = index; actionIndex = 0 } }
    }

    private func highlighted(_ item: QuickOpen.Item) -> Text {
        guard let r = item.match else { return Text(item.title) }
        return Text(item.title[..<r.lowerBound])
            + Text(item.title[r]).foregroundColor(.accentColor).bold()
            + Text(item.title[r.upperBound...])
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced())
                .padding(.horizontal, 4)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(text)
        }
    }

    private func handle(_ command: QuickOpenField.Command, items: [QuickOpen.Item]) {
        switch command {
        case .down:
            guard !items.isEmpty else { return }
            selected = (selected + 1) % items.count
            actionIndex = 0
        case .up:
            guard !items.isEmpty else { return }
            selected = (selected - 1 + items.count) % items.count
            actionIndex = 0
        case .tab(let back):
            guard items.indices.contains(selected) else { return }
            let n = items[selected].actions.count
            actionIndex = (actionIndex + (back ? n - 1 : 1)) % n
        case .submit:
            guard items.indices.contains(selected) else { return }
            let actions = items[selected].actions
            run(actions[min(actionIndex, actions.count - 1)])
        case .cancel:
            close()
        }
    }

    private func run(_ action: QuickOpen.Action) {
        close()
        // After the panel is gone, so the session it opens gets the focus.
        DispatchQueue.main.async { action.run() }
    }

    private func close() {
        workspace.showingQuickOpen = false
        DispatchQueue.main.async { workspace.selected?.focusedPane?.terminal.focus() }
    }
}

/// The panel's search field: an NSTextField, so arrows, Tab, Return and Esc
/// reach the panel (and input methods work as anywhere else).
struct QuickOpenField: NSViewRepresentable {
    enum Command { case up, down, tab(back: Bool), submit, cancel }

    @Binding var text: String
    let onCommand: (Command) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.placeholderString = "跳转到会话、连接服务器、打开文件夹…"
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickOpenField
        init(parent: QuickOpenField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onCommand(.down)
            case #selector(NSResponder.moveUp(_:)): parent.onCommand(.up)
            case #selector(NSResponder.insertTab(_:)): parent.onCommand(.tab(back: false))
            case #selector(NSResponder.insertBacktab(_:)): parent.onCommand(.tab(back: true))
            case #selector(NSResponder.insertNewline(_:)): parent.onCommand(.submit)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCommand(.cancel)
            default: return false
            }
            return true
        }
    }
}
