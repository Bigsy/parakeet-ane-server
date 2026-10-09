@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation

struct StreamingObservation: Codable {
    let fixture: String
    let iteration: Int
    let chunkSamples: Int
    let text: String
    let processMilliseconds: Double
    let finishMilliseconds: Double
    let maximumResidentBytes: Int
    let physicalFootprintBytes: UInt64
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

func streamingSpike(args: [String]) async throws {
    let root = URL(fileURLWithPath: args[1])
    let directory = root.appendingPathComponent(Repo.parakeetUnified.folderName)
    let manager = StreamingUnifiedAsrManager()
    if args[0] == "prepare-streaming" {
        try await ModelHub.download(.parakeetUnified, to: root,
                                   additionalModelNames: [ModelNames.ParakeetUnified.streamingEncoderInt8File])
        try await manager.loadModels(from: directory)
        await manager.cleanup()
        return
    }
    try await manager.loadModels(from: directory)
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let samples = data.withUnsafeBytes { raw in
        stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
    }
    let chunk = args.count > 3 ? Int(args[3]) ?? 320 : 320
    let repetitions = args.count > 4 ? Int(args[4]) ?? 30 : 30
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for iteration in -1..<repetitions {
        try await manager.reset()
        let started = ContinuousClock.now
        for offset in stride(from: 0, to: samples.count, by: chunk) {
            let count = min(chunk, samples.count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count) }
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            _ = await manager.consumeTokenTimings()
        }
        let finishStarted = ContinuousClock.now
        let text = try await manager.finish()
        let ended = ContinuousClock.now
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        guard iteration >= 0 else { continue }
        let observation = StreamingObservation(
            fixture: URL(fileURLWithPath: args[2]).lastPathComponent, iteration: iteration, chunkSamples: chunk,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            processMilliseconds: milliseconds(started.duration(to: finishStarted)),
            finishMilliseconds: milliseconds(finishStarted.duration(to: ended)), maximumResidentBytes: Int(usage.ru_maxrss), physicalFootprintBytes: physicalFootprint(),
            userCPUSeconds: Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
            systemCPUSeconds: Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6)
        print(String(decoding: try encoder.encode(observation), as: UTF8.self))
    }
    await manager.cleanup()
}

func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

func residency(args: [String]) async throws {
    let directory = URL(fileURLWithPath: args[1]).appendingPathComponent(Repo.parakeetUnified.folderName)
    let baseline = physicalFootprint()
    let batch = UnifiedAsrManager()
    try await batch.loadModels(from: directory)
    _ = try await batch.transcribe([Float](repeating: 0, count: 16000))
    let batchBytes = physicalFootprint()
    let stream = StreamingUnifiedAsrManager()
    try await stream.loadModels(from: directory)
    let dualBytes = physicalFootprint()
    await batch.cleanup()
    let streamingBytes = physicalFootprint()
    print("{\"baselineBytes\":\(baseline),\"batchBytes\":\(batchBytes),\"dualBytes\":\(dualBytes),\"streamingAfterBatchCleanupBytes\":\(streamingBytes)}")
    await stream.cleanup()
}
