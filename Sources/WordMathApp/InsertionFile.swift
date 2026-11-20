import Darwin
import Foundation

/// Word remembers the user's grant for this file. Keep its path and inode across insertions.
enum InsertionFile {
    private static let filename = "insertion.docx"

    static func directory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return support.appendingPathComponent("WordMath/Insertion", isDirectory: true)
    }

    static func withContents<T>(_ data: Data, in directory: URL, perform: (URL) throws -> T) throws -> T {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        let parentFD = open(parent.path, directoryFlags)
        guard parentFD >= 0 else { throw failure(errno, at: parent) }
        defer { close(parentFD) }
        let name = directory.lastPathComponent
        if mkdirat(parentFD, name, 0o700) != 0 && errno != EEXIST {
            throw failure(errno, at: directory)
        }
        let directoryFD = openat(parentFD, name, directoryFlags)
        guard directoryFD >= 0 else { throw failure(errno, at: directory) }
        defer { close(directoryFD) }
        try validate(directoryFD, type: S_IFDIR, at: directory)

        // Exclude another importer without putting a Word-visible file lock on the DOCX.
        while flock(directoryFD, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK { throw WordIntegrationError(message: "上一次插入尚未完成，请稍后再试。") }
            throw failure(code, at: directory)
        }

        let url = directory.appendingPathComponent(filename)
        let fd = openat(directoryFD, filename, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure(errno, at: url) }
        defer { close(fd) }
        try validate(fd, type: S_IFREG, at: url)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try file.truncate(atOffset: 0)
        // After a successful Word insert, a cleanup error must not trigger a duplicate insertion.
        defer { try? file.truncate(atOffset: 0) }
        try file.write(contentsOf: data)
        return try perform(url)
    }

    private static func validate(_ fd: Int32, type: mode_t, at url: URL) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure(errno, at: url) }
        guard info.st_mode & S_IFMT == type, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              type != S_IFREG || info.st_nlink == 1 else { throw failure(EACCES, at: url) }
    }

    private static func failure(_ code: Int32, at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
