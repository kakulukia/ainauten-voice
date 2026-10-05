import Foundation

public enum FormattingModel: String, Codable, Sendable {
    case qwen3, cloud, other
    public var title: String { switch self { case .qwen3: "Qwen3"; case .cloud: "Cloud"; case .other: "Textoptimierung" } }
}

public enum OptimizationStatus: String, Codable, Sendable {
    case used, notNeeded, originalStyle, originalRequested, fallback
}

/// Wall-clock time after Stop, until the text is ready. Concurrent stages may overlap.
public struct ProcessingMetrics: Codable, Equatable, Sendable {
    public let totalSeconds: Double
    public let preparationSeconds: Double
    public let recognitionSeconds: Double
    public let optimizationSeconds: Double
    public let optimizationStatus: OptimizationStatus
    public let model: FormattingModel?
    public let modelCalls: Int
    public init(totalSeconds: Double, preparationSeconds: Double = 0, recognitionSeconds: Double,
                optimizationSeconds: Double, optimizationStatus: OptimizationStatus,
                model: FormattingModel? = nil, modelCalls: Int = 0) {
        self.totalSeconds = totalSeconds; self.preparationSeconds = preparationSeconds
        self.recognitionSeconds = recognitionSeconds; self.optimizationSeconds = optimizationSeconds
        self.optimizationStatus = optimizationStatus; self.model = model; self.modelCalls = modelCalls
    }
    public var isValid: Bool {
        totalSeconds.isFinite && totalSeconds >= 0 && modelCalls >= 0 &&
        (modelCalls == 0 ? model == nil : model != nil) && (optimizationStatus != .used || modelCalls > 0) &&
        [preparationSeconds, recognitionSeconds, optimizationSeconds].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= totalSeconds }
    }
}

/// Each session owns one recorder. Late completions cannot change another session.
final class ProcessingMeasurement: @unchecked Sendable {
    enum Stage { case preparation, recognition, optimization }
    private let lock = NSLock()
    private var active: [UUID: (Stage, Double)] = [:]
    private var intervals: [(Stage, Double, Double)] = []
    private var model: FormattingModel?
    private var modelCalls = 0
    func begin(_ stage: Stage, id: UUID = UUID(), model: FormattingModel? = nil) -> UUID {
        lock.lock(); defer { lock.unlock() }
        active[id] = (stage, ProcessInfo.processInfo.systemUptime)
        if let model { self.model = model; modelCalls += 1 }
        return id
    }
    func end(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let (stage, start) = active.removeValue(forKey: id) { intervals.append((stage, start, ProcessInfo.processInfo.systemUptime)) }
    }
    func measure<T>(_ stage: Stage, operation: () async throws -> T) async rethrows -> T {
        let id = begin(stage); defer { end(id) }
        return try await operation()
    }
    func snapshot(stoppedAt: Double, status: OptimizationStatus, now: Double = ProcessInfo.processInfo.systemUptime) -> ProcessingMetrics {
        lock.lock(); defer { lock.unlock() }
        let ranges = intervals + active.values.map { ($0.0, $0.1, now) }
        func seconds(_ stage: Stage) -> Double {
            let clipped = ranges.filter { $0.0 == stage }.map { (max(stoppedAt, $0.1), min(now, $0.2)) }
                .filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
            var total = 0.0, end = stoppedAt
            for (start, finish) in clipped { total += max(0, finish - max(start, end)); end = max(end, finish) }
            return total
        }
        let total = max(0, now - stoppedAt)
        return ProcessingMetrics(totalSeconds: total, preparationSeconds: min(total, seconds(.preparation)),
                                 recognitionSeconds: min(total, seconds(.recognition)), optimizationSeconds: min(total, seconds(.optimization)),
                                 optimizationStatus: status == .notNeeded && modelCalls > 0 ? .used : status,
                                 model: model, modelCalls: modelCalls)
    }
}

/// Observe actual model use, including failed/cancelled calls and cached revisions.
struct MeasuredFormatter: TextFormatting {
    let base: any TextFormatting
    let measurement: ProcessingMeasurement
    func prepare() async throws { try await base.prepare() }
    func format(_ text: String, style: TextStyle, context: String, vocabulary: [String]) async throws -> String {
        let id = UUID(); defer { measurement.end(id) }
        return try await base.format(text, style: style, context: context, vocabulary: vocabulary, onModelUse: { model in
            _ = measurement.begin(.optimization, id: id, model: model)
        })
    }
}
