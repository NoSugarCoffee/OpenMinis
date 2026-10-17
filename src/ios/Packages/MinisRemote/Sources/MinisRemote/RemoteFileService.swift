@preconcurrency import Citadel
import Foundation
import NIOCore
import os

public struct RemoteFileStamp: Equatable, Sendable {
    public let size: UInt64
    /// Whole seconds, as SFTP v3 reports it.
    public let mtime: UInt32

    public init(size: UInt64, mtime: UInt32) {
        self.size = size
        self.mtime = mtime
    }
}

public enum RemoteCopyEndpoint: Equatable, Sendable {
    /// A real path on the phone's filesystem.
    case local(String)
    case remote(host: String, path: String)
}

public enum RemoteFileError: Error, Equatable, Sendable {
    case conflict(path: String)
    case notFound(path: String)
    case tooLarge(path: String, size: UInt64)
    case isDirectory(path: String)
    case relativePath(path: String)
    /// A `FileToolLogic` rejection; `message` is the exact text the local tool returns.
    case rejected(message: String)
    case unsupportedCopy(from: RemoteCopyEndpoint, to: RemoteCopyEndpoint)
    case failed(path: String, detail: String)

    public var userMessage: String {
        switch self {
        case .conflict(let path):
            return "Error: \(path) changed on the host since it was last read. Read it again with file_read, then retry the edit."
        case .tooLarge(let path, let size):
            let quoted = RemoteRunScripts.shellQuote(path)
            return "Error: \(path) is \(size) bytes, over the \(RemoteFileService.maxReadableBytes)-byte limit for reading or editing a host file. Read part of it with shell_execute, for example `tail -n 200 \(quoted)` or `sed -n '100,200p' \(quoted)`."
        case .notFound(let path):
            return "Error: No such file on the host: \(path)"
        case .isDirectory(let path):
            return "Error: \(path) is a directory on the host. Pass a file path."
        case .relativePath(let path):
            return "Error: \(path) is not an absolute path. Resolve it against the session's working directory first."
        case .rejected(let message):
            return message
        case .unsupportedCopy:
            return "Error: copy needs one phone path and one host path. Use a command on the host to copy between host paths."
        case .failed(let path, let detail):
            return "Error: \(path): \(detail)"
        }
    }
}

