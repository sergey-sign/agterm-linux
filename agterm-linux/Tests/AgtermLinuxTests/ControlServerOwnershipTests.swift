import Foundation
import Testing
@testable import AgtermLinux

@Suite("Linux control socket ownership")
struct ControlServerOwnershipTests {
    @Test("a second server refuses an already-owned socket without advertising it")
    func duplicateOwnerIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agterm.sock").path

        let first = ControlServer(path: path)
        let second = ControlServer(path: path)
        defer {
            second.stop()
            first.stop()
        }

        #expect(first.resolvedSocketPath == path)
        #expect(second.resolvedSocketPath == path + ControlServer.unavailableSuffix)
        #expect(first.boundSocketPath == nil)
        #expect(second.boundSocketPath == nil)
    }

    @Test("stopping an owner releases the lock for a later server")
    func ownershipCanBeReacquired() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agterm.sock").path

        let first = ControlServer(path: path)
        first.stop()
        let replacement = ControlServer(path: path)
        defer { replacement.stop() }

        #expect(replacement.resolvedSocketPath == path)
    }
}
