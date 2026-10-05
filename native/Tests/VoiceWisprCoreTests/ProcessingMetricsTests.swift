import XCTest
@testable import VoiceWisprCore

private actor MetricsSpeech: SpeechTranscribing {
    func prepare() async throws {}
    func transcribe(samples: [Float], sessionID: UUID, index: Int, offset: Double) async throws -> TranscriptSegment {
        try await Task.sleep(for: .milliseconds(15))
        return .init(sessionID: sessionID, index: index, text: "Das ist ein kurzer Test.")
    }
}
private actor MetricsGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var parked: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { parked = $0 }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
    func release() { parked?.resume(); parked = nil }
}
private actor MetricsFormatter: TextFormatting {
    let usesModel: Bool
    let fails: Bool
    let gate: MetricsGate?
    private var calls = 0
    init(usesModel: Bool = true, fails: Bool = false, gate: MetricsGate? = nil) { self.usesModel = usesModel; self.fails = fails; self.gate = gate }
    func prepare() async throws {}
    func format(_ text: String, style: TextStyle, context: String, vocabulary: [String]) async throws -> String { text }
    func format(_ text: String, style: TextStyle, context: String, vocabulary: [String], onModelUse: @Sendable (FormattingModel) -> Void) async throws -> String {
        if usesModel {
            onModelUse(.qwen3)
            calls += 1
            if let gate, calls == 1 { await gate.pause() }
            else { try await Task.sleep(for: .milliseconds(15)) }
        }
        if fails { throw VoiceError.message("Synthetic formatter failure") }
        return text
    }
}

final class ProcessingMetricsTests: XCTestCase {
    func testRealLocalFormatterShortTextDoesNotReportModelUse() async throws {
        let measurement = ProcessingMeasurement()
        let formatter = MeasuredFormatter(base: LocalFormatter(modelURL: URL(fileURLWithPath: "/missing-test-model.gguf")), measurement: measurement)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        let text = "Das ist ein kurzer Test."
        let result = try await formatter.format(text, style: .cleaned, context: "", vocabulary: [])
        let metrics = measurement.snapshot(stoppedAt: stoppedAt, status: .notNeeded)
        XCTAssertEqual(result, text); XCTAssertEqual(metrics.optimizationStatus, .notNeeded)
        XCTAssertEqual(metrics.modelCalls, 0); XCTAssertNil(metrics.model); XCTAssertEqual(metrics.optimizationSeconds, 0)
    }
    func testPipelineMeasuresRecognitionAndActualModelCalls() async throws {
        let pipeline = ProcessingPipeline(speech: MetricsSpeech(), formatter: MetricsFormatter())
        try await pipeline.start(style: .cleaned)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        try await pipeline.append(samples: Array(repeating: 0.1, count: 16_000))
        let result = try await pipeline.finish(stoppedAt: stoppedAt)
        let metrics = try XCTUnwrap(result.processing)
        XCTAssertTrue(metrics.isValid); XCTAssertGreaterThan(metrics.recognitionSeconds, 0)
        XCTAssertGreaterThan(metrics.optimizationSeconds, 0)
        XCTAssertEqual(metrics.model, .qwen3); XCTAssertEqual(metrics.modelCalls, 1)
        XCTAssertEqual(metrics.optimizationStatus, .used); XCTAssertFalse(result.usedFallback)
    }
    func testAutomaticSkipAndOriginalStyleRemainDistinct() async throws {
        for style in [TextStyle.cleaned, .original] {
            let pipeline = ProcessingPipeline(speech: MetricsSpeech(), formatter: MetricsFormatter(usesModel: false))
            let result = try await pipeline.process(samples: Array(repeating: 0.1, count: 16_000), sessionID: UUID(), style: style)
            let metrics = try XCTUnwrap(result.processing)
            XCTAssertEqual(metrics.optimizationStatus, style == .original ? .originalStyle : .notNeeded)
            XCTAssertEqual(metrics.modelCalls, 0); XCTAssertEqual(metrics.optimizationSeconds, 0)
        }
    }
    func testManualOriginalAndFormatterFailureRemainDistinct() async throws {
        let gate = MetricsGate()
        let pipeline = ProcessingPipeline(speech: MetricsSpeech(), formatter: MetricsFormatter(gate: gate))
        try await pipeline.start(style: .cleaned)
        try await pipeline.append(samples: Array(repeating: 0.1, count: 16_000))
        let finish = Task { try await pipeline.finish() }
        await gate.waitForEntry(); await pipeline.requestOriginal()
        let result = try await finish.value
        let metrics = try XCTUnwrap(result.processing)
        XCTAssertEqual(result.text, result.original); XCTAssertEqual(metrics.optimizationStatus, .originalRequested)
        XCTAssertEqual(metrics.modelCalls, 1); XCTAssertTrue(metrics.isValid)
        await gate.release()
        let next = try await pipeline.process(samples: Array(repeating: 0.1, count: 16_000), sessionID: UUID(), style: .cleaned)
        XCTAssertEqual(next.processing?.optimizationStatus, .used); XCTAssertEqual(next.processing?.modelCalls, 1)
        let failed = ProcessingPipeline(speech: MetricsSpeech(), formatter: MetricsFormatter(fails: true))
        let fallback = try await failed.process(samples: Array(repeating: 0.1, count: 16_000), sessionID: UUID(), style: .cleaned)
        XCTAssertEqual(fallback.processing?.optimizationStatus, .fallback); XCTAssertTrue(fallback.usedFallback)
    }
    func testModelWorkDuringRecordingIsCountedWithoutInflatingStopWait() async throws {
        let measurement = ProcessingMeasurement()
        let id = measurement.begin(.optimization, model: .qwen3)
        measurement.end(id)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        let metrics = measurement.snapshot(stoppedAt: stoppedAt, status: .notNeeded)
        XCTAssertEqual(metrics.optimizationStatus, .used); XCTAssertEqual(metrics.modelCalls, 1)
        XCTAssertEqual(metrics.optimizationSeconds, 0); XCTAssertTrue(metrics.isValid)
    }
    func testStopWaitIncludesTailDeliveryBeforeFinish() async throws {
        let pipeline = ProcessingPipeline(speech: MetricsSpeech(), formatter: MetricsFormatter(usesModel: false))
        try await pipeline.start(style: .cleaned)
        try await pipeline.append(samples: Array(repeating: 0.1, count: 16_000))
        let result = try await pipeline.finish(stoppedAt: ProcessInfo.processInfo.systemUptime - 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(result.processing).totalSeconds, 0.5)
    }
    func testOverlappingStagesAreClippedToStopAndNotAddedTwice() async throws {
        let measurement = ProcessingMeasurement()
        let first = measurement.begin(.recognition), second = measurement.begin(.recognition)
        let optimization = measurement.begin(.optimization, model: .cloud)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(15))
        let metrics = measurement.snapshot(stoppedAt: stoppedAt, status: .notNeeded)
        measurement.end(first); measurement.end(second); measurement.end(optimization)
        XCTAssertEqual(metrics.recognitionSeconds, metrics.totalSeconds)
        XCTAssertEqual(metrics.optimizationSeconds, metrics.totalSeconds)
        XCTAssertTrue(metrics.isValid); XCTAssertEqual(metrics.model, .cloud)
    }
}
