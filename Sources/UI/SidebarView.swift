import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var workspace: Workspace
    @State private var renamingGroup: String?
    @State private var newGroupFor: AgentSession?
    @AppStorage("sidebar.othersExpanded") private var othersExpanded = false

    var body: some View {
        // While the Agent 总览 is up no session is "the current one": clicking
        // any of them, the selected one included, goes to it.
        List(selection: Binding(
            get: { workspace.showingDashboard ? nil : workspace.selectedID },
            set: { id in
                if workspace.showingDashboard {
                    if let s = workspace.sessions.first(where: { $0.id == id }) { workspace.select(s) }
                } else {
                    workspace.selectedID = id
                }
            })) {
            Section {
                rows(for: nil)
            } header: {
                MachineHeader(count: workspace.sessions(in: nil).count
                              + workspace.groups.reduce(0) { $0 + workspace.sessions(in: $1).count })
            }
            ForEach(workspace.groups.filter { !workspace.sessions(in: $0).isEmpty }, id: \.self) { group in
                Section(isExpanded: expandedBinding(group)) {
                    rows(for: group)
                } header: {
                    HStack(spacing: 4) {
                        Text("本机").foregroundStyle(.tertiary)
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        Text(group)
                    }
                    .contextMenu {
                        Button("重命名分组…") { renamingGroup = group }
                        Button("解散分组") { workspace.ungroup(group) }
                    }
                }
            }
            ForEach(workspace.sidebarServers) { host in
                Section(isExpanded: serverBinding(host)) {
                    let open = workspace.sessions(on: host)
                    if open.isEmpty {
                        RemoteListingRows(host: host)
                    } else {
                        ForEach(open) { session in
                            SessionRow(session: session)
                                .tag(session.id)
                                .contextMenu { menu(for: session) }
                        }
                    }
                } header: {
                    ServerHeader(host: host)
                }
            }
            Section(isExpanded: $othersExpanded) {
                OtherServers()
            } header: {
                HStack {
                    Text("其他服务器")
                    Text("\(workspace.otherServers.count)").foregroundStyle(.tertiary)
                    Spacer()
                    Button { workspace.managingServers = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help("管理服务器：固定、自动或隐藏每台服务器")
                    Button { workspace.editingHost = RemoteHost.new() } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("添加服务器")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Button { workspace.showingQuickOpen = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("跳转或新建…")
                    Spacer()
                    Text("⌘P").font(.caption.monospaced())
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .help("跳转到会话、连接服务器、打开文件夹（⌘P）")
        }
        .sheet(item: Binding(get: { renamingGroup.map(GroupRef.init) }, set: { renamingGroup = $0?.name })) { ref in
            RenameSheet(title: "重命名分组", initial: ref.name) { workspace.renameGroup(ref.name, to: $0) }
        }
        .sheet(item: $newGroupFor) { session in
            RenameSheet(title: "新建分组", initial: session.folderName) { name in
                let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { workspace.move(session, toGroup: n) }
            }
        }
    }

    private func serverBinding(_ host: RemoteHost) -> Binding<Bool> {
        Binding(
            get: { workspace.serverOpen[host.id] ?? !workspace.sessions(on: host).isEmpty },
            set: { workspace.serverOpen[host.id] = $0 })
    }

    @ViewBuilder
    private func rows(for group: String?) -> some View {
        ForEach(workspace.sessions(in: group)) { session in
            SessionRow(session: session)
                .tag(session.id)
                .contextMenu { menu(for: session) }
        }
        .onMove { workspace.move(inGroup: group, from: $0, to: $1) }
    }

    @ViewBuilder
    private func menu(for session: AgentSession) -> some View {
        if session.remote != nil {
            Button("重新连接") { workspace.reconnect(session) }
            if let host = workspace.host(for: session) {
                Button("编辑服务器…") { workspace.editingHost = host }
            }
            Divider()
        }
        if session.remote == nil, session.kind.isAgent || !session.agentPanes.isEmpty {
            ForEach(session.agentPanes.filter { $0.agent?.activity == .exited }, id: \.terminal.paneID) { pane in
                Button("重新启动 \(pane.agent?.kind.name ?? "")") { workspace.restartAgent(session, pane: pane) }
            }
            if session.kind.isAgent && session.kind.history != .none {
                Button("恢复这个文件夹的其他对话…") {
                    workspace.showResume(directory: session.directory, agentID: session.kind.id)
                }
            }
            Divider()
        }
        Button("重命名…") { workspace.renaming = session }
        if session.remote == nil { groupMenu(for: session) }
        Divider()
        if session.remote == nil {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.directory)
            }
            Button("同目录再开一个") {
                workspace.open(kind: session.kind, directory: session.directory, group: session.group)
            }
        }
        Divider()
        Button("关闭", role: .destructive) { workspace.close(session) }
        if session.worktree != nil {
            Button("关闭并删除 worktree…", role: .destructive) { workspace.closeRemovingWorktree(session) }
        }
    }

    @ViewBuilder
    private func groupMenu(for session: AgentSession) -> some View {
        Menu("移到分组") {
            ForEach(workspace.groups.filter { $0 != session.group }, id: \.self) { g in
                Button(g) { workspace.move(session, toGroup: g) }
            }
            if !workspace.groups.isEmpty { Divider() }
            Button("新建分组…") { newGroupFor = session }
            if session.group != nil {
                Button("移出分组") { workspace.move(session, toGroup: nil) }
            }
        }
    }

    private func expandedBinding(_ group: String) -> Binding<Bool> {
        Binding(
            get: { !workspace.collapsedGroups.contains(group) },
            set: { open in
                if open { workspace.collapsedGroups.remove(group) } else { workspace.collapsedGroups.insert(group) }
            })
    }
}

private struct GroupRef: Identifiable {
    let name: String
    var id: String { name }
}

struct SessionRow: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var workspace: Workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped each time the session starts needing you, to bounce its icon once.
    @State private var nudge = 0

    /// An agent waiting on you, or a bell / notification you haven't looked at.
    private var needsYou: Bool {
        if case .waiting = session.activity { return true }
        if case .needsAttention = session.status { return true }
        return false
    }

    var body: some View {
        // A plain shell is one line; agents keep their state and branch.
        if session.agentPanes.isEmpty {
            ShellRow(session: session)
        } else {
            agentBody
        }
    }

    private var agentBody: some View {
        HStack(spacing: 8) {
            Image(systemName: session.kind.symbol)
                .frame(width: 18)
                .foregroundStyle(needsYou ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: nudge)
                .animation(.easeInOut(duration: 0.25), value: needsYou)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if !listsAgents, let label = session.activity.label {
                        ActivityBadge(activity: session.activity, label: label)
                    }
                    Text(session.folderName)
                    if session.panes.count > 1 {
                        Text("· \(session.panes.count) 个窗格")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let git = session.git {
                    GitLine(git: git, isWorktree: session.worktree != nil)
                }
                if listsAgents {
                    ForEach(session.agentPanes, id: \.terminal.paneID) { pane in
                        AgentLine(session: session, pane: pane)
                    }
                }
            }
            Spacer(minLength: 4)
            if !listsAgents, session.activity == .exited, let pane = session.agentPanes.first {
                RestartAgentButton(session: session, pane: pane)
            } else if session.isDisconnected {
                Button { workspace.reconnect(session) } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("已断开，点击重新连接（会重新附加服务器上的会话）")
            } else {
                StatusDot(status: session.status)
            }
        }
        .padding(.vertical, 2)
        .help(helpText)
        .onChange(of: needsYou) { _, now in
            if now && !reduceMotion { nudge += 1 }
        }
    }

    /// One agent, the one the session was opened with, is summed up in the
    /// row itself. Anything else gets a line per agent.
    private var listsAgents: Bool {
        !session.agentPanes.isEmpty && !session.hasOnlyPrimaryAgent
    }

    private var helpText: String {
        var parts = [session.directory.abbreviatingHome]
        if let wt = session.worktree {
            parts.append("worktree：\(wt.branch)，从 \(wt.base) 分出，主仓库 \(wt.repo.abbreviatingHome)")
        }
        if case .needsAttention(let msg?) = session.status { parts.append(msg) }
        let agents = session.agentPanes.compactMap(\.agent)
        for agent in agents {
            let who = agents.count > 1 ? "\(agent.kind.name)：" : ""
            if case .waiting(let msg?) = agent.activity { parts.append(who + msg) }
            if let id = agent.conversationID { parts.append("\(who)对话 \(id)") }
        }
        return parts.joined(separator: "\n")
    }
}

