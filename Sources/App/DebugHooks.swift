#if DEBUG
import AppKit
import SwiftUI

/// Debug-only remote control, so UI can be exercised without synthetic
/// keystrokes (which land in whatever app is frontmost). Post a distributed
/// notification named "WaitlightDebug" (or "WaitlightDebug.test" for an
/// instance started with WAITLIGHT_HOME, see AppPaths) whose object is a command string:
///
///   binding:<ghostty action>   e.g. binding:new_split:right, binding:scroll_to_top
///   paste:<text>               bracketed-paste text into the focused pane
///   type:<text>                type text as keystrokes into the focused pane (\n = Return)
///   pastefrom:<pasteboard>     paste from a named pasteboard (files → paths, image → saved PNG path)
///   find:<text>                open the find bar with this text
///   session:<n>                select session n (1-based, sidebar order)
///   hosts                      log saved hosts and their ssh command lines
///   connect:<host name or ssh config alias> / reconnect
///   screen                     log the focused pane's visible text (no screenshot needed)
///   history:<agentID>:<dir>    log the newest conversations found for that agent and folder
///   agents                     log the agent catalog and install detection
///   install:<agentID>          run that agent's install command, as 管理 Agent's 安装 button does
///   ui:agents | ui:resume[:<agentID>:<dir>] | ui:close   open/close the agent manager / resume sheet
///   restart                    restart an exited agent in the selected session (resume if known)
///   agent:<agentID>            start that agent in a new split of the selected session
///   dashboard[:show|hide]      toggle the Agent 总览, and log its rows
///   reply:<n>:<text>           answer the n-th agent (sidebar order) as the dashboard's reply field does
///   open:<n>                   open the n-th agent as the dashboard does
///   dispatch:<agentID>:<dir>:<prompt>   hand a task to a new agent, as the dashboard's field does
///   wtdispatch:<agentID>:<dir>:<prompt> the same, in a new worktree with the branch named after the task
///   git                        log each session's worktree, branch and change counts
///   rmworktree:<n>             close session n (sidebar order) and remove its worktree
///   sidebar                    log the sidebar's servers and each session's one-line shell info
///   serveropen:<host name>     open / fold that server's sidebar section
///   others:1|0|reset           open / fold 其他服务器 (reset forgets the setting)
///   qo:<query>                 open 跳转或新建 with that query (qo: closes it)
///   qokey:down|up|tab|return|esc   a key press into that panel's field
///   pin:<n> | stop:<n> | press:<n>:<keys>   pin / interrupt / press keys in the n-th agent
///   cycle:<±1>                 next / previous agent
///   hook:<agentID>:install|uninstall   the status hook file of Grok / Codex
///   monitor:show|hide|<kinds>  open/close the 性能 panel, or set its monitors (e.g. cpu,sessions)
///   monitor                    log the 性能 panel's latest readings (monitor:script dumps the server script)
///   dump                       write sessions/split trees to ~/Library/Caches/Waitlight/debug.log
///
/// From a shell:
///   swift -e 'import Foundation; DistributedNotificationCenter.default()
///     .postNotificationName(.init("WaitlightDebug"), object: "find:login",
///     userInfo: nil, deliverImmediately: true)'
@MainActor
enum DebugHooks {
    private static var token: NSObjectProtocol?

    static func install(_ workspace: Workspace) {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(
            forName: .init(AppPaths.debugChannel), object: nil, queue: .main
        ) { [weak workspace] note in
            guard let cmd = note.object as? String else { return }
            MainActor.assumeIsolated { workspace.map { run(cmd, in: $0) } }
        }
    }

