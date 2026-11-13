import CryptoKit
import Darwin
import Foundation

/// Bounded reads and filesystem identity checks shared by discovery and mutations.
public enum FS {
    public static let maxConfigBytes = 4 * 1024 * 1024
    public static func join(_ parts: String...) -> String { join(parts) }
    public static func join(_ parts: [String]) -> String {
        guard let first = parts.first else { return "/" }
        return parts.dropFirst().reduce(first) { ($0 as NSString).appendingPathComponent($1) }
    }
    public static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
    public static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    public static func id(_ parts: String...) -> String { id(parts) }
    public static func id(_ parts: [String]) -> String { String(hash((try? JSONEncoder().encode(parts)) ?? Data()).prefix(32)) }
    public static func friendly(_ path: String, home: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    /// Lexical normalization only. NSString.standardizingPath conditionally rewrites
    /// existing /private paths, which makes an existing file disagree with its glob.
    public static func normalized(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : join(FileManager.default.currentDirectoryPath, path)
        var components: [Substring] = []
        for component in absolute.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }
    public static func expand(_ path: String, home: String, base: String? = nil) -> String {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? join(home, String(path.dropFirst(2))) : path
        return normalized(expanded.hasPrefix("/") ? expanded : join(base ?? home, expanded))
    }
    public static func realPath(_ path: String) throws -> String {
        guard let value = Darwin.realpath(path, nil) else { throw fileError("Resolve", path) }
        defer { free(value) }; return String(cString: value)
    }
    public static func exists(_ path: String) -> Bool { var s = stat(); return lstat(path, &s) == 0 }
    public static func isDirectory(_ path: String) -> Bool {
        var s = stat(); return fstatat(AT_FDCWD, path, &s, 0) == 0 && (s.st_mode & S_IFMT) == S_IFDIR
    }
    public static func isSymlink(_ path: String) -> Bool {
        var s = stat(); return lstat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFLNK
    }
    public static func children(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path).sorted()
    }
    public static func canonical(_ path: String) throws -> (parent: String, path: String) {
        let parent = try realPath(parent(path)); return (parent, join(parent, name(path)))
    }
    public static func readData(_ path: String, maxBytes: Int = maxConfigBytes) throws -> Data {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw fileError("Read", path) }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG, s.st_size >= 0, s.st_size <= maxBytes else {
            throw ManagerError("Not a regular file, or the file exceeds the safe read limit")
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, min(buffer.count, maxBytes + 1 - data.count))
            if n < 0 { if errno == EINTR { continue }; throw fileError("Read", path) }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            guard data.count <= maxBytes else { throw ManagerError("File exceeds the safe read limit") }
        }
        return data
    }
    public static func readText(_ path: String, maxBytes: Int = maxConfigBytes) throws -> String {
        guard let text = String(data: try readData(path, maxBytes: maxBytes), encoding: .utf8) else {
            throw ManagerError("The file is not valid UTF-8")
        }; return text
    }
    public static func mode(_ path: String) throws -> UInt16 {
        var s = stat(); guard lstat(path, &s) == 0 else { throw fileError("Inspect", path) }; return s.st_mode & 0o777
    }
    /// Directory fingerprints include bounded file contents, not just a folder modification date.
    /// Symlinks are fingerprinted as links, never traversed or treated as their target.
    public static func fingerprint(_ path: String, content: String? = nil) throws -> String {
        var digest = SHA256(); var count = 0; var bytes = 0
        func visit(_ current: String, depth: Int) throws {
            count += 1
            guard count <= 10_000, depth <= 20 else { throw ManagerError("Installation exceeds the safe fingerprint limit") }
            var s = stat(); guard lstat(current, &s) == 0 else { throw fileError("Inspect", current) }
            let identity = "\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
            digest.update(data: Data(identity.utf8))
            switch s.st_mode & S_IFMT {
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: current)
                digest.update(data: Data(target.utf8))
            case S_IFDIR:
                for child in try children(current) {
                    digest.update(data: Data(child.utf8)); try visit(join(current, child), depth: depth + 1)
                }
            case S_IFREG:
                let data = current == path && content != nil ? Data(content!.utf8) : try readData(current, maxBytes: 64 * 1024 * 1024)
                bytes += data.count; guard bytes <= 128 * 1024 * 1024 else { throw ManagerError("Installation exceeds the safe fingerprint limit") }
                digest.update(data: data)
            default: throw ManagerError("Special filesystem nodes cannot be managed")
            }
        }
        try visit(path, depth: 0)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func privateDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var s = stat()
        guard lstat(path, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR, s.st_uid == getuid() else {
            throw ManagerError("App storage must be a real directory owned by the current user")
        }
        guard let privateACL = acl_init(0) else { throw fileError("Prepare private access", path) }
        defer { acl_free(UnsafeMutableRawPointer(privateACL)) }
        guard acl_set_file(path, ACL_TYPE_EXTENDED, privateACL) == 0, chmod(path, 0o700) == 0 else { throw fileError("Secure", path) }
    }
    /// Exclusive temp file, fsync, atomic rename. Existing ACLs, xattrs, owner/group,
    /// and permissions are preserved, rather than weakened by inode replacement.
    /// Never follows a destination symlink.
    public static func atomicWrite(_ path: String, data: Data, mode: UInt16 = 0o600) throws {
        guard !isSymlink(path) else { throw ManagerError("Refusing to replace a symbolic link") }
        let temporary = join(parent(path), ".harness-\(UUID().uuidString).tmp")
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw fileError("Prepare write", path) }
        var descriptorOpen = true
        defer { if descriptorOpen { close(fd) }; unlink(temporary) }
        if exists(path) {
            let sourceFD = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard sourceFD >= 0 else { throw fileError("Read file security metadata", path) }
            defer { close(sourceFD) }
            var original = stat()
            guard fstat(sourceFD, &original) == 0, (original.st_mode & S_IFMT) == S_IFREG,
                  fcopyfile(sourceFD, fd, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw ManagerError("Existing access controls could not be preserved; no file was replaced")
            }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw fileError("Write", path) }
                guard n > 0 else { throw ManagerError("The write did not make progress") }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw fileError("Save", path) }
        close(fd); descriptorOpen = false
        guard !isSymlink(path), rename(temporary, path) == 0 else { throw fileError("Replace", path) }
        let parentFD = open(parent(path), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if parentFD >= 0 { _ = fsync(parentFD); close(parentFD) }
    }
    public static func atomicWrite(_ path: String, text: String, mode: UInt16 = 0o600) throws {
        try atomicWrite(path, data: Data(text.utf8), mode: mode)
    }
    /// RENAME_EXCL refuses occupied destinations atomically, including broken symlinks.
    public static func moveExclusive(_ source: String, to destination: String) throws {
        guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EXDEV { throw ManagerError("The installation and backup storage are on different filesystems; nothing was moved") }
            if errno == EEXIST { throw ManagerError("The destination is occupied; nothing was overwritten") }
            throw fileError("Move", source)
        }
    }
    static func fileError(_ action: String, _ path: String) -> ManagerError {
        // Do not surface file contents or command/environment values in an error.
        ManagerError("\(action) failed for \(name(path)): \(String(cString: strerror(errno)))")
    }
}
