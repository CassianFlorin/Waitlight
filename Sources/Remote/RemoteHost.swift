import Foundation

/// A server you connect to over SSH (ECS, VPS, anything with sshd).
/// Secrets are never stored here — passwords live in the Keychain.
struct RemoteHost: Codable, Identifiable, Hashable {
    enum Auth: String, Codable, CaseIterable, Identifiable {
        /// Whatever ssh would do on its own: agent, default keys, ~/.ssh/config.
        case auto
        /// A specific private key file.
        case key
        /// Password, kept in the Keychain and fed to ssh via SSH_ASKPASS.
        case password
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "自动（ssh-agent / 默认密钥 / ssh config）"
            case .key: return "指定私钥"
            case .password: return "密码"
            }
        }
    }

    /// How the remote side survives disconnects.
    enum Persistence: String, Codable, CaseIterable, Identifiable {
        /// Use tmux or zellij if the server happens to have one, otherwise a
        /// plain login shell. Never requires installing anything.
        case auto
        case none, tmux, zellij
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "自动（有 tmux / zellij 就用，没有就普通 shell）"
            case .none: return "不保持（普通 shell，断开即结束）"
            case .tmux: return "tmux（服务器需已安装）"
            case .zellij: return "zellij（服务器需已安装）"
            }
        }
        var shortLabel: String {
            switch self {
            case .auto: return "自动"
            case .none: return "不保持"
            case .tmux: return "tmux"
            case .zellij: return "zellij"
            }
        }
        /// Whether sessions get a name we can re-attach to.
        var usesSessionName: Bool { self != .none }
    }

    var id = UUID()
    var name: String
    /// Hostname, IP, or an alias from ~/.ssh/config.
    var host: String
    var port: Int?
    var user: String?
    var auth: Auth = .auto
    var identityFile: String?
    /// ProxyJump, e.g. "bastion" or "user@jump:22".
    var jumpHost: String?
    /// Free-form label shown as a tag: "ECS", "VPS", "Lightsail"…
    var provider: String?
    var group: String?
    /// cd here after login (or when creating the tmux/zellij session).
    var remoteDirectory: String?
    var persistence: Persistence = .auto
    /// TERM sent to the server. Most servers don't have xterm-ghostty's terminfo.
    var term: String = "xterm-256color"
    /// Extra raw ssh arguments, e.g. "-o StrictHostKeyChecking=accept-new".
    var extraArguments: String?
    /// Whether the sidebar always shows it (pinned), only while it has
    /// sessions (auto), or never unless it has sessions open (hidden: found
    /// with ⌘P and in 管理服务器). nil: from before this existed, see `isPinned`.
    var sidebar: SidebarVisibility?
    /// When a session last connected to it. nil: never, or before this existed.
    var lastConnected: Date?

    enum SidebarVisibility: String, Codable, CaseIterable {
        case pinned, auto, hidden
        var label: String {
            switch self {
            case .pinned: return "固定"
            case .auto: return "自动"
            case .hidden: return "隐藏"
            }
        }
    }

    /// Servers you added yourself stay in the sidebar; ones saved because
    /// you connected an ~/.ssh/config alias show while they have sessions.
    var isPinned: Bool {
        sidebar.map { $0 == .pinned } ?? (name != host)
    }

    var visibility: SidebarVisibility { sidebar ?? (isPinned ? .pinned : .auto) }

    init(id: UUID = UUID(), name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }

    /// A blank server for the editor: added by hand, so it stays in the sidebar.
    static func new() -> RemoteHost {
        var h = RemoteHost(name: "", host: "")
        h.sidebar = .pinned
        return h
    }

    /// Tolerant decoding: a hosts.json written by an older (or newer) version
    /// must never lose the whole server list over one missing key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decode(String.self, forKey: .host)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? host
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        auth = (try? c.decodeIfPresent(Auth.self, forKey: .auth)) ?? .auto
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        jumpHost = try c.decodeIfPresent(String.self, forKey: .jumpHost)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        remoteDirectory = try c.decodeIfPresent(String.self, forKey: .remoteDirectory)
        persistence = (try? c.decodeIfPresent(Persistence.self, forKey: .persistence)) ?? .auto
        term = try c.decodeIfPresent(String.self, forKey: .term) ?? "xterm-256color"
        extraArguments = try c.decodeIfPresent(String.self, forKey: .extraArguments)
        sidebar = try? c.decodeIfPresent(SidebarVisibility.self, forKey: .sidebar)
        lastConnected = try? c.decodeIfPresent(Date.self, forKey: .lastConnected)
    }

    /// "user@host:port" for display.
    var address: String {
        var s = host
        if let user, !user.isEmpty { s = "\(user)@\(s)" }
        if let port, port != 22 { s += ":\(port)" }
        return s
    }

    var symbol: String {
        switch (provider ?? "").lowercased() {
        case "ecs", "aliyun", "阿里云", "tencent", "腾讯云", "aws", "ec2", "lightsail", "gcp", "azure":
            return "cloud"
        default:
            return "server.rack"
        }
    }

    /// A blank host pre-filled from an ~/.ssh/config alias.
    static func fromSSHConfig(alias: String) -> RemoteHost {
        var h = RemoteHost(name: alias, host: alias)
        h.sidebar = .auto
        return h
    }
}

