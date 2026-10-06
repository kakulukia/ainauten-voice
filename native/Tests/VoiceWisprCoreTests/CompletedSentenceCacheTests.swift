import XCTest
@testable import VoiceWisprCore

private actor CompletedSentenceGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var parked: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        observers.forEach { $0.resume() }; observers = []
        await withCheckedContinuation { parked = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { parked?.resume(); parked = nil }
}

private actor CompletedSentenceSpeech: SpeechTranscribing, SpeechSessionReconciling {
    private let sections: [String]
    private let final: String?
    private let gate: CompletedSentenceGate?
    private let gatedIndex: Int?
    private var recognized: [UUID: [Int: String]] = [:]
    init(_ sections: [String], final: String? = nil, gate: CompletedSentenceGate? = nil,
         gatedIndex: Int? = nil) {
        self.sections = sections; self.final = final
        self.gate = gate; self.gatedIndex = gatedIndex
    }
    func prepare() async throws {}
    func transcribe(samples: [Float], sessionID: UUID, index: Int, offset: Double) async throws -> TranscriptSegment {
        // This worker deliberately ignores cancellation to exercise the session fence.
        if index == gatedIndex, let gate { await gate.pause() }
        let text = sections.indices.contains(index) ? sections[index] : ""
        recognized[sessionID, default: [:]][index] = text
        let middle = offset + Double(samples.count) / 32_000
        let words = text.split(whereSeparator: \.isWhitespace).map {
            TranscriptWord(text: String($0), start: middle, end: middle + 0.001)
        }
        return .init(sessionID: sessionID, index: index, text: text, words: words)
    }
    func reconcile(samples: [Float], sessionID: UUID) async throws -> TranscriptSegment {
        let recorded = recognized[sessionID] ?? [:]
        let text = final ?? recorded.keys.sorted().compactMap { recorded[$0] }.joined(separator: " ")
        return .init(sessionID: sessionID, index: 0, text: text)
    }
}

