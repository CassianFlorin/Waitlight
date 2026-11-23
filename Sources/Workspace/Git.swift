import Foundation

/// A task's own checkout: a git worktree on a branch of its own, so agents
/// working in parallel never touch each other's files or your main checkout.
struct WorktreeRef: Codable, Equatable {
    /// The main checkout the worktree belongs to.
    var repo: String
    /// The worktree's folder.
    var path: String
    var branch: String
    /// What the branch started from; changes are counted against it.
    var base: String
}

/// A folder's branch and what changed in it, at a glance.
struct GitSnapshot: Equatable {
    var branch: String
    var files = 0
    var added = 0
    var removed = 0

    var hasChanges: Bool { files > 0 }
}

/// The few git commands Waitlight runs. All of them block: call off the main thread.
enum Git {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A git that won't pop up the Command Line Tools installer when it is
    /// missing: /usr/bin/git is only a shim that asks to install them.
    static let executable: String? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            return path
        }
        let developerGits = ["/Library/Developer/CommandLineTools/usr/bin/git",
                             "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return developerGits.contains(where: fm.isExecutableFile(atPath:)) ? "/usr/bin/git" : nil
    }()

    /// Run git in `dir`; its output, trimmed, if it succeeded.
    @discardableResult
    static func run(_ args: [String], in dir: String) throws -> String {
        guard let exe = executable else {
            throw Failure(message: "找不到 git。装上 Xcode 命令行工具（xcode-select --install）或 Homebrew 的 git 后再试。")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-C", dir] + args
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Looking must never take index.lock from under an agent that is committing.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "git \(args.first ?? "") 失败（\(p.terminationStatus)）" : message)
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The top of the checkout `dir` is in, or nil outside a repository.
    static func checkoutRoot(of dir: String) -> String? {
        try? run(["rev-parse", "--show-toplevel"], in: dir)
    }

    /// The branch checked out in `dir`; a short commit id when detached.
    static func branch(in dir: String) -> String? {
        guard let name = try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir) else { return nil }
        if name != "HEAD" { return name }
        return try? run(["rev-parse", "--short", "HEAD"], in: dir)
    }

    /// The main checkout of the repository `dir` is in, even when `dir` is
    /// itself a linked worktree, so new worktrees sit next to the real repo.
    static func mainCheckout(of dir: String) -> String? {
        guard let top = checkoutRoot(of: dir) else { return nil }
        guard let common = try? run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir),
              (common as NSString).lastPathComponent == ".git" else { return top }
        return (common as NSString).deletingLastPathComponent
    }

    /// Branch, files changed, lines added and removed in `dir`. With `base`,
    /// counted from where the branch left it, so the agent's commits count
    /// too; else against HEAD. New files count in full.
    static func snapshot(of dir: String, base: String?) -> GitSnapshot? {
        guard let branch = branch(in: dir) else { return nil }
        var snap = GitSnapshot(branch: branch)
        var from = "HEAD"
        if let base, let fork = try? run(["merge-base", base, "HEAD"], in: dir), !fork.isEmpty { from = fork }
        if let numstat = try? run(["diff", "--numstat", "--no-renames", from], in: dir) {
            for line in numstat.split(separator: "\n") {
                let cols = line.split(separator: "\t", maxSplits: 2)
                guard cols.count == 3 else { continue }
                snap.files += 1
                snap.added += Int(cols[0]) ?? 0     // "-" for binary files
                snap.removed += Int(cols[1]) ?? 0
            }
        }
        if let untracked = try? run(["ls-files", "--others", "--exclude-standard"], in: dir) {
            let top = checkoutRoot(of: dir) ?? dir
            for path in untracked.split(separator: "\n").prefix(500) {
                snap.files += 1
                snap.added += lineCount(of: (top as NSString).appendingPathComponent(String(path)))
            }
        }
        return snap
    }

    private static func lineCount(of path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.size] as? Int ?? 0) < 1_000_000,
              let data = FileManager.default.contents(atPath: path),
              !data.contains(0) else { return 0 }   // binary
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return data.last == 0x0A || data.isEmpty ? newlines : newlines + 1
    }

    // MARK: Worktrees

    /// A branch name for a task: its Latin words, else the time.
    static func branchName(for task: String, now: Date = Date()) -> String {
        var words: [String] = []
        var word = ""
        for scalar in task.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        var slug = ""
        for w in words {
            let next = slug.isEmpty ? w : slug + "-" + w
            if next.count > 32 { break }
            slug = next
        }
        if slug.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "MMdd-HHmm"
            slug = "task-" + f.string(from: now)
        }
        return "wl/" + slug
    }

    /// The worktree folder for a branch: `wl/fix-tax` → `fix-tax`.
    static func folderName(for branch: String) -> String {
        (branch.hasPrefix("wl/") ? String(branch.dropFirst(3)) : branch).replacingOccurrences(of: "/", with: "-")
    }

    /// Whether `name` can be a branch.
    static func isValidBranchName(_ name: String, in dir: String) -> Bool {
        (try? run(["check-ref-format", "--branch", name], in: dir)) != nil
    }

    /// Make a worktree of the repository `dir` is in, on a new branch from
    /// what `dir` has checked out. It goes in `<repo>.worktrees/` next to the
    /// main checkout. If the branch or folder is taken, a number is added.
    /// Gitignored files the agent will likely need (`.env`…) are copied in
    /// from the main checkout, see `WorktreeInclude`; the note says what was.
    static func addWorktree(from dir: String, branch wanted: String) throws -> (worktree: WorktreeRef, note: String?) {
        guard let top = checkoutRoot(of: dir), let repo = mainCheckout(of: dir) else {
            throw Failure(message: "“\((dir as NSString).lastPathComponent)”不在 git 仓库里，没法建 worktree。")
        }
        guard isValidBranchName(wanted, in: top) else {
            throw Failure(message: "“\(wanted)”不能用作分支名。")
        }
        let base = branch(in: top) ?? "HEAD"
        let container = repo + ".worktrees"
        let fm = FileManager.default

        var branch = wanted
        var path = ""
        for n in 1...99 {
            branch = n == 1 ? wanted : "\(wanted)-\(n)"
            path = (container as NSString).appendingPathComponent(folderName(for: branch))
            let taken = (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: top)) != nil
            if !taken && !fm.fileExists(atPath: path) { break }
        }
        try fm.createDirectory(atPath: container, withIntermediateDirectories: true)
        try run(["worktree", "add", "-b", branch, path, base], in: top)

        let note = WorktreeInclude.apply(from: repo, to: path)
        return (WorktreeRef(repo: repo, path: path, branch: branch, base: base), note)
    }

    /// Whether the worktree has changes that removing it would lose.
    static func hasUncommittedChanges(_ worktree: WorktreeRef) -> Bool {
        guard let status = try? run(["status", "--porcelain"], in: worktree.path) else { return false }
        return !status.isEmpty
    }

    /// Remove the worktree's folder. Its branch stays, with every commit on it.
    static func removeWorktree(_ worktree: WorktreeRef, force: Bool) throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktree.path)
        try run(args, in: worktree.repo)
    }
}
