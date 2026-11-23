import AppKit
import Combine

/// All open sessions, the selection, groups, and what we remember between launches.
@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var selectedID: AgentSession.ID? {
        didSet { selected.map(clearAttention) }
    }
    @Published private(set) var recentDirectories: [String] = []
    /// Group names in display order. Sessions with `group == nil` show first.
    @Published private(set) var groups: [String] = []
    @Published var collapsedGroups: Set<String> = []
    /// Set to show the rename sheet for a session.
    @Published var renaming: AgentSession?

    // MARK: Remote hosts
    @Published private(set) var hosts: [RemoteHost] = []
    /// Aliases from ~/.ssh/config not yet saved as hosts.
    @Published private(set) var sshConfigAliases: [String] = []
    /// ~/.ssh/config aliases the user removed from the sidebar (config file untouched).
    @Published private(set) var hiddenSSHConfigAliases: [String] = []
    /// Git hosting aliases the user chose to list anyway.
    @Published private(set) var shownGitAliases: Set<String> = []
    /// Set to open 管理服务器.
    @Published var managingServers = false
    /// Drives 管理服务器 from the debug hooks: "select:<name>", "test",
    /// "filter:<all|saved|ssh|hidden>", "query:<text>".
    @Published var debugServerCommand: String?
    /// Set to open the host editor (new or existing host).
    @Published var editingHost: RemoteHost?
    /// Set to open the remote-session picker for a host.
    @Published var pickingSessionFor: RemoteHost?
    private let hostStore = HostStore()

    // MARK: Agents
    let catalog = AgentCatalog()
    /// Set to open the "resume a conversation" sheet.
    @Published var resumeRequest: ResumeRequest?
    @Published var managingAgents = false
    /// The Agent 总览 takes the place of the selected session's terminal.
    @Published var showingDashboard = false
    /// ⌘P 跳转或新建, over the whole window.
    @Published var showingQuickOpen = false
    /// What the panel's field starts with (debug hook); emptied once used.
    var quickOpenSeed = ""
    private var hookObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    private var cancellables: [AgentSession.ID: AnyCancellable] = [:]
    /// Install sessions we're waiting on, to re-detect agents when they finish.
    private var installWatchers: [AgentSession.ID: AnyCancellable] = [:]
    private let store = WorkspaceStore()

    var selected: AgentSession? { sessions.first { $0.id == selectedID } }

    /// Sessions in sidebar order: this Mac's (ungrouped, then each group),
    /// then each server's under it.
    var orderedSessions: [AgentSession] {
        var out = sessions(in: nil) + groups.flatMap { sessions(in: $0) }
        for host in sidebarServers { out += sessions(on: host) }
        return out
    }

    /// Listed under 本机: local sessions, and any whose server was deleted.
    private func isListedLocally(_ s: AgentSession) -> Bool {
        guard let ref = s.remote else { return true }
        return !hosts.contains { $0.id == ref.hostID }
    }

    func sessions(on host: RemoteHost) -> [AgentSession] {
        sessions.filter { $0.remote?.hostID == host.id }
    }

    var attentionCount: Int {
        sessions.filter { if case .needsAttention = $0.status { return true } else { return false } }.count
    }

    init() {
        menuObserver = objectWillChange.sink { [weak self] _ in self?.queueMenuRefresh() }
        let saved = store.load()
        recentDirectories = saved.recentDirectories
        groups = saved.groups
        hosts = hostStore.load()
        reloadSSHConfig()
        GhosttyRuntime.shared.onAppEvent = { [weak self] event in
            guard let self else { return }
            if case .newSession = event { self.newSessionLikeCurrent(nil) }
        }
        // Agent hooks (see AgentHook) report from separate processes.
        hookObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentHook.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = AgentHook.parse(note.object) else { return }
            MainActor.assumeIsolated {
                for session in self?.sessions ?? [] {
                    guard let pane = session.pane(withID: event.paneID) else { continue }
                    session.handleHook(event.name, message: event.message, in: pane)
                    break
                }
            }
        }
        // Commits and edits made outside Waitlight show up when you come back.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.forEach { $0.refreshGit() } }
        }
    }

    // MARK: Lifecycle

    /// Re-open what was open last time (fresh processes, same agents, folders and splits).
    func restore() {
        let saved = store.load()
        for s in saved.sessions {
            if let ref = s.remote {
                // Reconnect and re-attach: this is what "restore" means for servers.
                if let host = hosts.first(where: { $0.id == ref.hostID }) {
                    let session = makeRemoteSession(host, sessionName: ref.sessionName, customName: s.customName,
                                                    group: s.group, layout: s.layout)
                    add(session, select: false)
                }
                continue
            }
            let kind = catalog.agent(id: s.kindID) ?? .shell
            // Agents come back *in the same conversation*, each in its own pane.
            // Files from before agents were per pane only know the session's agent.
            let primary = s.layout.flatMap(PaneNode.primaryLeaf(of:))
            let first: AgentLaunch?
            if let id = primary?.agentID {
                first = relaunch(agentID: id, conversationID: primary?.conversationID, hadAgent: primary?.hadAgent)
            } else {
                first = relaunch(agentID: kind.id, conversationID: s.conversationID, hadAgent: s.hadAgent)
            }
            let session = AgentSession(kind: kind, directory: s.directory, customName: s.customName,
                                       group: s.group, layout: s.layout, agent: first,
                                       restoreAgent: { [unowned self] leaf in
                                           leaf.agentID.flatMap {
                                               self.relaunch(agentID: $0, conversationID: leaf.conversationID,
                                                             hadAgent: leaf.hadAgent)
                                           }
                                       },
                                       worktree: s.worktree)
            session.pinned = s.pinned == true
            add(session, select: false)
        }
        // Nothing to restore (first launch, or everything was closed): start in a shell at ~.
        if sessions.isEmpty {
            open(kind: .shell, directory: NSHomeDirectory(), select: false)
        }
        selectedID = orderedSessions.first?.id
        persist()
    }

    /// Open a session. With `resume`, the agent continues that conversation.
    @discardableResult
    func open(kind: AgentKind, directory: String, group: String? = nil, select: Bool = true,
              resume: Conversation? = nil) -> AgentSession {
        let session = AgentSession(kind: kind, directory: directory, group: group,
                                   agent: launch(kind, resume: resume?.id))
        if let resume { session.customName = resume.title }
        add(session, select: select)
        remember(directory)
        persist()
        return session
    }

    private func add(_ session: AgentSession, select: Bool) {
        session.isFrontmost = { [weak self, weak session] in self?.selectedID == session?.id }
        session.onWorkspaceEvent = { [weak self] session, event in self?.handle(event, from: session) }
        session.detectAgent = { [weak self] title in self?.catalog.agent(runBy: title) }
        // Re-publish child changes so sidebar and Dock badge update.
        cancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.sessionDidChange()
        }
        if let g = session.group, !groups.contains(g) { groups.append(g) }
        sessions.append(session)
        if select { self.select(session) }
    }

    /// Sessions opened for a one-off command (container logs / shell from the
    /// 性能 panel). They are not restored on relaunch.
    private var ephemeral: Set<UUID> = []

    /// Open a session that runs `command`, locally or on `host`. With a host
    /// the session counts as that server's, so the 性能 panel stays on it.
    @discardableResult
    func openCommand(_ command: String, title: String, on host: RemoteHost?) -> AgentSession {
        let session: AgentSession
        if let host {
            session = AgentSession(kind: .ssh, directory: NSHomeDirectory(), customName: title,
                                   group: selected?.group,
                                   remote: RemoteRef(hostID: host.id, sessionName: nil),
                                   remoteName: host.name, remoteLabel: host.address,
                                   connectCommand: SSH.commandLine(for: host, remoteCommand: command))
        } else {
            session = AgentSession(kind: .shell, directory: NSHomeDirectory(), customName: title,
                                   group: selected?.group, startCommand: command)
        }
        ephemeral.insert(session.id)
        add(session, select: true)
        return session
    }

    func close(_ session: AgentSession) {
        ephemeral.remove(session.id)
        let order = orderedSessions
        guard let idx = order.firstIndex(where: { $0.id == session.id }) else { return }
        cancellables[session.id] = nil
        session.panes.forEach { $0.removeFromSuperview() }
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id {
            let rest = orderedSessions
            selectedID = rest.isEmpty ? nil : rest[min(idx, rest.count - 1)].id
        }
        persist()
        updateDockBadge()
    }

    // MARK: Agents

    private func withHooks(_ line: String, _ kind: AgentKind) -> String {
        AgentHook.decorate(line, for: kind)
    }

    /// How to start `kind`: in the conversation `resume` if it can go back to
    /// it, else in a new one. nil for a plain shell.
    private func launch(_ kind: AgentKind, resume id: String? = nil) -> AgentLaunch? {
        if let id, let line = kind.resumeLine(id) {
            return AgentLaunch(kind: kind, line: withHooks(line, kind), conversationID: id)
        }
        let (line, newID) = kind.newConversation()
        return line.map { AgentLaunch(kind: kind, line: withHooks($0, kind), conversationID: newID) }
    }

    /// How to bring a saved agent back. `hadAgent` without an id (e.g. Codex
    /// before its first prompt): continue the latest conversation in the folder.
    private func relaunch(agentID: String, conversationID: String?, hadAgent: Bool?) -> AgentLaunch? {
        guard let kind = catalog.agent(id: agentID), kind.isAgent else { return nil }
        if conversationID == nil, hadAgent == true, let line = kind.continueLine() {
            return AgentLaunch(kind: kind, line: withHooks(line, kind), conversationID: nil)
        }
        return launch(kind, resume: conversationID)
    }

    /// Run an agent's install command in a new terminal session, where you can
    /// see the output and answer prompts (sudo, Homebrew…). When the command
    /// finishes, installed agents are detected again so the agent shows up in
    /// the new-session menus.
    func install(_ agent: AgentKind) {
        guard let command = agent.installCommand else { return }
        managingAgents = false
        let session = openCommand(command, title: "安装 \(agent.name)", on: nil)
        installWatchers[session.id] = session.$status.sink { [weak self, id = session.id] status in
            guard case .finished = status else { return }
            DispatchQueue.main.async {
                self?.installWatchers[id] = nil
                #if DEBUG
                DebugHooks.log("install finished: \(status), detecting again")
                #endif
                self?.catalog.detectInstalled()
            }
        }
    }

    /// After an agent exited: start it again in its pane, back in the same
    /// conversation if we know it. Without `pane`: the focused pane's agent if
    /// it exited, else the first exited one.
    func restartAgent(_ session: AgentSession, pane: PaneView? = nil) {
        let exited = session.agentPanes.filter { $0.agent?.activity == .exited }
        guard let pane = pane ?? exited.first(where: { $0 === session.focusedPane }) ?? exited.first,
              let agent = pane.agent, let launch = launch(agent.kind, resume: agent.conversationID) else { return }
        session.run(launch, in: pane)
    }

    /// Start another agent in `session`, in a new pane split off the focused one.
    /// Not in any menu: new agents get a session of their own. Kept for the
    /// debug hook, which uses it to exercise sessions with several agents.
    func addAgent(_ kind: AgentKind, to session: AgentSession) {
        guard session.remote == nil, let launch = launch(kind) else { return }
        session.split(agent: launch)
        persist()
    }

    /// Hand a task to a new agent without going to it: a session of its own,
    /// started with the prompt, opened behind whatever is on screen.
    /// With `worktree`, the task first gets a git worktree on that new branch
    /// (made from what `directory` has checked out) and the agent works there.
    @discardableResult
    func dispatch(_ prompt: String, to kind: AgentKind, in directory: String,
                  worktree branch: String? = nil) async throws -> AgentSession? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, kind.canTakePrompt else { return nil }
        let (line, id) = kind.newConversation(prompt: text)
        guard let line else { return nil }
        var worktree: WorktreeRef?
        var note: String?
        if let branch {
            (worktree, note) = try await Task.detached(priority: .userInitiated) {
                try Git.addWorktree(from: directory, branch: branch)
            }.value
        }
        let launch = AgentLaunch(kind: kind, line: withHooks(line, kind), conversationID: id, startsWorking: true)
        let session = AgentSession(kind: kind, directory: worktree?.path ?? directory, agent: launch,
                                   worktree: worktree)
        // Until the agent titles its own work, the task is the best name for it.
        session.customName = text.count > 40 ? String(text.prefix(40)) + "…" : text
        session.setupNote = note
        add(session, select: false)
        // The folder you picked, not the worktree, is where the next task likely goes.
        remember(directory)
        persist()
        return session
    }

    /// Close a session and remove its worktree folder. The branch and its
    /// commits stay. Asks first when the worktree has uncommitted changes.
    func closeRemovingWorktree(_ session: AgentSession) {
        guard let worktree = session.worktree else { return close(session) }
        Task {
            let dirty = await Task.detached { Git.hasUncommittedChanges(worktree) }.value
            if dirty {
                let alert = NSAlert()
                alert.messageText = "“\(worktree.branch)”还有没提交的改动"
                alert.informativeText = "删除 worktree 会丢掉这些改动。已经提交的内容还在分支 \(worktree.branch) 上。"
                alert.addButton(withTitle: "仍然删除")
                alert.addButton(withTitle: "取消")
                alert.buttons.first?.hasDestructiveAction = true
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            close(session)
            do {
                try await Task.detached { try Git.removeWorktree(worktree, force: dirty) }.value
            } catch {
                let alert = NSAlert()
                alert.messageText = "没能删除 worktree"
                alert.informativeText = "\(worktree.path.abbreviatingHome)\n\n\(error.localizedDescription)"
                alert.runModal()
            }
        }
    }

    func togglePinned(_ session: AgentSession) {
        session.pinned.toggle()
        persist()
    }

    /// Where the agent on screen sits among all agents (sidebar order), for "2/5".
    var agentPosition: (index: Int?, count: Int) {
        let all = agentEntries
        return (all.firstIndex { $0.session.id == selectedID && $0.pane === $0.session.focusedPane }, all.count)
    }

    /// Go to the next / previous agent, across sessions, without the 总览.
    func cycleAgent(_ delta: Int) {
        let all = agentEntries
        guard !all.isEmpty else { return }
        let next: Int
        if let i = agentPosition.index {
            next = (i + delta + all.count) % all.count
        } else if let i = all.firstIndex(where: { $0.session.id == selectedID }) {
            next = i   // on a shell pane of a session with an agent: go to that agent first
        } else {
            next = delta > 0 ? 0 : all.count - 1
        }
        show(all[next].pane, in: all[next].session)
    }

    /// Select the session and bring one of its agents' panes forward.
    func show(_ pane: PaneView, in session: AgentSession) {
        select(session)
        session.focus(pane)
    }

    /// Go to a session, leaving the Agent 总览 if it is up.
    func select(_ session: AgentSession) {
        showingDashboard = false
        selectedID = session.id
    }

    func showResume(directory: String? = nil, agentID: String? = nil) {
        let dir = directory ?? selected.flatMap { $0.remote == nil ? $0.directory : nil }
            ?? recentDirectories.first ?? NSHomeDirectory()
        let agent = agentID ?? selected.flatMap { $0.kind.history != .none ? $0.kind.id : nil }
            ?? catalog.available.first { $0.history != .none }?.id ?? "claude"
        resumeRequest = ResumeRequest(directory: dir, agentID: agent)
    }

    private func newSessionLikeCurrent(_ from: AgentSession?) {
        let src = from ?? selected
        if let ref = src?.remote, let host = hosts.first(where: { $0.id == ref.hostID }) {
            connect(host)   // cmd+t in an SSH session: another session on the same server
            return
        }
        open(kind: src?.kind ?? .shell, directory: src?.directory ?? NSHomeDirectory(), group: src?.group)
    }

    // MARK: Remote

    func reloadSSHConfig() {
        let saved = Set(hosts.map(\.host))
        let hidden = hostStore.hiddenAliases()
        let all = SSHConfigReader.aliases().filter { !saved.contains($0) }
        sshConfigAliases = all.filter { !hidden.contains($0) }
        hiddenSSHConfigAliases = all.filter { hidden.contains($0) }
        shownGitAliases = hostStore.shownAliases()
        resolveSSHDestinations(all + hosts.map(\.host))
    }

    // MARK: Servers in the sidebar

    /// Where each ~/.ssh/config alias goes (`ssh -G`), for addresses and to
    /// tell git hosting apart from machines you log in to.
    @Published private(set) var sshDestinations: [String: SSHDestination] = [:]
    /// Open or folded, per server section. Unset: open while it has sessions.
    @Published var serverOpen: [UUID: Bool] = [:]
    /// Each server's tmux / zellij sessions, looked up when you expand it.
    @Published private(set) var remoteListings: [UUID: RemoteListing] = [:]

    enum RemoteListing: Equatable {
        case loading
        case sessions([String], multiplexer: String?, at: Date)
        case failed(String)
    }

    private func resolveSSHDestinations(_ names: [String]) {
        let unique = Array(Set(names))
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { SSHConfigReader.destinations(unique) }.value
            guard let self, self.sshDestinations != found else { return }
            self.sshDestinations = found
        }
    }

    /// Servers that get a section of their own: pinned ones, and any with
    /// sessions open. In the order you saved them.
    var sidebarServers: [RemoteHost] {
        hosts.filter { host in host.isPinned || sessions.contains { $0.remote?.hostID == host.id } }
    }

    /// One row under 其他服务器.
    enum ServerItem: Identifiable {
        case host(RemoteHost)
        case alias(String)

        var id: String {
            switch self {
            case .host(let h): return "host:" + h.id.uuidString
            case .alias(let a): return "alias:" + a
            }
        }
        var name: String {
            switch self {
            case .host(let h): return h.name
            case .alias(let a): return a
            }
        }
    }

    /// Everything else you can log in to, folded away under 其他服务器.
    var otherServers: [ServerItem] {
        let shown = Set(sidebarServers.map(\.id))
        return hosts.filter { !shown.contains($0.id) && $0.visibility != .hidden }.map(ServerItem.host)
            + sshConfigAliases.filter { !isAutoHidden(alias: $0) }.map(ServerItem.alias)
    }

    /// ~/.ssh/config entries for git (github.com…), left out of the sidebar
    /// unless you chose to show them.
    var gitHostingAliases: [String] {
        sshConfigAliases.filter { isAutoHidden(alias: $0) }
    }

    private func isAutoHidden(alias: String) -> Bool {
        isGitHosting(alias: alias) && !shownGitAliases.contains(alias)
    }

    /// Where an unsaved ~/.ssh/config alias shows: 自动 (under 其他服务器) or
    /// 隐藏 (removed by you, or git hosting you haven't asked to show).
    func visibility(ofAlias alias: String) -> RemoteHost.SidebarVisibility {
        hiddenSSHConfigAliases.contains(alias) || isAutoHidden(alias: alias) ? .hidden : .auto
    }

    func setVisibility(_ visibility: RemoteHost.SidebarVisibility, of host: RemoteHost) {
        var h = host
        h.sidebar = visibility
        saveHost(h)
    }

    /// 固定 saves the alias as a server (returned); 自动 / 隐藏 are only
    /// remembered here. ~/.ssh/config itself is never touched.
    @discardableResult
    func setVisibility(_ visibility: RemoteHost.SidebarVisibility, ofAlias alias: String) -> RemoteHost? {
        if visibility == .pinned { return pin(alias: alias) }
        var hidden = hostStore.hiddenAliases()
        var shown = hostStore.shownAliases()
        if visibility == .hidden {
            hidden.insert(alias)
            shown.remove(alias)
        } else {
            hidden.remove(alias)
            if isGitHosting(alias: alias) { shown.insert(alias) }
        }
        hostStore.saveHiddenAliases(hidden)
        hostStore.saveShownAliases(shown)
        reloadSSHConfig()
        return nil
    }

    func isGitHosting(alias: String) -> Bool {
        (sshDestinations[alias] ?? SSHDestination(hostName: alias)).isGitHosting
    }

    /// The address to show: what the alias resolves to when the server is
    /// just an ~/.ssh/config name.
    func address(of host: RemoteHost) -> String {
        if host.user == nil, host.port == nil, let d = sshDestinations[host.host] { return d.address }
        return host.address
    }

    func address(ofAlias alias: String) -> String {
        sshDestinations[alias]?.address ?? alias
    }

    func setPinned(_ host: RemoteHost, _ pinned: Bool) {
        setVisibility(pinned ? .pinned : .auto, of: host)
    }

    /// Pinning an ~/.ssh/config alias saves it as a server (the config file is untouched).
    @discardableResult
    func pin(alias: String) -> RemoteHost {
        var h = RemoteHost.fromSSHConfig(alias: alias)
        h.sidebar = .pinned
        saveHost(h)
        return h
    }

    /// 测试连接 in 管理服务器: one ssh round trip, timed. A saved server's
    /// session list is kept for the sidebar and ⌘P too.
    func testConnection(_ host: RemoteHost) async -> Result<(info: SSH.ServerInfo, seconds: Double), SSH.ProbeError> {
        let start = Date()
        let result = await SSH.inspect(host)
        let seconds = Date().timeIntervalSince(start)
        if case .success(let info) = result, hosts.contains(where: { $0.id == host.id }) {
            remoteListings[host.id] = .sessions(info.sessions, multiplexer: info.multiplexer(for: host.persistence),
                                                at: Date())
        }
        return result.map { (info: $0, seconds: seconds) }
    }

    /// What the host editor's 保存 does, from wherever it was opened.
    func saveEdited(_ host: RemoteHost, password: String?) {
        if let password { HostKeychain.setPassword(password, for: host.id, label: host.name) }
        saveHost(host)
    }

    /// Look up the server's tmux / zellij sessions (one ssh, no terminal),
    /// unless a recent answer is at hand. A failure is only retried when
    /// asked (`force`), never on its own.
    func loadRemoteSessions(_ host: RemoteHost, force: Bool = false) {
        switch remoteListings[host.id] {
        case .loading: return
        case .sessions(_, _, let at) where !force && Date().timeIntervalSince(at) < 60: return
        case .failed where !force: return
        default: break
        }
        remoteListings[host.id] = .loading
        Task {
            let result = await SSH.inspect(host)
            switch result {
            case .success(let info):
                remoteListings[host.id] = .sessions(info.sessions, multiplexer: info.multiplexer(for: host.persistence),
                                                    at: Date())
            case .failure(let e):
                remoteListings[host.id] = .failed(e.message.isEmpty ? "连接失败" : e.message)
            }
        }
    }

    func saveHost(_ host: RemoteHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        hostStore.save(hosts)
        reloadSSHConfig()
        // Keep labels of open sessions in sync.
        for s in sessions where s.remote?.hostID == host.id {
            s.remoteName = host.name
            s.remoteLabel = label(for: host, sessionName: s.remote?.sessionName)
        }
    }

    func deleteHost(_ host: RemoteHost) {
        hosts.removeAll { $0.id == host.id }
        HostKeychain.deletePassword(for: host.id)
        hostStore.save(hosts)
        reloadSSHConfig()
    }

    func host(for session: AgentSession) -> RemoteHost? {
        session.remote.flatMap { ref in hosts.first { $0.id == ref.hostID } }
    }

    /// Sidebar subtitle: address, plus the tmux/zellij session if it isn't the default.
    private func label(for host: RemoteHost, sessionName: String?) -> String {
        guard let s = sessionName, s != "agentdeck" else { return host.address }
        return "\(host.address) · \(s)"
    }

    /// A tmux/zellij name not used by another open session on this host.
    private func freshSessionName(for host: RemoteHost) -> String {
        let base = SSH.sessionName("agentdeck")
        let used = Set(sessions.compactMap { $0.remote?.hostID == host.id ? $0.remote?.sessionName : nil })
        if !used.contains(base) { return base }
        var n = 2
        while used.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private func makeRemoteSession(_ host: RemoteHost, sessionName: String?, customName: String? = nil,
                                   group: String? = nil, layout: PaneNode.Layout? = nil) -> AgentSession {
        let name = host.persistence.usesSessionName ? (sessionName ?? freshSessionName(for: host)) : nil
        return AgentSession(kind: .ssh, directory: NSHomeDirectory(), customName: customName,
                            group: group ?? host.group, layout: layout,
                            remote: RemoteRef(hostID: host.id, sessionName: name),
                            remoteName: host.name,
                            remoteLabel: label(for: host, sessionName: name),
                            connectCommand: SSH.commandLine(for: host, sessionName: name))
    }

    /// Open a session on a server. `sessionName` attaches to an existing
    /// tmux/zellij session; nil creates a fresh one.
    @discardableResult
    func connect(_ host: RemoteHost, sessionName: String? = nil) -> AgentSession {
        // Already attached to that remote session? Just go there.
        if let sessionName, let open = sessions.first(where: {
            $0.remote?.hostID == host.id && $0.remote?.sessionName == sessionName
        }) {
            select(open)
            if open.isDisconnected { reconnect(open) }
            return open
        }
        let session = makeRemoteSession(host, sessionName: sessionName)
        add(session, select: true)
        persist()
        noteConnected(host)
        return session
    }

    /// For 上次连接 in 管理服务器. Written straight to hosts.json: a full
    /// saveHost would re-read ~/.ssh/config on every connect.
    private func noteConnected(_ host: RemoteHost) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[i].lastConnected = Date()
        hostStore.save(hosts)
    }

    /// Connecting an ~/.ssh/config alias saves it as a server, so the session
    /// can be reconnected and restored later.
    @discardableResult
    func connect(alias: String, sessionName: String? = nil) -> AgentSession {
        let host = hosts.first { $0.host == alias } ?? {
            let h = RemoteHost.fromSSHConfig(alias: alias)
            saveHost(h)
            return h
        }()
        return connect(host, sessionName: sessionName)
    }

    /// Reconnect with the host's *current* settings (they may have been edited).
    func reconnect(_ session: AgentSession) {
        guard let host = host(for: session) else { return }
        session.reconnect(with: SSH.commandLine(for: host, sessionName: session.remote?.sessionName))
        noteConnected(host)
    }

    // MARK: Events bubbled up from sessions

    private func handle(_ event: TerminalEvent, from session: AgentSession) {
        switch event {
        case .newSession: newSessionLikeCurrent(session)
        case .closeSession: close(session)
        case .renameSession: renaming = session
        case .gotoSession(let n): gotoSession(n)
        case .moveSession(let amount): moveWithinGroup(session, by: amount)
        default: break
        }
    }

    /// Ghostty's goto_tab: 1-based index, or -1 prev / -2 next / -3 last.
    func gotoSession(_ n: Int32) {
        let order = orderedSessions
        guard !order.isEmpty else { return }
        let cur = order.firstIndex { $0.id == selectedID } ?? 0
        let target: Int
        switch n {
        case -1: target = (cur - 1 + order.count) % order.count
        case -2: target = (cur + 1) % order.count
        case -3: target = order.count - 1
        default:
            guard n >= 1 else { return }
            target = min(Int(n) - 1, order.count - 1)
        }
        select(order[target])
    }

    func selectNext(_ delta: Int) { gotoSession(delta > 0 ? -2 : -1) }

    /// Jump to the oldest session that is waiting for you.
    func selectNextNeedingAttention() {
        if let s = orderedSessions.first(where: { if case .needsAttention = $0.status { return true }; return false }) {
            select(s)
            // With several agents in the session, land on the one that is waiting.
            if let pane = s.agentPanes.first(where: { if case .waiting = $0.agent?.activity { return true }; return false }) {
                s.focus(pane)
            }
        }
    }

    private func clearAttention(_ s: AgentSession) {
        if case .needsAttention = s.status { s.status = .running }
    }

    // MARK: Rename & groups

    func rename(_ session: AgentSession, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    /// This Mac's sessions in a group (nil: ungrouped). Servers' sessions
    /// are listed under their server instead.
    func sessions(in group: String?) -> [AgentSession] {
        sessions.filter { isListedLocally($0) && $0.group == group }
    }

    func move(_ session: AgentSession, toGroup group: String?) {
        if let group, !groups.contains(group) { groups.append(group) }
        session.group = group
        pruneEmptyGroups()
        persist()
    }

    func renameGroup(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        if groups.contains(name) {
            groups.removeAll { $0 == old }          // merge into existing
        } else if let i = groups.firstIndex(of: old) {
            groups[i] = name
        }
        for s in sessions where s.group == old { s.group = name }
        if collapsedGroups.remove(old) != nil { collapsedGroups.insert(name) }
        persist()
    }

    /// Dissolve a group; its sessions become ungrouped (nothing is closed).
    func ungroup(_ group: String) {
        for s in sessions where s.group == group { s.group = nil }
        groups.removeAll { $0 == group }
        persist()
    }

    private func pruneEmptyGroups() {
        groups.removeAll { g in !sessions.contains { $0.group == g } }
    }

    /// Reorder within one sidebar section (indices are section-relative).
    func move(inGroup group: String?, from: IndexSet, to: Int) {
        var section = sessions(in: group)
        section.move(fromOffsets: from, toOffset: to)
        var it = section.makeIterator()
        sessions = sessions.map { isListedLocally($0) && $0.group == group ? it.next()! : $0 }
        persist()
    }

    private func moveWithinGroup(_ session: AgentSession, by amount: Int) {
        let section = sessions(in: session.group)
        guard let i = section.firstIndex(where: { $0.id == session.id }) else { return }
        let j = min(max(i + amount, 0), section.count - 1)
        guard i != j else { return }
        move(inGroup: session.group, from: IndexSet(integer: i), to: j > i ? j + 1 : j)
    }

    // MARK: Persistence

    private func remember(_ dir: String) {
        recentDirectories.removeAll { $0 == dir }
        recentDirectories.insert(dir, at: 0)
        recentDirectories = Array(recentDirectories.prefix(12))
    }

    func persist() {
        store.save(.init(
            sessions: orderedSessions.filter { !ephemeral.contains($0.id) }.map {
                // Each pane's agent is in the layout. The first pane's is
                // repeated here for versions that only knew one agent per session.
                let first = $0.panes.first { $0.isPrimary }?.agent
                return .init(kindID: $0.kind.id, directory: $0.directory, customName: $0.customName,
                             group: $0.group, layout: $0.root.layout, remote: $0.remote,
                             conversationID: first?.conversationID,
                             hadAgent: first != nil ? true : nil,
                             pinned: $0.pinned ? true : nil,
                             worktree: $0.worktree)
            },
            recentDirectories: recentDirectories,
            groups: groups))
    }

    // MARK: Menu bar

    /// The little the menu bar shows. Published only when a value actually
    /// changes, so the menus aren't rebuilt for every session update.
    final class MenuState: ObservableObject {
        @Published fileprivate(set) var hasSession = false
        @Published fileprivate(set) var showingDashboard = false
        @Published fileprivate(set) var selectedDisconnected = false
    }

    let menuState = MenuState()
    private var menuRefreshQueued = false
    private var menuObserver: AnyCancellable?

    /// objectWillChange fires before the change; read the new values after it.
    private func queueMenuRefresh() {
        guard !menuRefreshQueued else { return }
        menuRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuRefreshQueued = false
            let m = self.menuState
            let hasSession = self.selected != nil && !self.showingDashboard
            let disconnected = self.selected?.isDisconnected == true
            if m.hasSession != hasSession { m.hasSession = hasSession }
            if m.showingDashboard != self.showingDashboard { m.showingDashboard = self.showingDashboard }
            if m.selectedDisconnected != disconnected { m.selectedDisconnected = disconnected }
        }
    }

    /// A session changed and the workspace hasn't re-published it yet.
    private var sessionChangePending = false

    /// Everything that watches the workspace (sidebar, Agent 总览, toolbar,
    /// Dock badge, saving) hears about session changes at most every 0.1 s.
    /// Busy agents change state and title many times a second; re-rendering
    /// the whole window for each one is most of what an idle Waitlight costs.
    /// Views that show one session observe it directly and stay immediate.
    private func sessionDidChange() {
        guard !sessionChangePending else { return }
        sessionChangePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.sessionChangePending = false
            self.objectWillChange.send()
            self.updateDockBadge()
            self.schedulePersist()
        }
    }

    private var persistWork: DispatchWorkItem?

    /// Coalesce bursts of changes (typing `cd` a lot, dragging a divider).
    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func updateDockBadge() {
        let n = attentionCount
        let label = n > 0 ? "\(n)" : nil
        // Each assignment is a round trip to the Dock, even with the same value.
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }
}