/// File access on a host over SFTP. Paths are absolute host paths: callers resolve relative ones with
/// `RemoteRouting.resolveRemotePath` first, and a relative path throws `relativePath`.
/// Nothing ever falls back to the phone's filesystem; transport failures surface as `RemoteHostError`.
public actor RemoteFileService {
    private static let logger = Logger(subsystem: "app.minis.remote", category: "RemoteFileService")
    static let chunkSize = 64 * 1024
    /// read and edit hold the whole file in memory on the phone.
    public static let maxReadableBytes: UInt64 = 10_485_760
    private static let defaultRequestTimeout: Duration = .seconds(30)

    private struct StampKey: Hashable {
        let host: String
        let path: String
    }

    private let pool: SSHConnectionPool
    private let requestTimeout: Duration
    /// What the model last saw of each file, so an edit can refuse a file changed behind its back.
    private var lastSeen: [StampKey: RemoteFileStamp] = [:]

    public init(pool: SSHConnectionPool) {
        self.init(pool: pool, requestTimeout: Self.defaultRequestTimeout)
    }

    /// `requestTimeout` bounds each SFTP request and the rename exec; no answer in that time means the
    /// connection is dead.
    init(pool: SSHConnectionPool, requestTimeout: Duration) {
        self.pool = pool
        self.requestTimeout = requestTimeout
    }

    public static func tempName(for path: String, random: String) -> String {
        let slash = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        return "\(path[..<slash]).\(path[slash...]).minis-tmp-\(random)"
    }

    public func read(
        host: String, path: String, offset: Int?, lines: Int?, direction: String?, maxLength: Int?,
        defaultMaxLength: Int
    ) async throws -> String {
        try Self.requireAbsolute(path)
        if let parameterError = FileToolLogic.readParameterError(lines: lines, maxLength: maxLength) {
            throw RemoteFileError.rejected(message: parameterError)
        }
        let fetched: FetchedForRead = try await withSession(host: host) { session in
            let entry = try await session.existingFile(path)
            var data = Data()
            _ = try await session.download(path, from: 0, limit: UInt64(FileToolLogic.binarySniffLength)) {
                data.append(contentsOf: $0.readableBytesView)
            }
            if let preview = FileToolLogic.binaryPreview(
                path: path, leadingBytes: data, totalBytes: Int(entry.stamp.size)) {
                return .binaryPreview(preview)
            }
            try Self.requireReadable(entry, path: path)
            // A short first chunk is EOF. The stat size cannot decide this: procfs and sysfs report 0.
            if data.count == FileToolLogic.binarySniffLength {
                try await Self.downloadBounded(session, path: path, into: &data)
            }
            return .contents(stamp: entry.stamp, data: data)
        }
        switch fetched {
        case .binaryPreview(let preview):
            return preview
        case .contents(let stamp, let data):
            switch FileToolLogic.read(
                path: path, data: data, offset: offset, lines: lines, direction: direction, maxLength: maxLength,
                defaultMaxLength: defaultMaxLength) {
            case .text(let output):
                lastSeen[StampKey(host: host, path: path)] = stamp
                return output
            case .binary(let preview):
                return preview
            case .rejected(let message):
                throw RemoteFileError.rejected(message: message)
            }
        }
    }

    public func write(host: String, path: String, content: String) async throws {
        try Self.requireAbsolute(path)
        let data = Data(content.utf8)
        let written = try await withSession(host: host) { session in
            try await session.replace(path, expecting: nil, nextChunk: Self.chunks(of: data))
        }
        lastSeen[StampKey(host: host, path: path)] = written.stamp
    }

    /// Like the local tool's append: a missing file is created. The existing bytes are downloaded and written back
    /// with `content` added through the same atomic replace, conditional on the file not changing meanwhile.
    public func append(host: String, path: String, content: String) async throws {
        try Self.requireAbsolute(path)
        let addition = Data(content.utf8)
        let written = try await withSession(host: host) { session in
            guard let entry = try await session.fileIfPresent(path) else {
                return try await session.replace(path, expecting: nil, nextChunk: Self.chunks(of: addition))
            }
            try Self.requireReadable(entry, path: path)
            var data = Data()
            try await Self.downloadBounded(session, path: path, into: &data)
            data.append(addition)
            return try await session.replace(path, expecting: entry.stamp, nextChunk: Self.chunks(of: data))
        }
        lastSeen[StampKey(host: host, path: path)] = written.stamp
    }

    /// Two checks guard against lost updates: the file must be unchanged since the last `read` (if any), and
    /// unchanged between this edit's own read and the rename. A same-size change within the same second is
    /// invisible to both, because SFTP v3 reports mtime in whole seconds.
    public func edit(
        host: String, path: String, oldString: String, newString: String, replaceAll: Bool
    ) async throws -> String {
        try Self.requireAbsolute(path)
        let key = StampKey(host: host, path: path)
        let lastRead = lastSeen[key]
        let (summary, stamp) = try await withSession(host: host) { session in
            let entry = try await session.existingFile(path)
            if let lastRead, lastRead != entry.stamp {
                throw RemoteFileError.conflict(path: path)
            }
            try Self.requireReadable(entry, path: path)
            var data = Data()
            try await Self.downloadBounded(session, path: path, into: &data)
            switch FileToolLogic.edit(
                path: path, data: data, oldString: oldString, newString: newString, replaceAll: replaceAll) {
            case .rejected(let message):
                throw RemoteFileError.rejected(message: message)
            case .edited(let updatedContent, let summary):
                let written = try await session.replace(
                    path, expecting: entry.stamp, nextChunk: Self.chunks(of: Data(updatedContent.utf8)))
                return (summary, written.stamp)
            }
        }
        lastSeen[key] = stamp
        return summary
    }

    /// Streams in `chunkSize` pieces and replaces the destination atomically on either side.
    public func copy(from source: RemoteCopyEndpoint, to destination: RemoteCopyEndpoint) async throws -> UInt64 {
        switch (source, destination) {
        case (.local(let localPath), .remote(let host, let remotePath)):
            try Self.requireAbsolute(localPath)
            try Self.requireAbsolute(remotePath)
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
            defer { Self.close(reader, path: localPath) }
            let written = try await withSession(host: host) { session in
                try await session.replace(remotePath, expecting: nil) {
                    try Task.checkCancellation()
                    guard let chunk = try reader.read(upToCount: Self.chunkSize), !chunk.isEmpty else { return nil }
                    return chunk
                }
            }
            lastSeen[StampKey(host: host, path: remotePath)] = written.stamp
            return written.bytes
        case (.remote(let host, let remotePath), .local(let localPath)):
            try Self.requireAbsolute(remotePath)
            try Self.requireAbsolute(localPath)
            return try await download(host: host, remotePath: remotePath, to: URL(fileURLWithPath: localPath))
        default:
            throw RemoteFileError.unsupportedCopy(from: source, to: destination)
        }
    }

    /// Names of the subdirectories of `path`, sorted, for the working-directory picker. Symlinks are left out:
    /// the listing reports them unresolved.
    public func listDirectories(host: String, path: String) async throws -> [String] {
        try Self.requireAbsolute(path)
        return try await withSession(host: host) { session in
            try await session.directoryNames(path)
        }
    }

    private func download(host: String, remotePath: String, to destination: URL) async throws -> UInt64 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = URL(fileURLWithPath: Self.tempName(for: destination.path, random: Self.randomSuffix()))
        guard fileManager.createFile(atPath: temp.path, contents: nil) else {
            throw RemoteFileError.failed(path: destination.path, detail: "could not create a temporary file next to it")
        }
        do {
            let writer = try FileHandle(forWritingTo: temp)
            let bytes: UInt64
            do {
                bytes = try await withSession(host: host) { session in
                    _ = try await session.existingFile(remotePath)
                    return try await session.download(remotePath, from: 0, limit: nil) {
                        try Task.checkCancellation()
                        try writer.write(contentsOf: $0.readableBytesView)
                    }
                }
            } catch {
                Self.close(writer, path: temp.path)
                throw error
            }
            try writer.close()
            guard rename(temp.path, destination.path) == 0 else {
                throw RemoteFileError.failed(path: destination.path, detail: String(cString: strerror(errno)))
            }
            return bytes
        } catch {
            Self.removeLocal(temp)
            throw error
        }
    }

    private func withSession<T: Sendable>(
        host: String, _ body: @Sendable (SFTPSession) async throws -> T
    ) async throws -> T {
        let pool = pool
        let timeout = requestTimeout
        return try await pool.withSFTP(host: host, openTimeout: timeout) { sftp in
            try await body(SFTPSession(sftp: sftp, pool: pool, host: host, timeout: timeout))
        }
    }

    /// Continues from `data.count`. The bound also covers files the stat under-reports or that grow meanwhile.
    private static func downloadBounded(_ session: SFTPSession, path: String, into data: inout Data) async throws {
        let start = UInt64(data.count)
        _ = try await session.download(path, from: start, limit: maxReadableBytes + 1 - start) {
            data.append(contentsOf: $0.readableBytesView)
        }
        guard UInt64(data.count) <= maxReadableBytes else {
            throw RemoteFileError.tooLarge(path: path, size: UInt64(data.count))
        }
    }

    private static func requireReadable(_ entry: RemoteEntry, path: String) throws {
        guard entry.stamp.size <= maxReadableBytes else {
            throw RemoteFileError.tooLarge(path: path, size: entry.stamp.size)
        }
    }

    private static func requireAbsolute(_ path: String) throws {
        guard path.hasPrefix("/") else { throw RemoteFileError.relativePath(path: path) }
    }

    static func randomSuffix() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    static func chunks(of data: Data) -> () -> Data? {
        var offset = data.startIndex
        return {
            guard offset < data.endIndex else { return nil }
            let end = min(offset + chunkSize, data.endIndex)
            defer { offset = end }
            return data.subdata(in: offset..<end)
        }
    }

    private static func close(_ handle: FileHandle, path: String) {
        do {
            try handle.close()
        } catch {
            logger.error("Closing \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func removeLocal(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error(
                "Removing temporary \(url.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private enum FetchedForRead: Sendable {
    case binaryPreview(String)
    case contents(stamp: RemoteFileStamp, data: Data)
}

private struct RemoteEntry: Sendable {
    let stamp: RemoteFileStamp
    let isDirectory: Bool
    let permissionBits: UInt32?

    init(path: String, attributes: SFTPFileAttributes) throws {
        guard let size = attributes.size, let modified = attributes.accessModificationTime?.modificationTime else {
            throw RemoteFileError.failed(path: path, detail: "the host did not report its size and modification time")
        }
        stamp = RemoteFileStamp(size: size, mtime: UInt32(modified.timeIntervalSince1970))
        isDirectory = attributes.permissions.map { $0 & 0o170000 == 0o040000 } ?? false
        permissionBits = attributes.permissions.map { $0 & 0o7777 }
    }
}

/// Citadel's `SFTPFile` is not Sendable; each one is used by a single task at a time, one request after another.
private final class OpenRemoteFile: @unchecked Sendable {
    let file: SFTPFile

    init(_ file: SFTPFile) {
        self.file = file
    }
}

/// One SFTP channel's worth of work. Every request runs under `timeout`.
private struct SFTPSession: Sendable {
    private static let logger = Logger(subsystem: "app.minis.remote", category: "RemoteFileService")
    private static let renameIntoDirectoryExit = 21
    private static let cleanupTimeout: Duration = .seconds(5)

    let sftp: SFTPClient
    let pool: SSHConnectionPool
    let host: String
    let timeout: Duration

    func fileIfPresent(_ path: String) async throws -> RemoteEntry? {
        guard let entry = try await entry(at: path) else { return nil }
        guard !entry.isDirectory else { throw RemoteFileError.isDirectory(path: path) }
        return entry
    }

    func existingFile(_ path: String) async throws -> RemoteEntry {
        guard let entry = try await entry(at: path) else { throw RemoteFileError.notFound(path: path) }
        guard !entry.isDirectory else { throw RemoteFileError.isDirectory(path: path) }
        return entry
    }

    func directoryNames(_ path: String) async throws -> [String] {
        let sftp = sftp
        let listing = try await call(path) { try await sftp.listDirectory(atPath: path) }
        return listing.flatMap(\.components)
            .filter { component in
                component.filename != "." && component.filename != ".."
                    && component.attributes.permissions.map { $0 & 0o170000 == 0o040000 } == true
            }
            .map(\.filename)
            .sorted()
    }

    /// Reads from `start` to the end of the file, or at most `limit` bytes. Returns the byte count.
    func download(
        _ path: String, from start: UInt64, limit: UInt64?, into sink: (ByteBuffer) throws -> Void
    ) async throws -> UInt64 {
        let sftp = sftp
        let file = try await call(path) {
            OpenRemoteFile(try await sftp.openFile(filePath: path, flags: .read))
        }
        do {
            var received: UInt64 = 0
            while limit.map({ received < $0 }) ?? true {
                let from = start + received
                let length = UInt32(min(UInt64(RemoteFileService.chunkSize), limit.map { $0 - received } ?? .max))
                let chunk = try await call(path) { try await file.file.read(from: from, length: length) }
                if chunk.readableBytes == 0 { break }
                try sink(chunk)
                received += UInt64(chunk.readableBytes)
            }
            try await call(path) { try await file.file.close() }
            return received
        } catch {
            closeInBackground(file)
            throw error
        }
    }

    /// Writes a temp file in the target's directory, then renames it over the target, keeping the target's
    /// permission bits. `expecting` makes the rename conditional on the target's stamp. An existing symlink is
    /// resolved first, so the write goes through it like a local `Data.write`.
    func replace(
        _ path: String, expecting: RemoteFileStamp?, nextChunk: () throws -> Data?
    ) async throws -> (stamp: RemoteFileStamp, bytes: UInt64) {
        let existing = try await entry(at: path)
        if existing?.isDirectory == true { throw RemoteFileError.isDirectory(path: path) }
        if let expecting, existing?.stamp != expecting { throw RemoteFileError.conflict(path: path) }
        if existing == nil { try await ensureParentDirectory(of: path) }

        let target = existing == nil ? path : try await realPath(path)
        let temp = RemoteFileService.tempName(for: target, random: RemoteFileService.randomSuffix())
        let bytes: UInt64
        do {
            bytes = try await writeNewFile(temp, for: path, nextChunk: nextChunk)
            let current = try await entry(at: target)
            if let expecting, current?.stamp != expecting { throw RemoteFileError.conflict(path: path) }
            try await rename(temp, over: target, permissionBits: current?.permissionBits, reportingAs: path)
        } catch {
            await cleanUp(temp, after: error)
            throw error
        }
        guard let written = try await entry(at: path) else {
            throw RemoteFileError.failed(path: path, detail: "the file is missing right after it was written")
        }
        return (written.stamp, bytes)
    }

    private func entry(at path: String) async throws -> RemoteEntry? {
        let sftp = sftp
        do {
            return try await call(path) { try RemoteEntry(path: path, attributes: try await sftp.getAttributes(at: path)) }
        } catch RemoteFileError.notFound {
            return nil
        }
    }

    private func realPath(_ path: String) async throws -> String {
        let sftp = sftp
        return try await call(path) { try await sftp.getRealPath(atPath: path) }
    }

    /// Unstructured so it runs even when the caller was cancelled, which is what interrupted the write.
    /// A dead connection is not waited on: the removal would only time out.
    private func cleanUp(_ temp: String, after error: Error) async {
        let session = self
        let cleanup = Task { await session.discard(temp) }
        guard !(error is SFTPRequestTimedOut), sftp.isActive else { return }
        await cleanup.value
    }

    private func writeNewFile(_ temp: String, for path: String, nextChunk: () throws -> Data?) async throws -> UInt64 {
        let sftp = sftp
        let file = try await call(path) {
            // Private until the rename script sets the final mode, so a secret is never readable mid-write.
            var privateMode = SFTPFileAttributes()
            privateMode.permissions = 0o600
            return OpenRemoteFile(
                try await sftp.openFile(filePath: temp, flags: [.write, .create, .forceCreate], attributes: privateMode))
        }
        do {
            var offset: UInt64 = 0
            while let chunk = try nextChunk() {
                let at = offset
                try await call(path) { try await file.file.write(ByteBuffer(bytes: chunk), at: at) }
                offset += UInt64(chunk.count)
            }
            try await call(path) { try await file.file.close() }
            return offset
        } catch {
            closeInBackground(file)
            throw error
        }
    }

    private func ensureParentDirectory(of path: String) async throws {
        let parent = String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)])
        guard !parent.isEmpty, try await entry(at: parent) == nil else { return }
        try await runScript("mkdir -p -- \(RemoteRunScripts.shellQuote(parent))\n", path: path)
    }

    /// Citadel 0.9.2 exposes neither `posix-rename@openssh.com` nor SETSTAT, and OpenSSH's plain SFTP rename
    /// refuses an existing target (it links, then unlinks). `mv` within one directory is rename(2), which
    /// replaces the target atomically. A new file gets the mode the host's umask gives a fresh file.
    private func rename(
        _ temp: String, over target: String, permissionBits: UInt32?, reportingAs path: String
    ) async throws {
        let mode = permissionBits.map { String($0, radix: 8) } ?? "$(printf '%o' $((0666 & ~$(umask))))"
        var script = "T=\(RemoteRunScripts.shellQuote(target))\nP=\(RemoteRunScripts.shellQuote(temp))\n"
        script += "if [ -d \"$T\" ]; then exit \(Self.renameIntoDirectoryExit); fi\n"
        script += "chmod \"\(mode)\" \"$P\" || exit 1\n"
        script += "mv -f \"$P\" \"$T\"\n"
        try await runScript(script, path: path)
    }

    private func runScript(_ script: String, path: String) async throws {
        let marker = RemoteExecutor.makeFrameMarker()
        let result = try await pool.exec(
            host: host, script: RemoteExecutor.framedTransportScript(script, marker: marker), timeout: timeout)
        let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteExecutor.unframe(result.stdout, marker: marker) != nil else {
            throw RemoteFileError.failed(path: path, detail: "the host shell did not run the file script (\(detail))")
        }
        if result.exitStatus == Self.renameIntoDirectoryExit { throw RemoteFileError.isDirectory(path: path) }
        guard result.exitStatus == 0 else {
            throw RemoteFileError.failed(path: path, detail: "exit \(result.exitStatus): \(detail)")
        }
    }

    private func call<T: Sendable>(_ path: String, _ request: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await withSFTPDeadline(timeout, request)
        } catch let status as SFTPMessage.Status {
            if status.errorCode == .noSuchFile { throw RemoteFileError.notFound(path: path) }
            let reason = status.message.isEmpty ? status.errorCode.debugDescription : status.message
            throw RemoteFileError.failed(path: path, detail: "the host refused the request: \(reason)")
        }
    }

    fileprivate func discard(_ temp: String) async {
        let sftp = sftp
        do {
            try await withSFTPDeadline(min(timeout, Self.cleanupTimeout)) { try await sftp.remove(at: temp) }
        } catch {
            Self.logger.error(
                "Removing temporary \(temp, privacy: .public) on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func closeInBackground(_ file: OpenRemoteFile) {
        let host = host
        Task {
            do {
                try await file.file.close()
            } catch {
                Self.logger.error(
                    "Closing a remote file on \(host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
