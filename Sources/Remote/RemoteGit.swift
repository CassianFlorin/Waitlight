import Foundation

/// A folder on a server, for handing tasks out there.
struct RemoteFolder: Codable, Hashable {
    var hostID: UUID
    /// As typed: absolute, or starting with `~`.
    var path: String
}

/// Worktrees on a server, over plain ssh: nothing is installed there, only
/// git (and tmux, if it has one) are used. Every call is one ssh round trip
/// running a POSIX sh script whose answer comes back as `@tag value` lines.
enum RemoteGit {
    typealias Failure = Git.Failure

    /// What one look at a server folder finds.
    struct Probe: Equatable {
        /// The server's $HOME, to show paths with `~`.
        var home: String
        /// The folder, resolved.
        var directory: String
        /// The checkout the folder is in; nil outside a git repository.
        var top: String?
        /// The main checkout, even when the folder is a linked worktree.
        var repo: String?
        var branch: String?
        /// The repository's `.worktreeinclude`, when it has one (nil: none,
        /// "": unreadable or too big).
        var include: String?
        var hasTmux = false
        var tmuxSessions: [String] = []

        var isRepository: Bool { repo != nil }
        /// Where a branch's worktree goes: `<repo>.worktrees/<folder>`.
        var container: String? { repo.map { $0 + ".worktrees" } }

        func abbreviating(_ path: String) -> String {
            guard !home.isEmpty, home != "/" else { return path }
            if path == home { return "~" }
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
    }