/// ~/Library/Application Support/Waitlight/workspace.json
final class WorkspaceStore {
    struct Saved: Codable {
        struct Session: Codable {
            var kindID: String
            var directory: String
            var customName: String?
            var group: String?
            var layout: PaneNode.Layout?
            var remote: RemoteRef?
            /// The first pane's agent, as older versions expect it. Every
            /// pane's agent, this one included, is in `layout`.
            var conversationID: String?
            var hadAgent: Bool?
            var pinned: Bool?
            /// The task's worktree, if it was handed out with one.
            var worktree: WorktreeRef?
        }
        var sessions: [Session] = []
        var recentDirectories: [String] = []
        var groups: [String] = []

        init(sessions: [Session] = [], recentDirectories: [String] = [], groups: [String] = []) {
            self.sessions = sessions
            self.recentDirectories = recentDirectories
            self.groups = groups
        }

        // Tolerate files written by older versions (missing keys).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
            recentDirectories = try c.decodeIfPresent([String].self, forKey: .recentDirectories) ?? []
            groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        }
    }

    private var url: URL {
        AppPaths.support.appendingPathComponent("workspace.json")
    }

    func load() -> Saved {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return saved
    }

    /// What the last save wrote, so an unchanged workspace isn't rewritten.
    private var lastSaved: Data?

    func save(_ saved: Saved) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(saved), data != lastSaved else { return }
        if (try? data.write(to: url, options: .atomic)) != nil { lastSaved = data }
    }
}

/// What the "resume a conversation" sheet should show first.
struct ResumeRequest: Identifiable, Equatable {
    let id = UUID()
    var directory: String
    var agentID: String
}