/// One agent of a session that holds several: its own state, and a click
/// goes to its pane.
private struct AgentLine: View {
    @ObservedObject var session: AgentSession
    let pane: PaneView
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        if let agent = pane.agent {
            HStack(spacing: 4) {
                Image(systemName: agent.kind.symbol)
                    .font(.caption2)
                    .frame(width: 12)
                Text(session.agentLabel(for: pane))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let label = agent.activity.label {
                    ActivityBadge(activity: agent.activity, label: label)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if agent.activity == .exited {
                    RestartAgentButton(session: session, pane: pane)
                }
            }
            .font(.caption)
            .foregroundStyle(pane === session.focusedPane ? .primary : .secondary)
            .contentShape(Rectangle())
            .onTapGesture { workspace.show(pane, in: session) }
            .help("点击切到这个 Agent 的窗格")
        }
    }
}

private struct RestartAgentButton: View {
    let session: AgentSession
    let pane: PaneView
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        let name = pane.agent?.kind.name ?? ""
        Button { workspace.restartAgent(session, pane: pane) } label: {
            Image(systemName: "play.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(pane.agent?.conversationID != nil ? "重新启动 \(name)，回到同一段对话" : "重新启动 \(name)")
    }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .running:
            EmptyView()
        case .needsAttention:
            PulsingDot(color: .orange, size: 8)
                .help("等你处理")
        case .finished(let code):
            Circle().fill(code == 0 || code == -1 ? Color.green.opacity(0.7) : .red).frame(width: 6, height: 6)
        case .disconnected:
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange)
        }
    }
}