    /// Appends to ~/Library/Caches/Waitlight/debug.log
    static func log(_ msg: String) {
        let url = AppPaths.cache.appendingPathComponent("debug.log")
        let line = Data((msg + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    private static func run(_ cmd: String, in workspace: Workspace) {
        let (verb, arg) = cmd.firstIndex(of: ":").map {
            (String(cmd[..<$0]), String(cmd[cmd.index(after: $0)...]))
        } ?? (cmd, "")
        let pane = workspace.selected?.focusedPane
        switch verb {
        case "binding": pane?.terminal.performBindingAction(arg)
        case "paste": pane?.terminal.insertPasteText(arg.replacingOccurrences(of: "\\n", with: "\r"))
        case "type":
            pane?.terminal.typeText(arg.replacingOccurrences(of: "\\n", with: "\r"))
            // A real Return key reports a submit (TerminalSurfaceView.keyDown); typed text doesn't.
            if arg.contains("\\n"), let pane { pane.onEvent?(pane, .userSubmitted) }
        case "pastefrom":
            // Same conversion as ⌘V, but from a named pasteboard so tests
            // don't clobber the user's clipboard.
            if let text = PasteboardText.read(NSPasteboard(name: .init(arg))) { pane?.terminal.insertPasteText(text) }
        case "dump":
            for (i, sess) in workspace.orderedSessions.enumerated() {
                log("\(i + 1) \(sess.displayName) kind=\(sess.kind.id) activity=\(sess.activity) "
                    + "panes=\(sess.panes.count) zoom=\(sess.zoomedPane != nil) tree=\(sess.root.signature)")
                for p in sess.panes {
                    let a = p.agent
                    log("   pane \(p.terminal.paneID) primary=\(p.isPrimary) focused=\(p === sess.focusedPane) "
                        + "agent=\(a?.kind.id ?? "-") activity=\(a.map { "\($0.activity)" } ?? "-") "
                        + "conv=\(a?.conversationID ?? "-") adopted=\(a?.adopted ?? false)")
                }
            }
        case "history":
            // history:<agentID>:<directory>
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let agent = workspace.catalog.agent(id: parts[0]) else { break }
            let items = ConversationHistory.list(for: agent, directory: parts[1], limit: 5)
            log("history \(agent.id) \(parts[1]): \(items.count) shown")
            for c in items { log("  \(c.updated) \(c.id) \(c.title)") }
        case "install":
            // install:<agentID>  run its install command as the 安装 button does
            if let a = workspace.catalog.agent(id: arg) { workspace.install(a) }
        case "agents":
            for a in workspace.catalog.agents {
                log("agent \(a.id) installed=\(String(describing: workspace.catalog.isInstalled(a))) path=\(workspace.catalog.path(of: a) ?? "-")")
            }
        case "ui":
            // ui:agents | ui:terminal-settings | ui:resume[:<agentID>:<dir>]
            let parts = arg.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.first == "agents" { workspace.managingAgents = true }
            if parts.first == "terminal-settings" {
                // The Settings scene can't be opened from here; host the page directly.
                let w = NSWindow(contentViewController: NSHostingController(rootView: TerminalSettingsView()))
                w.title = "终端设置 (debug)"
                w.makeKeyAndOrderFront(nil)
            }
            if parts.first == "close" { workspace.managingAgents = false; workspace.resumeRequest = nil }
            if parts.first == "resume" {
                workspace.showResume(directory: parts.count > 2 ? parts[2] : nil, agentID: parts.count > 1 ? parts[1] : nil)
            }
        case "monitor":
            let d = UserDefaults.standard
            switch arg {
            case "show": d.set(true, forKey: MonitorSettings.visibleKey)
            case "hide": d.set(false, forKey: MonitorSettings.visibleKey)
            case "script":
                log(MonitorScript.build(kinds: Set(MonitorKind.allCases), interval: 1, system: true))
            case "":
                let m = PerformanceMonitor.shared, r = m.readings
                log("monitor running=\(m.isRunning) kinds=\(d.string(forKey: MonitorSettings.kindsKey) ?? "-")")
                if let c = r.cpu { log("  cpu \(Fmt.percent(c.total)) user=\(Fmt.percent(c.user)) sys=\(Fmt.percent(c.system)) cores=\(c.perCore.count)") }
                if let m = r.memory { log("  mem \(Fmt.bytes(m.used))/\(Fmt.bytes(m.total)) \(m.extras.map { "\($0.label)=\(Fmt.bytes($0.bytes))" }.joined(separator: " ")) swap=\(Fmt.bytes(m.swapUsed)) p=\(m.pressure)") }
                if let g = r.gpu { log("  gpu \(Fmt.percent(g.utilization)) mem=\(g.memoryInUse.map(Fmt.bytes) ?? "-")") }
                if let n = r.network { log("  net in=\(Fmt.rate(n.a)) out=\(Fmt.rate(n.b))") }
                if let k = r.disk { log("  disk r=\(k.rate.map { Fmt.rate($0.a) } ?? "-") w=\(k.rate.map { Fmt.rate($0.b) } ?? "-") free=\(k.free.map(Fmt.bytes) ?? "-")") }
                log("  target=\(m.target.host?.name ?? "local") error=\(m.remoteError ?? "-")")
                if let p = r.processes { log("  procs " + p.map { "\($0.name)=\(Fmt.cpu($0.cpu))" }.joined(separator: " ")) }
                if let k = r.docker {
                    log("  docker installed=\(k.installed) error=\(k.error ?? "-") \(k.runningCount)/\(k.containers.count)")
                    for c in k.containers { log("    \(c.name) \(c.state) cpu=\(c.cpu.map(Fmt.cpu) ?? "-") mem=\(c.memory ?? "-")") }
                }
                if let s = r.sessions {
                    log("  procs=\(s.totalProcesses) cpu=\(Fmt.cpu(s.totalCPU)) mem=\(Fmt.bytes(s.totalMemory)) app=\(Fmt.cpu(s.appCPU))/\(Fmt.bytes(s.appMemory))")
                    for row in s.rows { log("    \(row.name) \(Fmt.cpu(row.cpu)) \(Fmt.bytes(row.memory)) n=\(row.processes)") }
                }
                log("  history " + m.history.map { "\($0.key)=\($0.value.values.count)" }.sorted().joined(separator: " "))
            default: d.set(arg, forKey: MonitorSettings.kindsKey)
            }
        case "dockerlogs":
            // dockerlogs:<container> — same as 查看日志 in the 性能 panel's Docker card.
            let host = workspace.selected.flatMap(workspace.host(for:))
            workspace.openCommand(DockerControl.logsCommand(arg), title: "日志 · \(arg)", on: host)
        case "restart":
            workspace.selected.map { workspace.restartAgent($0) }
        case "dashboard":
            workspace.showingDashboard = arg.isEmpty ? !workspace.showingDashboard : arg == "show"
            log("dashboard showing=\(workspace.showingDashboard)")
            for (i, e) in workspace.agentEntries.enumerated() {
                log("   \(i + 1) [\(e.state.title)] \(e.title) agent=\(e.agent.kind.id) dir=\(e.directory)")
            }
        case "reply":
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let entries = workspace.agentEntries
            if parts.count == 2, let n = Int(parts[0]), entries.indices.contains(n - 1) {
                entries[n - 1].session.send(parts[1], to: entries[n - 1].pane)
            }
        case "open":
            let entries = workspace.agentEntries
            if let n = Int(arg), entries.indices.contains(n - 1) { workspace.show(entries[n - 1].pane, in: entries[n - 1].session) }
        case "dispatch":
            let parts = arg.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let kind = workspace.catalog.agent(id: parts[0]) {
                Task {
                    let s = try? await workspace.dispatch(parts[2], to: kind, in: parts[1])
                    log("dispatch \(s == nil ? "refused" : "ok") canTakePrompt=\(kind.canTakePrompt)")
                }
            }
        case "wtdispatch":
            let parts = arg.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let kind = workspace.catalog.agent(id: parts[0]) {
                Task {
                    do {
                        let s = try await workspace.dispatch(parts[2], to: kind, in: parts[1],
                                                             worktree: Git.branchName(for: parts[2]))
                        log("wtdispatch ok dir=\(s?.directory ?? "-") worktree=\(String(describing: s?.worktree)) note=\(s?.setupNote ?? "-")")
                    } catch {
                        log("wtdispatch failed: \(error.localizedDescription)")
                    }
                }
            }
        case "serveropen":
            if let host = workspace.hosts.first(where: { $0.name == arg }) {
                workspace.serverOpen[host.id] = !(workspace.serverOpen[host.id] ?? !workspace.sessions(on: host).isEmpty)
            }
        case "qo":
            // Open 跳转或新建 with this query (empty arg: close it).
            if arg.isEmpty { workspace.showingQuickOpen = false } else {
                workspace.quickOpenSeed = arg
                workspace.showingQuickOpen = true
            }
        case "qokey":
            // A real key press into the panel's field: down, up, tab, return, esc.
            let codes: [String: (UInt16, String)] = ["down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
                                                     "tab": (48, "\t"), "return": (36, "\r"), "esc": (53, "\u{1b}")]
            if let (code, chars) = codes[arg], let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                window.sendEvent(event)
                log("qokey \(arg) responder=\(String(describing: window.firstResponder.map { type(of: $0) }))")
            }
        case "others":
            // The 其他服务器 section's open state (an @AppStorage key).
            if arg == "reset" { UserDefaults.standard.removeObject(forKey: "sidebar.othersExpanded") }
            else { UserDefaults.standard.set(arg == "1", forKey: "sidebar.othersExpanded") }
        case "sidebar":
            log("servers: \(workspace.sidebarServers.map(\.name))")
            log("others: \(workspace.otherServers.map(\.name)) git: \(workspace.gitHostingAliases)")
            log("listings: \(workspace.remoteListings.map { "\($0.key): \($0.value)" }) open: \(workspace.serverOpen)")
            for (i, s) in workspace.orderedSessions.enumerated() {
                log("   \(i + 1) \(s.remote == nil ? "local" : "remote") name=\(s.shellName) cmd=\(s.shellCommand?.text ?? "-") status=\(s.status)")
            }
        case "git":
            for (i, s) in workspace.orderedSessions.enumerated() {
                log("   \(i + 1) \(s.displayName) dir=\(s.directory) git=\(String(describing: s.git)) worktree=\(String(describing: s.worktree))")
            }
        case "rmworktree":
            let order = workspace.orderedSessions
            if let n = Int(arg), order.indices.contains(n - 1) { workspace.closeRemovingWorktree(order[n - 1]) }
        case "pin", "stop", "press":
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let entries = workspace.agentEntries
            guard let n = parts.first.flatMap({ Int($0) }), entries.indices.contains(n - 1) else { break }
            let e = entries[n - 1]
            if verb == "pin" { workspace.togglePinned(e.session) }
            if verb == "stop" { e.session.interrupt(e.pane) }
            if verb == "press", parts.count == 2 { e.session.press(parts[1], in: e.pane) }
        case "cycle":
            workspace.cycleAgent(Int(arg) ?? 1)
            let pos = workspace.agentPosition
            log("cycle -> \(pos.index.map { String($0 + 1) } ?? "-")/\(pos.count) session=\(workspace.selected?.displayName ?? "-")")
        case "hook":
            let parts = arg.split(separator: ":").map(String.init)
            if parts.count == 2, let kind = workspace.catalog.agent(id: parts[0]), let dropIn = AgentHook.dropIn(for: kind) {
                if parts[1] == "install" { dropIn.install() } else { dropIn.uninstall() }
                log("hook \(kind.id) installed=\(dropIn.isInstalled) file=\(dropIn.file.path)")
                log("  launch: \(AgentHook.decorate(kind.newConversation().line ?? "", for: kind))")
            }
        case "agent":
            if let s = workspace.selected, let kind = workspace.catalog.agent(id: arg) { workspace.addAgent(kind, to: s) }
        case "hosts":
            for h in workspace.hosts { log("host \(h.name) | \(SSH.commandLine(for: h, sessionName: "agentdeck"))") }
            log("aliases \(workspace.sshConfigAliases.count)")
        case "connect":
            if let h = workspace.hosts.first(where: { $0.name == arg }) { workspace.connect(h) }
            else if workspace.sshConfigAliases.contains(arg) { workspace.connect(alias: arg) }
        case "edithost":
            workspace.editingHost = workspace.hosts.first(where: { $0.name == arg }) ?? RemoteHost.new()
        case "inspect":
            // Same path as the editor's 测试连接 button.
            if let h = workspace.hosts.first(where: { $0.name == arg }) {
                Task {
                    switch await SSH.inspect(h) {
                    case .success(let i):
                        log("inspect ok sys=\(i.system) tmux=\(i.hasTmux) zellij=\(i.hasZellij) sessions=\(i.sessions)")
                    case .failure(let e):
                        log("inspect failed: \(e.message)")
                    }
                }
            }
        case "screen":
            // Works even when the Mac is locked and screenshots fail.
            log("--- screen (\(workspace.selected?.displayName ?? "-")) ---\n" + (pane?.terminal.visibleText() ?? "") + "\n--- end ---")
        case "reconnect":
            workspace.selected.map(workspace.reconnect)
        case "find": pane?.showSearch(needle: arg)
        case "session": workspace.gotoSession(Int32(arg) ?? 1)
        default: NSLog("WaitlightDebug: unknown command %@", cmd)
        }
    }
}
#endif
