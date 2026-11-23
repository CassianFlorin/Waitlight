import Foundation

/// Gitignored files a new worktree needs but a checkout doesn't bring:
/// `.env`, local editor settings and the like. They are copied from the
/// main checkout into the new worktree.
///
/// Which ones: the repository's `.worktreeinclude`, read the way Orca reads
/// it (https://orca.dev/docs/model/orca-yaml), so one file serves both apps.
/// One literal path per line, from the repository root; blank lines and `#`
/// lines are ignored; globs (`*`, `?`) and negation (`!`) are skipped; only
/// entries that exist and are gitignored are copied, an existing destination
/// is left alone, and copying is capped at 2 GiB and 50,000 entries.
/// Without the file: untracked `.env*` files at the root.
enum WorktreeInclude {
    static let fileName = ".worktreeinclude"
    static let maxFileSize = 256 * 1024
    static let maxCandidates = 1000
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maxEntries = 50_000

    /// Copy what the new worktree should get from `repo` into `worktree`.
    /// Returns a line on what happened (nil when there was nothing to do).
    static func apply(from repo: String, to worktree: String) -> String? {
        let fm = FileManager.default
        let file = (repo as NSString).appendingPathComponent(fileName)
        let candidates: [String]
        var skipped: [String] = []
        let usesFile = fm.fileExists(atPath: file)
        if usesFile {
            guard let attrs = try? fm.attributesOfItem(atPath: file),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? Int ?? 0) <= maxFileSize,
                  let text = try? String(contentsOfFile: file, encoding: .utf8) else {
                return "\(fileName) 不是普通文件或超过 256 KiB，没有复制任何东西"
            }
            let parsed = parse(text)
            candidates = parsed.paths
            skipped += parsed.rejected.map { "\($0)（不支持通配或排除）" }
        } else {
            candidates = ((try? fm.contentsOfDirectory(atPath: repo)) ?? [])
                .filter { $0.hasPrefix(".env") }
                .sorted()
        }
        guard !candidates.isEmpty else { return skipped.isEmpty ? nil : summary(copied: 0, skipped: skipped, usesFile: usesFile) }

        // Only what exists and git ignores; tracked files come with the checkout.
        let existing = candidates.filter { fm.fileExists(atPath: (repo as NSString).appendingPathComponent($0)) }
        if usesFile { skipped += candidates.filter { !existing.contains($0) }.map { "\($0)（不存在）" } }
        let ignored = ignoredPaths(existing, in: repo)
        if usesFile { skipped += existing.filter { !ignored.contains($0) }.map { "\($0)（没被 git 忽略）" } }

        var bytesLeft = maxBytes, entriesLeft = maxEntries, copied = 0
        for path in existing where ignored.contains(path) {
            let dst = (worktree as NSString).appendingPathComponent(path)
            if fm.fileExists(atPath: dst) { continue }
            // A top-level symlink brings its target's contents.
            let src = URL(fileURLWithPath: (repo as NSString).appendingPathComponent(path)).resolvingSymlinksInPath().path
            let size = measure(src)
            guard size.entries <= entriesLeft, size.bytes <= bytesLeft else {
                skipped.append("\(path)（超出 2 GiB / 5 万个文件的复制上限）")
                continue
            }
            do {
                try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                // On APFS this is a clone: instant, and no extra space until edited.
                try fm.copyItem(atPath: src, toPath: dst)
                bytesLeft -= size.bytes
                entriesLeft -= size.entries
                copied += 1
            } catch {
                skipped.append("\(path)（\(error.localizedDescription)）")
            }
        }
        if copied == 0 && skipped.isEmpty { return nil }
        return summary(copied: copied, skipped: skipped, usesFile: usesFile)
    }

    private static func summary(copied: Int, skipped: [String], usesFile: Bool) -> String {
        var line = usesFile ? "按 \(fileName) 复制了 \(copied) 项" : "复制了 \(copied) 个 .env 文件"
        if !skipped.isEmpty { line += "；跳过：" + skipped.joined(separator: "、") }
        return line
    }

    /// The literal paths in a `.worktreeinclude`, normalized and deduplicated,
    /// and the lines skipped for being globs or negations.
    static func parse(_ text: String) -> (paths: [String], rejected: [String]) {
        var paths: [String] = [], rejected: [String] = [], seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("!") || line.contains("*") || line.contains("?") {
                rejected.append(line)
                continue
            }
            var path = line.replacingOccurrences(of: "\\", with: "/")
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/") { path.removeLast() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            // Stay inside the repository, and out of .git.
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" }),
                  seen.insert(path).inserted else { continue }
            paths.append(path)
            if paths.count == maxCandidates { break }
        }
        return (paths, rejected)
    }

    /// Which of `paths` git ignores in `repo`. Tracked paths never count.
    private static func ignoredPaths(_ paths: [String], in repo: String) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        // Exits 1 when none is ignored, which `run` reports as a failure.
        guard let out = try? Git.run(["check-ignore", "--"] + paths, in: repo) else { return [] }
        return Set(out.split(separator: "\n").map {
            var p = String($0)
            while p.hasSuffix("/") { p.removeLast() }
            return p
        })
    }

    /// Bytes and filesystem entries under `path`, counted before copying.
    /// Stops early once over a limit: past that it is refused anyway.
    private static func measure(_ path: String) -> (bytes: Int64, entries: Int) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return (0, 0) }
        guard isDir.boolValue else {
            let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            return (size, 1)
        }
        var bytes: Int64 = 0, entries = 1
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let walker = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            entries += 1
            if let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                bytes += Int64(v.fileSize ?? 0)
            }
            if entries > maxEntries || bytes > maxBytes { break }
        }
        return (bytes, entries)
    }
}