struct NewSessionMenu: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var catalog: AgentCatalog

    var body: some View {
        Menu {
            ForEach(catalog.available) { kind in
                Menu {
                    Button("选择文件夹…") { NewSessionPanel.present(kind: kind, in: workspace) }
                    if !workspace.recentDirectories.isEmpty {
                        Divider()
                        ForEach(workspace.recentDirectories, id: \.self) { dir in
                            Button(dir.abbreviatingHome) { workspace.open(kind: kind, directory: dir) }
                        }
                    }
                    if kind.history != .none && kind.canResume {
                        Divider()
                        Button("恢复之前的对话…") { workspace.showResume(agentID: kind.id) }
                    }
                } label: {
                    Label(kind.name, systemImage: kind.symbol)
                }
            }
            Divider()
            Button("管理 Agent…") { workspace.managingAgents = true }
            Divider()
            Menu {
                ForEach(workspace.hosts) { host in
                    Button { workspace.connect(host) } label: { Label(host.name, systemImage: host.symbol) }
                }
                if !workspace.sshConfigAliases.isEmpty {
                    Divider()
                    Section("~/.ssh/config") {
                        ForEach(workspace.sshConfigAliases, id: \.self) { alias in
                            Button(alias) { workspace.connect(alias: alias) }
                        }
                    }
                }
                Divider()
                Button("添加服务器…") { workspace.editingHost = RemoteHost.new() }
                Button("管理服务器…") { workspace.managingServers = true }
            } label: {
                Label("连接服务器", systemImage: "server.rack")
            }
        } label: {
            Label("新建会话", systemImage: "plus")
        }
        .help("新建会话")
    }
}

