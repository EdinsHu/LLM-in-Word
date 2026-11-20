import Foundation
import Testing
@testable import WordMathApp

@Suite("Reusable Word insertion file")
struct InsertionFileTests {
    private enum ImportFailure: Error { case rejected }

    private func withTemporaryDirectory(_ perform: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        try perform(parent)
    }

    @Test func reusesFileIdentityForShorterContentsAndErasesAfterImport() throws {
        try withTemporaryDirectory { parent in
            let directory = parent.appendingPathComponent("Insertion")
            var identities: [UInt64] = []
            var paths: [URL] = []
            for data in [Data(repeating: 65, count: 32768), Data("短".utf8)] {
                let path = try InsertionFile.withContents(data, in: directory) { url in
                    #expect(try Data(contentsOf: url) == data)
                    let info = try FileManager.default.attributesOfItem(atPath: url.path)
                    identities.append(try #require(info[.systemFileNumber] as? NSNumber).uint64Value)
                    #expect((info[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                    return url
                }
                paths.append(path)
                #expect(try Data(contentsOf: path).isEmpty)
            }
            #expect(paths[0] == paths[1])
            #expect(identities[0] == identities[1])
        }
    }

    @Test func failedOrOverlappingImportsKeepTheFileReusable() throws {
        try withTemporaryDirectory { parent in
            let directory = parent.appendingPathComponent("Insertion")
            let outer = Data("first".utf8)
            let second = Data("second".utf8)
            var usedURL: URL?
            let interruptedImport = {
                try InsertionFile.withContents(outer, in: directory) { file throws -> Void in
                    usedURL = file
                    #expect(throws: (any Error).self) {
                        try InsertionFile.withContents(second, in: directory) { _ in
                            Issue.record("An overlapping import must not replace an active Word fragment")
                        }
                    }
                    #expect(try Data(contentsOf: file) == outer)
                    throw ImportFailure.rejected
                }
            }
            #expect(throws: ImportFailure.self, performing: interruptedImport)
            let file = try #require(usedURL)
            #expect(try Data(contentsOf: file).isEmpty)
            try InsertionFile.withContents(second, in: directory) { next throws -> Void in
                #expect(next == file)
                #expect(try Data(contentsOf: next) == second)
            }
            #expect(try Data(contentsOf: file).isEmpty)
        }
    }

    @Test func rejectsLinkedFilesBeforeOverwritingTheirContents() throws {
        try withTemporaryDirectory { parent in
            let directory = parent.appendingPathComponent("Insertion")
            let file = try InsertionFile.withContents(Data("fragment".utf8), in: directory) { $0 }
            let target = parent.appendingPathComponent("user-document")
            let sentinel = Data("keep this document intact".utf8)
            try sentinel.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            for useSymlink in [true, false] {
                try FileManager.default.removeItem(at: file)
                if useSymlink {
                    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
                } else {
                    try FileManager.default.linkItem(at: target, to: file)
                }
                #expect(throws: (any Error).self) {
                    try InsertionFile.withContents(Data("replacement".utf8), in: directory) { _ in
                        Issue.record("A linked fragment must never reach Word")
                    }
                }
                #expect(try Data(contentsOf: target) == sentinel)
            }
        }
    }
}