/// Which remote session a local Waitlight session is attached to.
struct RemoteRef: Codable, Hashable {
    var hostID: UUID
    /// tmux / zellij session name on the server (nil when persistence is .none).
    /// With .auto it is only used if the server turns out to have a multiplexer.
    var sessionName: String?
    /// Where on the server the session works, when not the host's folder: a
    /// task handed out there (its worktree, or the folder it was given).
    var directory: String?
}

/// ~/Library/Application Support/Waitlight/hosts.json
struct HostStore {
    private var url: URL {
        AppPaths.support.appendingPathComponent("hosts.json")
    }

    func load() -> [RemoteHost] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RemoteHost].self, from: data)) ?? []
    }

    func save(_ hosts: [RemoteHost]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(hosts) { try? data.write(to: url, options: .atomic) }
    }

    /// ~/.ssh/config aliases removed from the sidebar: hidden-ssh-aliases.json.
    /// ~/.ssh/config itself is read-only to Waitlight.
    private var hiddenURL: URL {
        AppPaths.support.appendingPathComponent("hidden-ssh-aliases.json")
    }

    func hiddenAliases() -> Set<String> {
        guard let data = try? Data(contentsOf: hiddenURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    func saveHiddenAliases(_ aliases: Set<String>) {
        write(aliases, to: hiddenURL)
    }

    /// Git hosting aliases (github.com…) you chose to show anyway: shown-ssh-aliases.json.
    private var shownURL: URL {
        AppPaths.support.appendingPathComponent("shown-ssh-aliases.json")
    }

    func shownAliases() -> Set<String> {
        guard let data = try? Data(contentsOf: shownURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    func saveShownAliases(_ aliases: Set<String>) {
        write(aliases, to: shownURL)
    }

    private func write(_ aliases: Set<String>, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(aliases.sorted()) { try? data.write(to: url, options: .atomic) }
    }
}

/// Where an ~/.ssh/config alias really goes, as `ssh -G` resolves it.
struct SSHDestination: Equatable {
    var hostName: String
    var user: String?
    var port: Int?

    /// github.com, GitLab, Bitbucket and the like: in ~/.ssh/config for git,
    /// not for logging in, so the sidebar leaves them out.
    var isGitHosting: Bool {
        if user == "git" { return true }
        let h = hostName.lowercased()
        return ["github.com", "gitlab.com", "bitbucket.org", "gitee.com", "codeberg.org",
                "ssh.dev.azure.com", "vs-ssh.visualstudio.com", "git.sr.ht"]
            .contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// "user@host:port" without the parts ssh would use anyway.
    var address: String {
        var s = hostName
        if let user, user != NSUserName() { s = "\(user)@\(s)" }
        if let port, port != 22 { s += ":\(port)" }
        return s
    }
}

/// Reads Host aliases out of ~/.ssh/config (following Include), so hosts you
/// already configured show up without retyping anything.
enum SSHConfigReader {
    /// Resolve aliases with `ssh -G` (OpenSSH's own reading of the config,
    /// Match blocks and all). Blocking; a few ms per alias. No connection is made.
    static func destinations(_ aliases: [String]) -> [String: SSHDestination] {
        var out: [String: SSHDestination] = [:]
        for alias in aliases {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-G", alias]
            p.standardInput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { continue }
            var dest = SSHDestination(hostName: alias)
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let kv = line.split(separator: " ", maxSplits: 1)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "hostname": dest.hostName = String(kv[1])
                case "user": dest.user = String(kv[1])
                case "port": dest.port = Int(kv[1])
                default: break
                }
            }
            out[alias] = dest
        }
        return out
    }

    static func aliases() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var seen = Set<String>()
        var out: [String] = []
        var visited = Set<String>()
        read(home.appendingPathComponent(".ssh/config"), into: &out, seen: &seen, visited: &visited)
        return out
    }

    private static func read(_ file: URL, into out: inout [String], seen: inout Set<String>, visited: inout Set<String>) {
        let path = file.standardizedFileURL.path
        guard !visited.contains(path), let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        visited.insert(path)
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "host" {
                for name in value.split(separator: " ").map(String.init) {
                    // Skip patterns and negations; they aren't connectable names.
                    guard !name.contains("*"), !name.contains("?"), !name.hasPrefix("!") else { continue }
                    if seen.insert(name).inserted { out.append(name) }
                }
            } else if key == "include" {
                for pattern in value.split(separator: " ").map(String.init) {
                    let expanded = (pattern as NSString).expandingTildeInPath
                    let full = expanded.hasPrefix("/") ? expanded : sshDir.appendingPathComponent(expanded).path
                    for f in glob(full) { read(URL(fileURLWithPath: f), into: &out, seen: &seen, visited: &visited) }
                }
            }
        }
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }
}