enum NewSessionPanel {
    @MainActor
    static func present(kind: AgentKind, in workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "在此打开 \(kind.name)"
        if let recent = workspace.recentDirectories.first {
            panel.directoryURL = URL(fileURLWithPath: recent)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.open(kind: kind, directory: url.path, group: workspace.selected?.group)
    }
}

/// The 本机 section header: this Mac, and a menu to open a session here.
private struct MachineHeader: View {
    let count: Int
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var catalog: AgentCatalog

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "laptopcomputer")
            Text("本机")
            Text("\(count)").foregroundStyle(.tertiary)
            Spacer()
            Menu {
                ForEach(catalog.available) { kind in
                    Menu {
                        Button("选择文件夹…") { NewSessionPanel.present(kind: kind, in: workspace) }
                        if !workspace.recentDirectories.isEmpty {
                            Divider()
                            ForEach(workspace.recentDirectories, id: \.self) { dir in
                                Button(dir.abbreviatingHome) { workspace.open(kind: kind, directory: dir) }
                            }
                        }
                    } label: {
                        Label(kind.name, systemImage: kind.symbol)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("在本机新建会话")
        }
    }
}

/// A server's section header: its name, whether its sessions are
/// connected, and a button for another session on it.
private struct ServerHeader: View {
    let host: RemoteHost
    @EnvironmentObject private var workspace: Workspace

    private var open: [AgentSession] { workspace.sessions(on: host) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: host.symbol)
            Text(host.name).lineLimit(1)
            state
            Spacer()
            Button { workspace.connect(host) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("在 \(host.name) 上新建会话")
        }
        .help(workspace.address(of: host))
        .contextMenu {
            Button("新会话") { workspace.connect(host) }
            if host.persistence.usesSessionName {
                Button("附加到已有会话…") { workspace.pickingSessionFor = host }
            }
            Divider()
            Button("编辑…") { workspace.editingHost = host }
            if host.isPinned {
                Button("不固定（没有会话时收进“其他服务器”）") { workspace.setPinned(host, false) }
            } else {
                Button("固定到侧边栏") { workspace.setPinned(host, true) }
            }
            Button("管理服务器…") { workspace.managingServers = true }
        }
    }

    @ViewBuilder private var state: some View {
        if open.isEmpty {
            Text("未连接").foregroundStyle(.tertiary)
        } else if open.allSatisfy(\.isDisconnected) {
            Circle().fill(Color.orange).frame(width: 6, height: 6).help("已断开")
        } else {
            Circle().fill(Color.green.opacity(0.85)).frame(width: 6, height: 6).help("已连接")
        }
    }
}

/// Under a server with nothing open: the tmux / zellij sessions already on
/// it, to attach with one click. Looked up when the section is opened.
private struct RemoteListingRows: View {
    let host: RemoteHost
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        Group {
            switch workspace.remoteListings[host.id] {
            case .sessions(let names, let mux, _) where !names.isEmpty:
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "circle.dashed").font(.caption).foregroundStyle(.tertiary).frame(width: 18)
                        Text(name).lineLimit(1)
                        Text(mux ?? "").font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                        Button("附加") { workspace.connect(host, sessionName: name) }
                            .controlSize(.small)
                    }
                    .help("附加到 \(host.name) 上的 \(mux ?? "") 会话 \(name)")
                }
            case .sessions(_, let mux, _):
                HStack(spacing: 6) {
                    Text(mux == nil ? "没有 tmux / zellij，断开后不能接回" : "服务器上还没有会话")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("新会话") { workspace.connect(host) }.controlSize(.small)
                }
            case .failed(let message):
                HStack(spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("重试") { workspace.loadRemoteSessions(host, force: true) }.controlSize(.small)
                }
                .help(message)
            default:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在看服务器上的会话…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { workspace.loadRemoteSessions(host) }
    }
}

/// 其他服务器: servers without a section of their own, one line each. Git
/// hosting entries from ~/.ssh/config are left out unless you ask.
private struct OtherServers: View {
    @EnvironmentObject private var workspace: Workspace
    @State private var showGitHosting = false

