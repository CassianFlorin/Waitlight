import SwiftUI

/// 管理服务器: every server Waitlight knows (saved ones and ~/.ssh/config
/// aliases) in one table, with where each shows in the sidebar, and a
/// detail pane to test the connection and open or attach a session.
struct ServerManagerView: View {
    @EnvironmentObject private var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var selection: String?
    /// Host editor opened from here (a sheet on this sheet).
    @State private var editing: RemoteHost?
    @State private var probes: [String: Probe] = [:]

    enum Filter: Hashable, CaseIterable {
        case all, saved, sshConfig, hidden
        var label: String {
            switch self {
            case .all: return "全部"
            case .saved: return "已保存"
            case .sshConfig: return "ssh config"
            case .hidden: return "已隐藏"
            }
        }
    }

    enum Probe {
        case running
        case ok(SSH.ServerInfo, seconds: Double, multiplexer: String?)
        case failed(String)
    }

    /// One server in the table.
    struct Row: Identifiable {
        let item: Workspace.ServerItem
        let name: String
        let address: String
        let visibility: RemoteHost.SidebarVisibility
        let persistence: String
        let lastConnected: Date?
        let openSessions: Int
        let isGitHosting: Bool

        var id: String { item.id }
        var host: RemoteHost? { if case .host(let h) = item { return h } else { return nil } }
        var alias: String? { if case .alias(let a) = item { return a } else { return nil } }
        var isSaved: Bool { host != nil }
        var symbol: String { host?.symbol ?? "server.rack" }
    }

    // MARK: Rows

    private var allRows: [Row] {
        let hostRows = workspace.hosts.map { h in
            Row(item: .host(h), name: h.name, address: workspace.address(of: h), visibility: h.visibility,
                persistence: h.persistence.shortLabel, lastConnected: h.lastConnected,
                openSessions: workspace.sessions(on: h).count, isGitHosting: false)
        }
        let aliasRows = (workspace.sshConfigAliases + workspace.hiddenSSHConfigAliases).map { a in
            Row(item: .alias(a), name: a, address: workspace.address(ofAlias: a),
                visibility: workspace.visibility(ofAlias: a), persistence: "自动", lastConnected: nil,
                openSessions: 0, isGitHosting: workspace.isGitHosting(alias: a))
        }
        return hostRows + aliasRows
    }

