import Foundation
import Darwin

/// Thread-safe running totals a UI can poll while a scan is in flight.
public final class ScanProgress: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var files = 0
        public var bytes: Int64 = 0
        public var current = ""
        public var unreadable = 0
    }
    private let lock = NSLock()
    private var s = Snapshot()
    private var cancelled = false

    public init() {}

    func add(files: Int, bytes: Int64, current: String?, unreadable: Int) {
        lock.lock()
        s.files += files
        s.bytes += bytes
        s.unreadable += unreadable
        if let current { s.current = current }
        lock.unlock()
    }

    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return s }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Hard links are counted once.
private final class InodeSet: @unchecked Sendable {
    private struct Key: Hashable { let dev: Int32; let ino: UInt64 }
    private let lock = NSLock()
    private var seen = Set<Key>()
    func firstSighting(dev: Int32, ino: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(Key(dev: dev, ino: ino)).inserted
    }
}

public enum Scanner {
    /// fts walks block, so they run here rather than starving Swift's cooperative thread pool.
    private static let walkQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "timber.scan"
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        q.qualityOfService = .userInitiated
        return q
    }()

    private struct Ctx: @unchecked Sendable {
        let progress: ScanProgress
        let threshold: Int64
        let inodes: InodeSet
        let device: Int32
    }

    /// Walks `url` and returns a size tree. Top-level children are scanned in parallel,
    /// and `onChild` fires as each one finishes (the UI sprouts a tree for it).
    public static func scan(
        _ url: URL,
        progress: ScanProgress = ScanProgress(),
        retainThreshold: Int64 = 1_000_000,
        onChild: (@Sendable (Node) -> Void)? = nil
    ) async -> Node {
        let rootPath = url.standardizedFileURL.path
        var st = stat()
        let device = lstat(rootPath, &st) == 0 ? st.st_dev : 0
        let ctx = Ctx(progress: progress, threshold: retainThreshold, inodes: InodeSet(), device: device)
        let root = Node(path: rootPath, isDirectory: true)
        root.newest = timestamp(st.st_mtimespec)

        guard let kids = listChildren(rootPath) else {
            root.unreadable = true
            progress.add(files: 0, bytes: 0, current: nil, unreadable: 1)
            return root
        }
        await withTaskGroup(of: Node?.self) { group in
            for k in kids {
                group.addTask { await scanItem(k, ctx: ctx, splitDepth: 1) }
            }
            for await child in group {
                guard let child else { continue }
                root.adopt(child, retain: true)
                onChild?(child)
            }
        }
        root.sortChildren()
        return root
    }

    private static func listChildren(_ path: String) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        let base = path == "/" ? "" : path
        return names.map { base + "/" + $0 }
    }

    private static func timestamp(_ t: timespec) -> TimeInterval {
        TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9
    }

    private static func scanItem(_ path: String, ctx: Ctx, splitDepth: Int) async -> Node? {
        if ctx.progress.isCancelled { return nil }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            ctx.progress.add(files: 0, bytes: 0, current: nil, unreadable: 1)
            return nil
        }
        if st.st_dev != ctx.device { return nil } // another volume mounted inside
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        if !isDir {
            let node = Node(path: path, isDirectory: false)
            var bytes = Int64(st.st_blocks) * 512
            if st.st_nlink > 1 && !ctx.inodes.firstSighting(dev: st.st_dev, ino: st.st_ino) { bytes = 0 }
            node.size = bytes
            node.fileCount = 1
            node.newest = timestamp(st.st_mtimespec)
            ctx.progress.add(files: 1, bytes: bytes, current: path, unreadable: 0)
            return node
        }
        if splitDepth > 0 {
            let node = Node(path: path, isDirectory: true)
            node.size = Int64(st.st_blocks) * 512
            guard let kids = listChildren(path) else {
                node.unreadable = true
                ctx.progress.add(files: 0, bytes: 0, current: path, unreadable: 1)
                return node
            }
            await withTaskGroup(of: Node?.self) { group in
                for k in kids { group.addTask { await scanItem(k, ctx: ctx, splitDepth: splitDepth - 1) } }
                for await c in group {
                    guard let c else { continue }
                    node.adopt(c, retain: c.size >= ctx.threshold)
                }
            }
            node.sortChildren()
            return node
        }
        return await withCheckedContinuation { cont in
            walkQueue.addOperation { cont.resume(returning: ftsScan(path, ctx: ctx)) }
        }
    }

    /// Single-threaded depth-first walk with fts(3): far faster than FileManager enumeration.
    private static func ftsScan(_ path: String, ctx: Ctx) -> Node? {
        let root = Node(path: path, isDirectory: true)
        let fts: UnsafeMutablePointer<FTS>? = path.withCString { cPath in
            let dup = strdup(cPath)
            defer { free(dup) }
            var argv: [UnsafeMutablePointer<CChar>?] = [dup, nil]
            return fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }
        guard let fts else { root.unreadable = true; return root }
        defer { fts_close(fts) }

        var stack: [Node] = []
        var files = 0, unreadable = 0
        var bytes: Int64 = 0
        let threshold = ctx.threshold

        func flush(_ current: String?) {
            ctx.progress.add(files: files, bytes: bytes, current: current, unreadable: unreadable)
            files = 0; bytes = 0; unreadable = 0
        }

        while let ent = fts_read(fts) {
            let e = ent.pointee
            let level = Int(e.fts_level)
            switch Int32(e.fts_info) {
            case FTS_D:
                if level == 0 {
                    root.size = Int64(e.fts_statp.pointee.st_blocks) * 512
                    stack.append(root)
                } else {
                    let n = Node(path: String(cString: e.fts_path), isDirectory: true)
                    n.size = Int64(e.fts_statp.pointee.st_blocks) * 512
                    stack.append(n)
                }
            case FTS_DP, FTS_DNR, FTS_ERR:
                guard level == stack.count - 1, let n = stack.popLast() else {
                    unreadable += 1
                    continue
                }
                if Int32(e.fts_info) != FTS_DP { n.unreadable = true; unreadable += 1 }
                n.sortChildren()
                if let p = stack.last {
                    p.adopt(n, retain: n.size >= threshold)
                }
                if ctx.progress.isCancelled { flush(nil); return root }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let p = stack.last else { continue }
                let s = e.fts_statp.pointee
                var b = Int64(s.st_blocks) * 512
                if s.st_nlink > 1 && !ctx.inodes.firstSighting(dev: s.st_dev, ino: s.st_ino) { b = 0 }
                let mtime = timestamp(s.st_mtimespec)
                if b >= threshold {
                    let f = Node(path: String(cString: e.fts_path), isDirectory: false)
                    f.size = b; f.fileCount = 1; f.newest = mtime
                    p.adopt(f, retain: true)
                } else {
                    p.size += b
                    p.fileCount += 1
                    p.hiddenSize += b
                    p.hiddenCount += 1
                    if mtime > p.newest { p.newest = mtime }
                }
                files += 1
                bytes += b
                if files >= 4000 { flush(String(cString: e.fts_path)) }
            case FTS_NS:
                unreadable += 1
            default:
                break
            }
        }
        flush(nil)
        return root
    }
}
