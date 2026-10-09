import Darwin
import Foundation
import ParakeetCore

struct SessionObservation: Codable {
    let fixture: String
    let iteration: Int
    let chunkSamples: Int
    let text: String
    let actualAudioDuration: Double
    let finishMilliseconds: Double
    let totalMilliseconds: Double
    let inferenceMilliseconds: Double
    let physicalFootprintBytes: UInt64
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let interruptWakeups: UInt64
    let platformIdleWakeups: UInt64
}

func cpuUsage() -> (Double, Double) {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return (Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
            Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6)
}

func wakeups() -> (UInt64, UInt64) {
    var info = task_power_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? (info.task_interrupt_wakeups, info.task_platform_idle_wakeups) : (0, 0)
}

func sessionBenchmark(args: [String]) async throws {
    let root = URL(fileURLWithPath: args[1])
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let samples = data.withUnsafeBytes { raw in
        stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
    }
    let chunk = args.count > 3 ? Int(args[3]) ?? 320 : 320
    let repetitions = args.count > 4 ? Int(args[4]) ?? 30 : 30
    let realtime = args[0] == "session-realtime"
    let engine = ParakeetEngine(configuration: .init(mode: .streaming, cacheRoot: root, downloadPolicy: .requireCached))
    try await engine.prepare()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for iteration in 0..<repetitions {
        let usageBefore = cpuUsage(); let wakeupsBefore = wakeups()
        let session = try await engine.startStreaming()
        let began = ContinuousClock.now
        for offset in stride(from: 0, to: samples.count, by: chunk) {
            if realtime {
                try await ContinuousClock().sleep(until: began.advanced(by: .nanoseconds(Int64(offset) * 1_000_000_000 / 16000)))
            }
            try await session.append(PCM16kMono(samples: Array(samples[offset..<min(offset + chunk, samples.count)])), startingAt: offset)
        }
        if realtime {
            try await ContinuousClock().sleep(until: began.advanced(by: .nanoseconds(Int64(samples.count) * 1_000_000_000 / 16000)))
        }
        let result = try await session.finish()
        let after = cpuUsage(); let wakeupsAfter = wakeups()
        let observation = SessionObservation(fixture: URL(fileURLWithPath: args[2]).lastPathComponent,
            iteration: iteration, chunkSamples: chunk, text: result.text, actualAudioDuration: result.actualAudioDuration,
            finishMilliseconds: milliseconds(result.finalizationDuration ?? .zero), totalMilliseconds: milliseconds(result.totalDuration),
            inferenceMilliseconds: milliseconds(result.inferenceDuration), physicalFootprintBytes: physicalFootprint(),
            userCPUSeconds: after.0 - usageBefore.0, systemCPUSeconds: after.1 - usageBefore.1,
            interruptWakeups: wakeupsAfter.0 - wakeupsBefore.0, platformIdleWakeups: wakeupsAfter.1 - wakeupsBefore.1)
        print(String(decoding: try encoder.encode(observation), as: UTF8.self))
    }
    try await engine.unload()
}