    private func matches(_ row: Row, _ filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .saved: return row.isSaved
        case .sshConfig: return !row.isSaved
        case .hidden: return row.visibility == .hidden
        }
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return allRows.filter { row in
            matches(row, filter)
                && (q.isEmpty || row.name.lowercased().contains(q) || row.address.lowercased().contains(q)
                    || (row.host?.host.lowercased().contains(q) ?? false))
        }
    }

    private var selectedRow: Row? {
        selection.flatMap { id in allRows.first { $0.id == id } }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    table
                    Text(legend)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                Divider()
                detail
                    .frame(width: 300)
            }
        }
        .frame(width: 1080, height: 640)
        .sheet(item: $editing) { host in
            HostEditor(host: host, isNew: !workspace.hosts.contains { $0.id == host.id }) { saved, password in
                workspace.saveEdited(saved, password: password)
                selection = "host:" + saved.id.uuidString
            }
        }
        .onAppear {
            if selection == nil { selection = rows.first?.id }
            runDebugCommand()
        }
        .onChange(of: workspace.debugServerCommand) { runDebugCommand() }
    }

    private var header: some View {
        let all = allRows
        return HStack(spacing: 10) {
            Text("管理服务器").font(.headline)
            TextField("搜索", text: $query, prompt: Text("名称、地址、用户"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Picker("来源", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Text("\(f.label) \(all.filter { matches($0, f) }.count)").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button("重新读取 ssh config") { workspace.reloadSSHConfig() }
                .help("重新读取 ~/.ssh/config（只读，不会修改它）")
            Button("添加服务器…") { editing = RemoteHost.new() }
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("名称") { row in
                HStack(spacing: 6) {
                    Image(systemName: row.symbol).foregroundStyle(.secondary).frame(width: 16)
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("地址") { row in
                Text(row.address)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.address)
            }
            .width(min: 90, ideal: 140)
            TableColumn("来源") { row in
                Text(row.isSaved ? "已保存" : "ssh config")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            }
            .width(74)
            TableColumn("侧边栏") { row in
                Picker("侧边栏", selection: visibilityBinding(row)) {
                    ForEach(RemoteHost.SidebarVisibility.allCases, id: \.self) { v in
                        Text(v.label).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .width(130)
            TableColumn("保持") { row in
                Text(row.persistence).foregroundStyle(.secondary)
            }
            .width(48)
            TableColumn("上次连接") { row in
                Text(lastLabel(row)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = allRows.first(where: { $0.id == id }) {
                rowMenu(row)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = allRows.first(where: { $0.id == id }) { newSession(row) }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: Row) -> some View {
        Button("新会话") { newSession(row) }
        Button("测试连接") { test(row) }
        Divider()
        if let host = row.host {
            Button("编辑…") { editing = host }
            Button("删除…", role: .destructive) { confirmDelete(host) }
        } else if let alias = row.alias {
            Button("保存为服务器…") { editing = .fromSSHConfig(alias: alias) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: row.symbol)
                    Text(row.name).font(.headline).lineLimit(1)
                }
                field("地址") {
                    Text(fullAddress(row)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(sourceLine(row)).font(.caption).foregroundStyle(.secondary)
                }
                if row.isGitHosting {
                    Text("这是 git 托管地址，ssh 只用来推拉代码，一般登录不上 shell，所以默认隐藏。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 12) {
                    field("会话保持") {
                        if let host = row.host {
                            Picker("会话保持", selection: persistenceBinding(host)) {
                                ForEach(RemoteHost.Persistence.allCases) { p in Text(p.shortLabel).tag(p) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        } else {
                            Text("自动").help("保存为服务器后可以改")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    field("登录后目录") {
                        Text(row.host?.remoteDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                probeView(row)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let host = row.host {
                        Button("编辑…") { editing = host }
                    } else if let alias = row.alias {
                        Button("保存为服务器…") { editing = .fromSSHConfig(alias: alias) }
                    }
                    Button("测试连接") { test(row) }
                        .disabled(isRunning(row))
                    Spacer()
                    Button("新会话") { newSession(row) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("选一台服务器查看详情")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func probeView(_ row: Row) -> some View {
        switch probes[row.id] {
        case nil:
            Text("点“测试连接”看服务器能不能连上、装了什么，以及上面已有的会话。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在连接…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连不上").foregroundStyle(.red)
                    Text(message).font(.caption).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.35)))
        case .ok(let info, let seconds, let mux):
            VStack(alignment: .leading, spacing: 4) {
                Text("连接正常 · \(String(format: "%.1f", seconds)) 秒").foregroundStyle(.green)
                Text(summary(info)).font(.caption).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.green.opacity(0.35)))
            sessionsList(row, info: info, multiplexer: mux)
        }
    }

    @ViewBuilder
    private func sessionsList(_ row: Row, info: SSH.ServerInfo, multiplexer: String?) -> some View {
        if let mux = multiplexer {
            field("服务器上的 \(mux) 会话") {
                if info.sessions.isEmpty {
                    Text("还没有").foregroundStyle(.secondary)
                } else {
                    let attached = Set(row.host.map { h in
                        workspace.sessions(on: h).compactMap { $0.remote?.sessionName }
                    } ?? [])
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(info.sessions, id: \.self) { name in
                                HStack {
                                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                                    Text(name).lineLimit(1)
                                    Spacer()
                                    Button(attached.contains(name) ? "切过去" : "附加") { attach(row, name) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if row.host?.persistence != RemoteHost.Persistence.none {
            Text("服务器上没有 tmux / zellij，新会话是普通 shell，断开后不能恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func visibilityBinding(_ row: Row) -> Binding<RemoteHost.SidebarVisibility> {
        Binding(get: { row.visibility }, set: { v in
            guard v != row.visibility else { return }
            switch row.item {
            case .host(let h):
                workspace.setVisibility(v, of: h)
            case .alias(let a):
                // 固定 saves it as a server: the row (and its id) changes.
                if let saved = workspace.setVisibility(v, ofAlias: a) {
                    let newID = "host:" + saved.id.uuidString
                    if let p = probes.removeValue(forKey: row.id) { probes[newID] = p }
                    if selection == row.id { selection = newID }
                }
            }
        })
    }

    private func persistenceBinding(_ host: RemoteHost) -> Binding<RemoteHost.Persistence> {
        Binding(get: { workspace.hosts.first { $0.id == host.id }?.persistence ?? host.persistence },
                set: { p in
            guard var h = workspace.hosts.first(where: { $0.id == host.id }) else { return }
            h.persistence = p
            workspace.saveHost(h)
            probes["host:" + h.id.uuidString] = nil   // which sessions apply changed
        })
    }

    private func isRunning(_ row: Row) -> Bool {
        if case .running? = probes[row.id] { return true }
        return false
    }

    /// The host to probe: the saved one, or an unsaved stand-in for an alias.
    private func probeHost(_ row: Row) -> RemoteHost {
        row.host ?? .fromSSHConfig(alias: row.alias ?? row.name)
    }

    func test(_ row: Row) {
        guard !isRunning(row) else { return }
        let id = row.id
        let host = probeHost(row)
        probes[id] = .running
        Task {
            switch await workspace.testConnection(host) {
            case .success(let r):
                probes[id] = .ok(r.info, seconds: r.seconds, multiplexer: r.info.multiplexer(for: host.persistence))
            case .failure(let e):
                probes[id] = .failed(e.message.isEmpty ? "连接失败" : e.message)
            }
        }
    }

    private func newSession(_ row: Row) {
        dismiss()
        switch row.item {
        case .host(let h): workspace.connect(h)
        case .alias(let a): workspace.connect(alias: a)
        }
    }

    private func attach(_ row: Row, _ name: String) {
        dismiss()
        switch row.item {
        case .host(let h): workspace.connect(h, sessionName: name)
        case .alias(let a): workspace.connect(alias: a, sessionName: name)
        }
    }

    private func confirmDelete(_ host: RemoteHost) {
        let alert = NSAlert()
        alert.messageText = "删除服务器“\(host.name)”？"
        alert.informativeText = "只删除 Waitlight 里的配置和钥匙串里保存的密码，不会影响服务器，也不会关闭已打开的会话。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            workspace.deleteHost(host)
            if selection == "host:" + host.id.uuidString { selection = nil }
        }
    }

    private func runDebugCommand() {
        guard let cmd = workspace.debugServerCommand else { return }
        workspace.debugServerCommand = nil
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "select": selection = allRows.first { $0.name == arg }?.id
        case "test": if let row = selectedRow { test(row) }
        case "query": query = arg
        case "filter":
            filter = ["saved": .saved, "ssh": .sshConfig, "hidden": .hidden][arg] ?? .all
        default: break
        }
    }

    // MARK: Text

    private var legend: String {
        "固定：一直显示在侧边栏。自动：有打开的会话时显示，否则收进“其他服务器”。隐藏：只在 ⌘P 和这里能找到（有打开的会话时仍会显示）。"
            + "User 是 git、或地址是 github / gitlab / bitbucket 等的条目默认隐藏。~/.ssh/config 本身永远不会被修改。"
    }

    private func lastLabel(_ row: Row) -> String {
        if row.isGitHosting && row.visibility == .hidden { return "git 托管 · 默认隐藏" }
        var parts: [String] = []
        if let d = row.lastConnected { parts.append(Self.relative(d)) } else { parts.append("从未") }
        if row.openSessions > 0 { parts.append("\(row.openSessions) 个会话") }
        return parts.joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "刚刚" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func fullAddress(_ row: Row) -> String {
        if let h = row.host, h.user != nil || h.port != nil { return h.address }
        let name = row.host?.host ?? row.alias ?? row.name
        guard let d = workspace.sshDestinations[name] else { return row.address }
        return "\(d.user ?? NSUserName())@\(d.hostName):\(d.port ?? 22)"
    }

    private func sourceLine(_ row: Row) -> String {
        if let alias = row.alias { return "来自 ~/.ssh/config 的 Host \(alias)" }
        return "已保存在 Waitlight"
    }

    private func summary(_ info: SSH.ServerInfo) -> String {
        var bits = [info.system.isEmpty ? "未知系统" : info.system]
        bits.append(info.hasTmux ? (info.tmuxVersion ?? "tmux") : "tmux 未装")
        bits.append(info.hasZellij ? (info.zellijVersion ?? "zellij") : "zellij 未装")
        return bits.joined(separator: " · ")
    }
}