private actor CompletedSentenceFormatter: TextFormatting {
    private let gate: CompletedSentenceGate?
    private let gatedCall: Int
    private let failingCall: Int?
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var inputs: [String] = []
    private(set) var contexts: [String] = []
    init(gate: CompletedSentenceGate? = nil, gatedCall: Int = 2, failingCall: Int? = nil) {
        self.gate = gate; self.gatedCall = gatedCall; self.failingCall = failingCall
    }
    func prepare() async throws {}
    func format(_ text: String, style: TextStyle, context: String, vocabulary: [String]) async throws -> String {
        inputs.append(text); contexts.append(context)
        let call = inputs.count
        let ready = observers.filter { call >= $0.0 }
        observers.removeAll { call >= $0.0 }
        ready.forEach { $0.1.resume() }
        // Only one call waits, so a new session can complete before the stale call returns.
        if call == gatedCall, let gate { await gate.pause() }
        if call == failingCall { throw VoiceError.message("Synthetic continuation failure") }
        return text.replacingOccurrences(of: "Form. Bringen", with: "Form bringen")
    }
    func waitForCalls(_ count: Int) async {
        if inputs.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
}

final class CompletedSentenceCacheTests: XCTestCase {
    private let completed = "Der erste Satz bleibt sicher erhalten."
    private let open = "Das Ganze in eine saubere Form."
    private let next = "Bringen und als Goal definieren lassen."
    private func pipeline(_ speech: CompletedSentenceSpeech, _ formatter: CompletedSentenceFormatter,
                          coreSamples: Int = 16_000) -> ProcessingPipeline {
        ProcessingPipeline(speech: speech, formatter: formatter, coreSamples: coreSamples,
                           overlapSamples: 0, preserveCompletedSentences: true)
    }
    func testStreamingKeepsCompletedSentenceOutOfNextCallAndRepairsTheOpenBoundary() async throws {
        let first = completed + " " + open
        let speech = CompletedSentenceSpeech([first, next])
        let formatter = CompletedSentenceFormatter()
        let pipeline = pipeline(speech, formatter)
        try await pipeline.start(style: .cleaned)
        try await pipeline.append(samples: [Float](repeating: 0.1, count: 16_000))
        await formatter.waitForCalls(1)
        let beforeStop = await formatter.inputs
        XCTAssertEqual(beforeStop.count, 1)
        XCTAssertEqual(beforeStop[0].trimmingCharacters(in: .whitespacesAndNewlines), first)
        try await pipeline.append(samples: [Float](repeating: 0.1, count: 16_000))
        let result = try await pipeline.finish()
        let inputs = await formatter.inputs
        XCTAssertEqual(inputs.count, 2)
        XCTAssertFalse(inputs[1].contains(completed))
        XCTAssertEqual(inputs[1], open + " " + next)
        XCTAssertEqual(result.text, completed + " Das Ganze in eine saubere Form bringen und als Goal definieren lassen.")
        XCTAssertEqual(result.original, first + " " + next)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.processing?.modelCalls, 2)
        XCTAssertEqual(result.processing?.optimizationStatus, .used)
    }
    func testSingleSentenceStillReopensAndDefaultStillAllowsTwoSentences() throws {
        let single = try XCTUnwrap(FormattingWindow.continuation(previous: .init(input: open, output: open, formatted: true), next: next, maximumSentences: 1))
        XCTAssertEqual(single.input, open + " " + next)
        XCTAssertEqual(single.prefixOutput, "")
        let first = completed + " " + open
        let reduced = try XCTUnwrap(FormattingWindow.continuation(previous: .init(input: first, output: first, formatted: true), next: next, maximumSentences: 1))
        XCTAssertEqual(reduced.prefixOutput.trimmingCharacters(in: .whitespacesAndNewlines), completed)
        XCTAssertEqual(reduced.input, open + " " + next)
        let legacy = try XCTUnwrap(FormattingWindow.continuation(previous: .init(input: first, output: first, formatted: true), next: next))
        XCTAssertEqual(legacy.prefixOutput, "")
        XCTAssertEqual(legacy.input, first + " " + next)
    }
    func testRevisionRendererReopensOnlyLastSentenceOfAnAlreadyRenderedPrefix() async throws {
        let second = "Der zweite Satz bleibt ebenfalls erhalten."
        let prefix = completed + " " + second + " " + open
        let target = prefix + " " + next
        let plan = FormattingRevision.Plan(pieces: [.reuse(prefix), .revise(" " + next)], reusedWords: prefix.split(whereSeparator: \.isWhitespace).count, revisedWords: next.split(whereSeparator: \.isWhitespace).count)
        let formatter = CompletedSentenceFormatter()
        let result = try await FormattingRevision.render(plan: plan, target: target, formatter: formatter, style: .cleaned, dictionary: DictionaryMatcher([]), preserveCompletedSentences: true)
        let inputs = await formatter.inputs
        XCTAssertEqual(inputs, [open + " " + next])
        XCTAssertTrue(result.0.hasPrefix(completed + " " + second))
        XCTAssertTrue(result.0.contains("Form bringen"))
        XCTAssertEqual(ProcessingPipeline.lexicalSequence(result.0), ProcessingPipeline.lexicalSequence(target))
        XCTAssertFalse(result.1)
    }
    func testFinalRecognitionCorrectionPreservesPrefixDictionaryAndNegation() async throws {
        let first = "Der bereits geprüfte erste Satz bleibt im gesamten Diktat unverändert erhalten."
        let provisional = first + " Bitte New York senden."
        let final = first + " Bitte New York nicht senden."
        let speech = CompletedSentenceSpeech([provisional, ""], final: final)
        let formatter = CompletedSentenceFormatter()
        let pipeline = pipeline(speech, formatter, coreSamples: 224_000)
        try await pipeline.start(style: .cleaned, dictionary: [.init(phrase: "New York", replacement: "NYC")])
        try await pipeline.append(samples: [Float](repeating: 0.1, count: 256_000))
        await formatter.waitForCalls(1)
        let result = try await pipeline.finish()
        let inputs = await formatter.inputs
        XCTAssertGreaterThan(inputs.count, 1)
        XCTAssertTrue(inputs.dropFirst().contains { $0.contains("nicht") && $0.contains("NYC") })
        XCTAssertFalse(inputs.dropFirst().contains { $0.contains(first) })
        XCTAssertTrue(result.text.hasPrefix(first))
        XCTAssertEqual(result.original, final)
        XCTAssertEqual(ProcessingPipeline.lexicalSequence(result.text), ProcessingPipeline.lexicalSequence(first + " Bitte NYC nicht senden."))
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.processing?.optimizationStatus, .used)
    }
    func testFailedContinuationKeepsCachedPrefixAndAllNewWordsWithFallbackMetric() async throws {
        let first = completed + " " + open
        let speech = CompletedSentenceSpeech([first, next])
        let formatter = CompletedSentenceFormatter(failingCall: 2)
        let pipeline = pipeline(speech, formatter)
        let result = try await pipeline.process(samples: [Float](repeating: 0.1, count: 32_000), sessionID: UUID(), style: .cleaned)
        let inputs = await formatter.inputs
        XCTAssertEqual(inputs.count, 2)
        XCTAssertFalse(inputs[1].contains(completed))
        XCTAssertEqual(ProcessingPipeline.lexicalSequence(result.text), ProcessingPipeline.lexicalSequence(first + " " + next))
        XCTAssertTrue(result.text.hasPrefix(completed))
        XCTAssertTrue(result.usedFallback)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.processing?.optimizationStatus, .fallback)
        XCTAssertEqual(result.processing?.modelCalls, 2)
    }
    func testRequestOriginalBeforeRecognitionReturnsKeepsDictionaryAndAvoidsModelCalls() async throws {
        let gate = CompletedSentenceGate()
        let speech = CompletedSentenceSpeech(["Bitte New York nicht senden."], gate: gate, gatedIndex: 0)
        let formatter = CompletedSentenceFormatter()
        let pipeline = pipeline(speech, formatter)
        try await pipeline.start(style: .cleaned, dictionary: [.init(phrase: "New York", replacement: "NYC")])
        try await pipeline.append(samples: [Float](repeating: 0.1, count: 16_000))
        await gate.waitForEntry()
        await pipeline.requestOriginal()
        await gate.release()
        let result = try await pipeline.finish()
        let inputs = await formatter.inputs
        XCTAssertEqual(inputs, [])
        XCTAssertEqual(result.text, "Bitte NYC nicht senden.")
        XCTAssertEqual(result.processing?.optimizationStatus, .originalRequested)
        XCTAssertEqual(result.processing?.modelCalls, 0)
    }
    func testRequestOriginalDuringContinuationRejectsLateResultAndAllowsNewSession() async throws {
        let gate = CompletedSentenceGate()
        let first = completed + " " + open
        let speech = CompletedSentenceSpeech([first, next])
        let formatter = CompletedSentenceFormatter(gate: gate)
        let pipeline = pipeline(speech, formatter)
        let finish = Task { try await pipeline.process(samples: [Float](repeating: 0.1, count: 32_000), sessionID: UUID(), style: .cleaned) }
        await gate.waitForEntry()
        await pipeline.requestOriginal()
        let result = try await finish.value
        XCTAssertEqual(result.text, first + " " + next)
        XCTAssertEqual(result.processing?.optimizationStatus, .originalRequested)
        XCTAssertEqual(result.processing?.modelCalls, 2)
        let nextID = UUID()
        let newResult = try await pipeline.process(samples: [Float](repeating: 0.1, count: 16_000), sessionID: nextID, style: .cleaned)
        XCTAssertEqual(newResult.id, nextID)
        XCTAssertEqual(newResult.text, first)
        XCTAssertEqual(newResult.processing?.modelCalls, 1)
        XCTAssertFalse(newResult.usedFallback)
        await gate.release()
    }
    func testCancelDuringContinuationCannotChangeANewSession() async throws {
        let gate = CompletedSentenceGate()
        let first = completed + " " + open
        let speech = CompletedSentenceSpeech([first, next])
        let formatter = CompletedSentenceFormatter(gate: gate)
        let pipeline = pipeline(speech, formatter)
        let old = Task { try await pipeline.process(samples: [Float](repeating: 0.1, count: 32_000), sessionID: UUID(), style: .cleaned) }
        await gate.waitForEntry()
        await pipeline.cancel()
        let nextID = UUID()
        let result = try await pipeline.process(samples: [Float](repeating: 0.1, count: 16_000), sessionID: nextID, style: .cleaned)
        XCTAssertEqual(result.id, nextID)
        XCTAssertEqual(result.text, first)
        XCTAssertEqual(result.processing?.modelCalls, 1)
        XCTAssertFalse(result.usedFallback)
        await gate.release()
        do { _ = try await old.value; XCTFail("A cancelled continuation cannot deliver") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testCancelWhileRecognitionRunsCannotReuseAnOldSentenceCache() async throws {
        let gate = CompletedSentenceGate()
        let first = completed + " " + open
        let speech = CompletedSentenceSpeech([first, "Alter zweiter Text."], gate: gate, gatedIndex: 1)
        let formatter = CompletedSentenceFormatter()
        let pipeline = pipeline(speech, formatter)
        let old = Task { try await pipeline.process(samples: [Float](repeating: 0.1, count: 32_000), sessionID: UUID(), style: .cleaned) }
        await gate.waitForEntry()
        await pipeline.cancel()
        let nextID = UUID()
        let result = try await pipeline.process(samples: [Float](repeating: 0.1, count: 16_000), sessionID: nextID, style: .cleaned)
        XCTAssertEqual(result.id, nextID)
        XCTAssertEqual(result.text, first)
        XCTAssertEqual(result.processing?.modelCalls, 1)
        await gate.release()
        do { _ = try await old.value; XCTFail("A cancelled recognition cannot deliver") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let inputs = await formatter.inputs
        XCTAssertFalse(inputs.contains { $0.contains("Alter zweiter Text") })
    }
    func testOriginalStyleStillAvoidsFormattingWithCompletedSentenceCachingEnabled() async throws {
        let first = completed + " " + open
        let speech = CompletedSentenceSpeech([first, next])
        let formatter = CompletedSentenceFormatter()
        let pipeline = pipeline(speech, formatter)
        let result = try await pipeline.process(samples: [Float](repeating: 0.1, count: 32_000), sessionID: UUID(), style: .original)
        let inputs = await formatter.inputs
        XCTAssertEqual(inputs, [])
        XCTAssertEqual(result.text.trimmingCharacters(in: .whitespacesAndNewlines), first + " " + next)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.processing?.optimizationStatus, .originalStyle)
    }
}