    /// A path as the server's shell should read it: `~` stays its home.
    static func shellPath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + SSH.quote(String(path.dropFirst(2))) }
        return SSH.quote(path)
    }

    /// Look at a folder on the server: does it exist, is it in a repository,
    /// on which branch, and which tmux sessions are there already.
    static func probe(_ host: RemoteHost, directory: String) async throws -> Probe {
        let script = """
        echo "@home $HOME"
        cd \(shellPath(directory)) 2>/dev/null || { echo "@err 服务器上没有这个文件夹"; exit 3; }
        echo "@dir $(pwd -P)"
        if command -v tmux >/dev/null 2>&1; then echo "@tmux"; tmux ls -F '@t #S' 2>/dev/null; fi
        command -v git >/dev/null 2>&1 || { echo "@nogit"; exit 0; }
        top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
        common=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P) || common=""
        case "$common" in */.git) repo=${common%/.git} ;; *) repo=$top ;; esac
        echo "@top $top"
        echo "@repo $repo"
        echo "@branch $(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)"
        f="$repo/.worktreeinclude"
        if [ -f "$f" ]; then
          if [ "$(wc -c < "$f")" -le \(WorktreeInclude.maxFileSize) ]; then
            echo "@include"; sed 's/^/@i /' "$f"
          else echo "@include"; fi
        fi
        """
        let lines = try await run(host, script)
        var p = Probe(home: "", directory: directory)
        var includeLines: [String]?
        for line in lines {
            if let v = value(line, "@home") { p.home = v }
            else if let v = value(line, "@dir") { p.directory = v }
            else if line == "@tmux" { p.hasTmux = true }
            else if let v = value(line, "@t") { p.tmuxSessions.append(v) }
            else if let v = value(line, "@top") { p.top = v }
            else if let v = value(line, "@repo") { p.repo = v }
            else if let v = value(line, "@branch") { p.branch = v }
            else if line == "@include" { includeLines = [] }
            else if line == "@i" { includeLines?.append("") }
            else if line.hasPrefix("@i ") { includeLines?.append(String(line.dropFirst(3))) }
        }
        p.include = includeLines?.joined(separator: "\n")
        return p
    }

    /// Make a worktree of the repository at `probe` on a new branch from what
    /// that folder has checked out, in `<repo>.worktrees/` next to the main
    /// checkout, the same as on this Mac. Gitignored files listed in its
    /// `.worktreeinclude` (else root `.env*`) are copied in on the server.
    static func addWorktree(_ host: RemoteHost, at probe: Probe, branch wanted: String) async throws
        -> (worktree: WorktreeRef, note: String?) {
        guard let top = probe.top, let repo = probe.repo, let container = probe.container else {
            throw Failure(message: "服务器上的“\((probe.directory as NSString).lastPathComponent)”不在 git 仓库里，没法建 worktree。")
        }
        var skipped: [String] = []
        var paths: [String] = []
        let usesFile = probe.include != nil
        if let text = probe.include {
            let parsed = WorktreeInclude.parse(text)
            paths = parsed.paths
            skipped += parsed.rejected.map { "\($0)（不支持通配或排除）" }
        }
        let limitKB = WorktreeInclude.maxBytes / 1024
        let script = """
        err() { printf '@err %s\\n' "$*" | tr '\\n' ' '; echo; exit 3; }
        cd \(SSH.quote(top)) || err "服务器上没有这个文件夹"
        want=\(SSH.quote(wanted))
        git check-ref-format --branch "$want" >/dev/null 2>&1 || err "“${want}”不能用作分支名。"
        base=$(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)
        container=\(SSH.quote(container))
        n=1; b=$want
        while :; do
          p="$container/$(printf '%s' "${b#wl/}" | tr / -)"
          if ! git show-ref --verify --quiet "refs/heads/$b" && [ ! -e "$p" ]; then break; fi
          n=$((n + 1)); [ "$n" -gt 99 ] && err "分支名 $want 已经用到 99 个了"
          b="$want-$n"
        done
        mkdir -p "$container" || err "没能建文件夹 $container"
        out=$(git worktree add -b "$b" "$p" "$base" 2>&1) || err "$out"
        p=$(cd "$p" && pwd -P)
        echo "@path $p"; echo "@branch $b"; echo "@base $base"
        repo=\(SSH.quote(repo))
        # ${rel}, not $rel, before a full-width character: some sh read it as part of the name.
        copy() {
          rel=$1; src="$repo/$rel"; dst="$p/$rel"
          [ -e "$dst" ] || [ -L "$dst" ] && return
          kb=$(du -skH "$src" 2>/dev/null | cut -f1)
          [ "${kb:-0}" -gt \(limitKB) ] && { echo "@skip ${rel}（超出 2 GiB 的复制上限）"; return; }
          mkdir -p "$(dirname "$dst")" && cp -RH "$src" "$dst" 2>/dev/null && echo "@copied $rel" || echo "@skip ${rel}（复制失败）"
        }
        \(usesFile ? includeLoop(paths) : envLoop)
        """
        let lines = try await run(host, script)
        var path: String?, branch = wanted, base = probe.branch ?? "HEAD"
        var copied = 0
        for line in lines {
            if let v = value(line, "@path") { path = v }
            else if let v = value(line, "@branch") { branch = v }
            else if let v = value(line, "@base") { base = v }
            else if value(line, "@copied") != nil { copied += 1 }
            else if let v = value(line, "@skip") { skipped.append(v) }
        }
        guard let path else { throw Failure(message: "服务器没有说 worktree 建在了哪里") }
        var note: String?
        if copied > 0 || !skipped.isEmpty {
            note = usesFile ? "按 \(WorktreeInclude.fileName) 复制了 \(copied) 项" : "复制了 \(copied) 个 .env 文件"
            if !skipped.isEmpty { note! += "；跳过：" + skipped.joined(separator: "、") }
        }
        return (WorktreeRef(repo: repo, path: path, branch: branch, base: base, hostID: host.id), note)
    }

    /// The `.worktreeinclude` entries: only what exists and git ignores;
    /// tracked files come with the checkout.
    private static func includeLoop(_ paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return """
        for rel in \(paths.map(SSH.quote).joined(separator: " ")); do
          if [ ! -e "$repo/$rel" ]; then echo "@skip ${rel}（不存在）"
          elif git -C "$repo" check-ignore -q -- "$rel"; then copy "$rel"
          else echo "@skip ${rel}（没被 git 忽略）"; fi
        done
        """
    }

    /// Without `.worktreeinclude`: gitignored `.env*` files at the root.
    private static let envLoop = """
    for f in "$repo"/.env*; do
      [ -e "$f" ] || continue
      rel=${f##*/}
      git -C "$repo" check-ignore -q -- "$rel" && copy "$rel"
    done
    true
    """

    /// Branch and what changed in a server worktree, counted from where the
    /// branch left `base`, like `Git.snapshot`. nil when it can't be reached.
    static func snapshot(_ host: RemoteHost, of worktree: WorktreeRef) async -> GitSnapshot? {
        let script = """
        cd \(SSH.quote(worktree.path)) 2>/dev/null || exit 3
        echo "@branch $(git symbolic-ref --short -q HEAD || git rev-parse --short HEAD)"
        from=$(git merge-base \(SSH.quote(worktree.base)) HEAD 2>/dev/null) || from=HEAD
        git diff --numstat --no-renames "$from" | sed 's/^/@n /'
        git ls-files --others --exclude-standard | head -500 | while IFS= read -r f; do
          [ -f "$f" ] && [ "$(wc -c < "$f")" -lt 1000000 ] && grep -Iq . "$f" 2>/dev/null \\
            && echo "@u $(wc -l < "$f")" || echo "@u 0"
        done
        """
        guard let lines = try? await run(host, script, timeout: 20) else { return nil }
        var snap: GitSnapshot?
        for line in lines {
            if let v = value(line, "@branch") { snap = GitSnapshot(branch: v) }
            else if let v = value(line, "@n") {
                let cols = v.split(separator: "\t", maxSplits: 2)
                guard cols.count == 3 else { continue }
                snap?.files += 1
                snap?.added += Int(cols[0]) ?? 0
                snap?.removed += Int(cols[1]) ?? 0
            } else if let v = value(line, "@u") {
                snap?.files += 1
                snap?.added += Int(v.trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return snap
    }

    /// Whether removing the worktree would lose uncommitted changes.
    static func hasUncommittedChanges(_ host: RemoteHost, _ worktree: WorktreeRef) async throws -> Bool {
        let lines = try await run(host, """
        cd \(SSH.quote(worktree.path)) 2>/dev/null || { echo "@gone"; exit 0; }
        git status --porcelain | head -1 | sed 's/^/@c /'
        """)
        return lines.contains { $0.hasPrefix("@c ") }
    }

    /// Remove the worktree's folder on the server; its branch stays. The
    /// task's tmux session goes too: its agent was working in that folder.
    static func removeWorktree(_ host: RemoteHost, _ worktree: WorktreeRef, force: Bool,
                               tmuxSession: String?) async throws {
        let kill = tmuxSession.map {
            "command -v tmux >/dev/null 2>&1 && tmux kill-session -t \(SSH.quote("=" + $0)) 2>/dev/null\n"
        } ?? ""
        _ = try await run(host, """
        \(kill)cd \(SSH.quote(worktree.repo)) 2>/dev/null || { printf '@err %s\\n' "服务器上找不到主仓库"; exit 3; }
        out=$(git worktree remove \(force ? "--force " : "")\(SSH.quote(worktree.path)) 2>&1) || { printf '@err %s\\n' "$out" | tr '\\n' ' '; echo; exit 3; }
        echo "@ok"
        """)
    }

    // MARK: Plumbing

    /// Run a script on the host; its output lines. A script reports its own
    /// failure with an `@err` line; anything else non-zero is ssh's.
    private static func run(_ host: RemoteHost, _ script: String, timeout: TimeInterval = 30) async throws -> [String] {
        // sh, whatever the login shell is (fish would not read these scripts).
        let r = await SSH.run(host, command: "sh -c " + SSH.quote(script), timeout: timeout)
        let lines = r.output.components(separatedBy: .newlines)
        if let e = lines.lazy.compactMap({ value($0, "@err") }).first {
            throw Failure(message: e.trimmingCharacters(in: .whitespaces))
        }
        guard r.ok else {
            let message = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "连不上 \(host.name)：" + (message.isEmpty ? "ssh 失败" : message))
        }
        return lines
    }

    private static func value(_ line: String, _ tag: String) -> String? {
        guard line.hasPrefix(tag + " ") else { return nil }
        return String(line.dropFirst(tag.count + 1))
    }
}
