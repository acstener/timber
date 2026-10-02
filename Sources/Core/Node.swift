import Foundation

/// One file or folder in a scanned tree. Only children above the scanner's retain
/// threshold are kept; everything smaller is folded into `hiddenSize`/`hiddenCount`.
public final class Node: Identifiable, Hashable, @unchecked Sendable {
    public let path: String
    public let isDirectory: Bool
    public internal(set) var size: Int64 = 0
    public internal(set) var fileCount: Int = 0
    /// Newest modification time anywhere in the subtree (seconds since 1970, 0 = unknown).
    public internal(set) var newest: TimeInterval = 0
    public internal(set) var children: [Node] = []
    public internal(set) var hiddenSize: Int64 = 0
    public internal(set) var hiddenCount: Int = 0
    public internal(set) var unreadable = false
    public internal(set) weak var parent: Node?

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }
    public static func == (a: Node, b: Node) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
    public var name: String {
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }
    public var displayName: String {
        if path == NSHomeDirectory() { return "Home" }
        if path == "/System/Volumes/Data" { return "Macintosh HD" }
        return name
    }
    public var newestDate: Date? { newest > 0 ? Date(timeIntervalSince1970: newest) : nil }
    public var pathExtension: String { (name as NSString).pathExtension.lowercased() }

    /// Number of retained + folded children.
    public var itemCount: Int { children.count + hiddenCount }

    public var depthFromRoot: Int {
        var d = 0; var p = parent
        while let n = p { d += 1; p = n.parent }
        return d
    }

    public var ancestors: [Node] {
        var out: [Node] = []; var p = parent
        while let n = p { out.insert(n, at: 0); p = n.parent }
        return out
    }

    public func find(path target: String) -> Node? {
        if path == target { return self }
        guard target.hasPrefix(path == "/" ? "/" : path + "/") else { return nil }
        for c in children { if let hit = c.find(path: target) { return hit } }
        return nil
    }

    // MARK: building

    func adopt(_ child: Node, retain: Bool) {
        size += child.size
        fileCount += child.fileCount
        if child.newest > newest { newest = child.newest }
        if child.unreadable && !retain { unreadable = true }
        if retain {
            child.parent = self
            children.append(child)
        } else {
            hiddenSize += child.size
            hiddenCount += 1
        }
    }

    func sortChildren() {
        children.sort { $0.size > $1.size }
    }

    // MARK: chopping

    /// Removes this node from its parent, subtracting its size up the chain.
    public func detach() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        var a: Node? = p
        while let n = a {
            n.size -= size
            n.fileCount -= fileCount
            a = n.parent
        }
        parent = nil
    }

    /// Puts a previously detached node back (used by undo).
    public func reattach(to p: Node) {
        parent = p
        let idx = p.children.firstIndex { $0.size < size } ?? p.children.count
        p.children.insert(self, at: idx)
        var a: Node? = p
        while let n = a {
            n.size += size
            n.fileCount += fileCount
            a = n.parent
        }
    }
}

public enum Kind: String, Sendable {
    case folder, app, bundle, video, audio, image, archive, installer, diskImage, document, code, file

    public var label: String {
        switch self {
        case .folder: return "Folder"
        case .app: return "App"
        case .bundle: return "Package"
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Image"
        case .archive: return "Archive"
        case .installer: return "Installer"
        case .diskImage: return "Disk image"
        case .document: return "Document"
        case .code: return "Code"
        case .file: return "File"
        }
    }

    public var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .app: return "app.badge.fill"
        case .bundle: return "shippingbox.fill"
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .image: return "photo.fill"
        case .archive: return "doc.zipper"
        case .installer: return "opticaldiscdrive.fill"
        case .diskImage: return "externaldrive.fill"
        case .document: return "doc.text.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .file: return "doc.fill"
        }
    }
}

extension Node {
    public var kind: Kind {
        let ext = pathExtension
        if isDirectory {
            switch ext {
            case "app": return .app
            case "photoslibrary", "musiclibrary", "tvlibrary", "xcarchive", "bundle", "framework", "fcpbundle", "logicx", "band", "imovielibrary": return .bundle
            case "sparsebundle", "utm", "pvm", "vmwarevm": return .diskImage
            default: return .folder
            }
        }
        switch ext {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm", "braw", "r3d", "mxf", "prores": return .video
        case "mp3", "wav", "aif", "aiff", "flac", "m4a", "caf", "ogg": return .audio
        case "jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "webp": return .image
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst": return .archive
        case "dmg", "pkg", "iso", "xip", "ipsw", "mpkg": return .installer
        case "vmdk", "qcow2", "vdi", "img", "raw-disk", "sparseimage", "vhd", "vhdx": return .diskImage
        case "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "epub": return .document
        case "swift", "js", "ts", "py", "rs", "go", "c", "h", "m", "json", "db", "sqlite", "sqlite3": return .code
        default: return .file
        }
    }
}