    var body: some View {
        ForEach(workspace.otherServers) { item in
            row(item)
        }
        let git = workspace.gitHostingAliases
        if !git.isEmpty {
            Button {
                showGitHosting.toggle()
            } label: {
                Text(showGitHosting ? "收起 git 托管条目" : gitHint(git))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            if showGitHosting {
                ForEach(git, id: \.self) { row(.alias($0)).opacity(0.7) }
            }
        }
    }

    private func row(_ item: Workspace.ServerItem) -> some View {
        HStack(spacing: 6) {
            switch item {
            case .host(let host):
                Image(systemName: host.symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(host.name).lineLimit(1).layoutPriority(1)
                let address = workspace.address(of: host)
                if address != host.name {
                    Text(address).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            case .alias(let alias):
                Image(systemName: "server.rack").frame(width: 18).foregroundStyle(.tertiary)
                Text(alias).lineLimit(1).layoutPriority(1)
                let address = workspace.address(ofAlias: alias)
                if address != alias {
                    Text(address).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            ConnectButton { connect(item) }
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button("连接") { connect(item) }
            switch item {
            case .host(let host):
                Button("固定到侧边栏") { workspace.setPinned(host, true) }
                Button("隐藏（只在 ⌘P 和管理服务器里显示）") { workspace.setVisibility(.hidden, of: host) }
                Button("编辑…") { workspace.editingHost = host }
                Divider()
                Button("删除", role: .destructive) { confirmDelete(host) }
            case .alias(let alias):
                Button("固定到侧边栏") { workspace.pin(alias: alias) }
                Button("隐藏（只在 ⌘P 和管理服务器里显示）") { workspace.setVisibility(.hidden, ofAlias: alias) }
                Button("保存为服务器…") { workspace.editingHost = .fromSSHConfig(alias: alias) }
            }
            Divider()
            Button("管理服务器…") { workspace.managingServers = true }
        }
    }

    private func gitHint(_ git: [String]) -> String {
        if git.count == 1 { return "\(git[0]) 是 git 托管，已隐藏 · 显示" }
        return "\(git.prefix(2).joined(separator: "、"))\(git.count > 2 ? " 等 \(git.count) 个" : "") git 托管已隐藏 · 显示"
    }

    private func connect(_ item: Workspace.ServerItem) {
        switch item {
        case .host(let host): workspace.connect(host)
        case .alias(let alias): workspace.connect(alias: alias)
        }
    }

    private func confirmDelete(_ host: RemoteHost) {
        let alert = NSAlert()
        alert.messageText = "删除服务器“\(host.name)”？"
        alert.informativeText = "只删除 Waitlight 里的配置和钥匙串里保存的密码，不会影响服务器，也不会关闭已打开的会话。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { workspace.deleteHost(host) }
    }
}

/// A plain shell in one line: its folder (or your name for it), the command
/// running now, and on the right how long it has run, how it ended, or
/// that it rang.
private struct ShellRow: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        // A task handed out on a server: its worktree's branch and changes too.
        if session.worktree != nil, let git = session.git {
            VStack(alignment: .leading, spacing: 2) {
                line
                GitLine(git: git, isWorktree: true).padding(.leading, 24)
            }
        } else {
            line
        }
    }

    private var line: some View {
        HStack(spacing: 6) {
            Image(systemName: session.remote == nil ? session.kind.symbol : "terminal")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(session.shellName)
                .lineLimit(1)
                .layoutPriority(1)
            if let command = session.shellCommand {
                Text(command.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if session.panes.count > 1 {
                Text("\(session.panes.count) 个窗格").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 1)
        .help(help)
    }

    @ViewBuilder private var trailing: some View {
        if session.isDisconnected {
            Button { workspace.reconnect(session) } label: {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("已断开，点击重新连接（会重新附加服务器上的会话）")
        } else if case .needsAttention = session.status {
            HStack(spacing: 3) {
                PulsingDot(color: .orange, size: 6)
                Text("响铃").foregroundStyle(.orange)
            }
            .font(.caption)
        } else if let command = session.shellCommand {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.age(from: command.since, to: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.blue)
            }
        } else if case .finished(let code) = session.status, code != 0, code != -1 {
            Text("退出 \(code)").font(.caption).foregroundStyle(.red)
        }
    }

    private var help: String {
        var parts = [session.remote == nil ? session.directory.abbreviatingHome : (session.remoteLabel ?? "")]
        if let command = session.shellCommand { parts.append("正在运行：\(command.text)") }
        if let wt = session.worktree {
            parts.append("worktree：\(wt.path)，分支 \(wt.branch)，从 \(wt.base) 分出")
        } else if let dir = session.remote?.directory {
            parts.append(dir)
        }
        if let git = session.git { parts.append("分支 \(git.branch)") }
        if case .needsAttention(let msg?) = session.status { parts.append(msg) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func age(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "刚开始" }
        if s < 3600 { return "\(s / 60) 分" }
        if s < 86400 { return "\(s / 3600) 时" }
        return "\(s / 86400) 天"
    }
}

private struct ConnectButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: hovering ? "play.circle.fill" : "play.circle")
                .foregroundStyle(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .scaleEffect(hovering && !reduceMotion ? 1.12 : 1)
        }
        .buttonStyle(.borderless)
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovering = h }
        }
        .help("连接")
    }
}

/// "运行中 / 等你 / 本轮完成 …" next to the folder name.
///
/// Motion carries meaning: working shimmers, waiting ripples (it's the one
/// that needs you), done/ready stay still. Everything goes static under
/// "Reduce motion".
struct ActivityBadge: View {
    let activity: AgentActivity
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped when a turn finishes, for a single bounce of the dot.
    @State private var finished = 0
    @ObservedObject private var visibility = AppVisibility.shared

    var body: some View {
        HStack(spacing: 3) {
            switch activity {
            case .working:
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && visibility.isVisible)
                Text(label).foregroundStyle(color).shimmer(active: !reduceMotion)
            case .waiting:
                PulsingDot(color: color, size: 5)
                Text(label).foregroundStyle(color).fontWeight(.medium)
            default:
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(color)
                    .symbolEffect(.bounce, value: finished)
                Text(label).foregroundStyle(color)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activity)
        .onChange(of: activity) { old, new in
            if new == .done && old != .done && !reduceMotion { finished += 1 }
        }
    }

    private var color: Color {
        switch activity {
        case .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .exited: return .secondary
        default: return .secondary
        }
    }
}

/// Whether any of the app's windows can be seen. Endless animations run on
/// the main thread every frame, so they stop while nobody can see them
/// (window minimised, covered, on another Space, app hidden).
@MainActor
final class AppVisibility: ObservableObject {
    static let shared = AppVisibility()
    @Published private(set) var isVisible = true
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let visible = NSApp.occlusionState.contains(.visible)
                if self?.isVisible != visible { self?.isVisible = visible }
            }
        }
    }
}

