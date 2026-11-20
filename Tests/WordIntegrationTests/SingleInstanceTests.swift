import Darwin
import Foundation
import Testing
@testable import WordMathApp

@Suite("Single-instance ownership")
struct SingleInstanceTests {
    @Test func lockPersistsAcrossLaunchesAndReleases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = try SingleInstanceLock.acquire(in: directory)
        #expect(first != nil)
        #expect(try SingleInstanceLock.acquire(in: directory) == nil)
        withExtendedLifetime(first) {}
        first = nil
        let file = directory.appendingPathComponent(SingleInstanceLock.filename)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try SingleInstanceLock.acquire(in: directory) != nil)
    }

    @Test func simultaneousLaunchesProduceOneOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owners = try await withThrowingTaskGroup(of: SingleInstanceLock?.self) { group in
            for _ in 0..<24 {
                group.addTask { try SingleInstanceLock.acquire(in: directory) }
            }
            var held: [SingleInstanceLock] = []
            for try await claim in group {
                if let claim { held.append(claim) }
            }
            return held
        }
        #expect(owners.count == 1)
        #expect(try SingleInstanceLock.acquire(in: directory) == nil)
        withExtendedLifetime(owners) {}
    }

    @Test func unsafeLockPathIsAnErrorNotAnotherOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(SingleInstanceLock.filename)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: directory)
        #expect(throws: (any Error).self) { try SingleInstanceLock.acquire(in: directory) }
    }

    // Independent process takes the same Darwin flock. Force a crash while it still holds
    // the inode, then prove the next app can start without inspecting a PID or deleting a file.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func recoveryAfterOwnerProcessIsKilled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try SingleInstanceLock.acquire(in: directory) != nil) // create private path then release
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [
            "-MFcntl=:flock", "-e",
            #"open(my $lock, "+<", $ARGV[0]) or die $!; flock($lock, LOCK_EX | LOCK_NB) or die $!; syswrite(STDOUT, "L", 1); sleep 10;"#,
            directory.appendingPathComponent(SingleInstanceLock.filename).path
        ]
        let ready = Pipe()
        child.standardOutput = ready
        try child.run()
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        let signal = ready.fileHandleForReading.readData(ofLength: 1)
        try #require(signal == Data("L".utf8))
        #expect(try SingleInstanceLock.acquire(in: directory) == nil)
        try #require(kill(child.processIdentifier, SIGKILL) == 0)
        child.waitUntilExit()
        #expect(try SingleInstanceLock.acquire(in: directory) != nil)
    }
}
