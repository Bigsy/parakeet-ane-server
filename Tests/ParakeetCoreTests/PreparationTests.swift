import Foundation
import os
import Testing
@testable import ParakeetCore

@Suite struct PreparationTests {
    @Test func reportsProgressInOrderAndWarmsOnlyOnce() async throws {
        let stages = OSAllocatedUnfairLock(initialState: [PreparationProgress.Stage]())
        let engine = ParakeetEngine(loader: { _, progress in
            progress(.init(stage: .checkingCache)); progress(.init(stage: .loading))
            return EchoModel()
        })
        try await engine.prepare { event in stages.withLock { $0.append(event.stage) } }
        try await engine.prepare { event in stages.withLock { $0.append(event.stage) } }
        #expect(stages.withLock { $0 } == [.checkingCache, .loading, .warmingUp, .ready])
    }

    @Test func downloadAndLoadFailuresStayNotReady() async throws {
        let download = ParakeetEngine(loader: { _, _ in throw ParakeetError.downloadFailed })
        await #expect(throws: ParakeetError.downloadFailed) { try await download.prepare() }
        #expect(await download.state == .failed)
        let load = ParakeetEngine(loader: { _, _ in throw NSError(domain: "private model diagnostics", code: 1) })
        await #expect(throws: ParakeetError.preparationFailed) { try await load.prepare() }
        #expect(await load.state == .failed)
    }

    @Test func preservesModelIDs() {
        #expect(ModelChoice.allCases.map(\.modelID) == [
            "parakeet-unified-en-0.6b", "parakeet-ultra", "parakeet-tdt-0.6b-v2", "parakeet-tdt-0.6b-v3"
        ])
    }

    @Test func incompleteOfflineCacheDoesNotDownloadOrChangeFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = root.appendingPathComponent("parakeet-unified-en-0.6b")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: repository.appendingPathComponent("vocab.json"))
        let engine = ParakeetEngine(configuration: .init(cacheRoot: root, downloadPolicy: .requireCached))
        await #expect(throws: ParakeetError.missingCache) { try await engine.prepare() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: repository.path) == ["vocab.json"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".parakeet-core.lock").path))
    }
}