/// A solid dot with a ring that keeps expanding and fading out — "look here".
struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var visibility = AppVisibility.shared

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                // A fresh ring each time it shows, so the animation starts again.
                if !reduceMotion && visibility.isVisible { Ripple(color: color) }
            }
    }

    private struct Ripple: View {
        let color: Color
        @State private var expanded = false

        var body: some View {
            Circle()
                .stroke(color, lineWidth: 1)
                .scaleEffect(expanded ? 2.6 : 1)
                .opacity(expanded ? 0 : 0.8)
                .onAppear {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expanded = true }
                }
        }
    }
}

/// A soft highlight that sweeps across text, for "still working".
private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    @ObservedObject private var visibility = AppVisibility.shared

    func body(content: Content) -> some View {
        if active && visibility.isVisible {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.75), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.3)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    phase = -0.6
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}

/// A folder's branch and its changes: `⑂ wl/fix-tax +31 −9`. A task's own
/// worktree gets a tinted branch icon.
struct GitLine: View {
    let git: GitSnapshot
    let isWorktree: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(isWorktree ? AnyShapeStyle(Color.teal) : AnyShapeStyle(.tertiary))
            Text(git.branch)
                .truncationMode(.middle)
            if git.hasChanges {
                Text("+\(git.added)").foregroundStyle(.green)
                    .layoutPriority(1)
                Text("−\(git.removed)").foregroundStyle(.red.opacity(0.85))
                    .layoutPriority(1)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(help)
    }

    private var help: String {
        let what = isWorktree ? "这个任务自己的 worktree，分支 \(git.branch)" : "分支 \(git.branch)"
        guard git.hasChanges else { return what + "，没有改动" }
        return what + "：\(git.files) 个文件，+\(git.added) −\(git.removed)" + (isWorktree ? "（从分出的地方算起）" : "（未提交）")
    }
}
