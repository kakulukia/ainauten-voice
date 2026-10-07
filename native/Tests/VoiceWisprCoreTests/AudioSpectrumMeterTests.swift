import XCTest
@testable import VoiceWisprCore

final class AudioSpectrumMeterTests: XCTestCase {
    private func tone(_ frequency: Double, amplitude: Float = 0.025) -> [Float] {
        (0..<512).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / 16_000)) }
    }

    func testEqualVolumeTonesDriveDifferentFrequencyBands() {
        for (frequency, band) in [(125.0, 0), (750.0, 4), (3000.0, 7)] {
            let levels = AudioSpectrumMeter().levels(for: tone(frequency))
            XCTAssertEqual(levels.count, 9)
            XCTAssertEqual(levels.firstIndex(of: levels.max()!), band)
            XCTAssertGreaterThan(levels[band], 0.65)
            XCTAssertLessThan(levels[(band + 4) % 9], 0.1)
        }
    }

    func testQuietTonesHaveVisiblePeaksWithoutSaturating() {
        let levels = AudioSpectrumMeter().levels(for: tone(750, amplitude: 0.005))
        XCTAssertGreaterThan(levels[4], 0.35)
        XCTAssertLessThan(levels[4], 0.8)
    }

    func testMixedTonesShowSeparateLowAndHighPeaks() {
        let samples = zip(tone(125), tone(3000)).map(+)
        let levels = AudioSpectrumMeter().levels(for: samples)
        XCTAssertGreaterThan(levels[0], 0.65)
        XCTAssertGreaterThan(levels[7], 0.65)
        XCTAssertLessThan(levels[4], 0.1)
    }

    func testSmallCallbacksMatchACompleteAudioWindow() {
        let samples = tone(750)
        let meter = AudioSpectrumMeter()
        var levels: [Float] = []
        for start in stride(from: 0, to: 512, by: 128) {
            levels = meter.levels(for: Array(samples[start..<start + 128]))
        }
        XCTAssertEqual(levels, AudioSpectrumMeter().levels(for: samples))
    }

    func testSilenceEmptyAndInvalidSamplesStayFiniteAndBounded() {
        let meter = AudioSpectrumMeter()
        _ = meter.levels(for: tone(750))
        for samples: [Float] in [[Float](repeating: 0, count: 512), [], [.nan, .infinity, -.infinity]] {
            let levels = meter.levels(for: samples)
            XCTAssertEqual(levels, [Float](repeating: 0, count: 9))
        }
        XCTAssertTrue(meter.levels(for: tone(750, amplitude: 1)).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }
}
