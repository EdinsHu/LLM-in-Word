import Darwin
import Foundation

/// Holding this object grants ownership of WordMath's user session. The kernel drops the
/// advisory lock on close or process exit, including SIGKILL. Leave the inode in place
/// so every launcher always competes for the same lock.
final class SingleInstanceLock: Sendable {
    private let descriptor: Int32
    static let filename = "runtime.lock"

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire() throws -> SingleInstanceLock? {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return try acquire(in: support.appendingPathComponent("WordMath/Instance", isDirectory: true))
    }

    /// Returns nil only when another instance owns the lock. Other errors must be reported.
    static func acquire(in directory: URL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Foundation can apply directory attributes after creation. Pass 0700 directly
        // to mkdir so racing launchers never see a momentarily world-readable directory.
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw failure(errno, at: directory)
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw failure(errno, at: directory) }
        defer { close(directoryFD) }
        try validate(directoryFD, type: S_IFDIR, at: directory)

        let location = directory.appendingPathComponent(filename)
        let fd = open(location.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure(errno, at: location) }
        var keepOpen = false
        defer { if !keepOpen { close(fd) } }
        try validate(fd, type: S_IFREG, at: location)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK { return nil }
            throw failure(code, at: location)
        }
        keepOpen = true
        return SingleInstanceLock(descriptor: fd)
    }

    deinit { close(descriptor) }

    private static func validate(_ fd: Int32, type: mode_t, at url: URL) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure(errno, at: url) }
        guard info.st_mode & S_IFMT == type, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else { throw failure(EACCES, at: url) }
    }

    private static func failure(_ number: Int32, at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(number), userInfo: [NSFilePathErrorKey: url.path])
    }
}
