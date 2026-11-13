import AppKit

enum StatusSpectrum {
    static func image(levels: [Float]) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let bars = stride(from: 0, to: levels.count, by: 2).map { index in
            levels[index..<min(index + 2, levels.count)].max() ?? 0
        }
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, level) in bars.enumerated() {
                let height = CGFloat(2 + 12 * level)
                let rect = NSRect(x: 1 + CGFloat(index) * 3.5, y: (size.height - height) / 2,
                                  width: 2, height: height)
                NSColor.black.withAlphaComponent(CGFloat(0.6 + 0.4 * level)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
