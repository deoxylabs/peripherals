import CoreGraphics
import Foundation

/// The keyboard's power-on animation: a spinning double helix that collapses
/// into the deoxy lockup. Slot 0's frames are the whole panel, 256x64, because
/// the dial's icon column isn't up yet when it plays.
enum BootAnimation {
    static let width = 256, height = 64
    static let fps = 25
    static let seconds = 3.2

    static func frames() -> [GreyImage] {
        (0..<Int(seconds * Double(fps))).map { frame(Double($0) / Double(fps)) }
    }

    private static func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }

    static func frame(_ t: Double) -> GreyImage {
        let canvas = Canvas(width: width, height: height)
        let context = canvas.context
        let w = Double(width), h = Double(height)
        let lockupHeight = 30.0
        let lockupWidth = Artwork.wordmark.map { Double($0.width) * lockupHeight / Double($0.height) } ?? 140

        let grow = ease(t / 0.5)                     // out from the centre
        let settle = ease((t - 1.3) / 0.8)           // contract into the mark
        let reveal = ease((t - 1.95) / 0.55)         // the lockup arrives

        let markLeft = (w - lockupWidth) / 2
        let markWidth = lockupHeight * 0.62          // roughly where the helix mark sits
        let centre = w / 2 * (1 - settle) + (markLeft + markWidth / 2) * settle
        let half = (w / 2 - 12) * grow * (1 - settle) + markWidth / 2 * settle
        let amplitude = 18 * (1 - settle) + lockupHeight * 0.38 * settle
        let wave = 56 * (1 - settle) + markWidth * 1.1 * settle
        let phase = t * 2 * Double.pi * 0.9
        let fade = 1 - reveal

        if fade > 0.01, half > 0.25 {
            var segments: [(depth: Double, from: CGPoint, to: CGPoint, width: Double)] = []
            var x = centre - half
            while x < centre + half {
                for strand in [0, Double.pi] {
                    let a0 = 2 * Double.pi * (x - centre) / wave + phase + strand
                    let a1 = a0 + 2 * Double.pi * 0.25 / wave
                    segments.append((cos(a0), CGPoint(x: x, y: h / 2 + amplitude * sin(a0)),
                                     CGPoint(x: x + 0.25, y: h / 2 + amplitude * sin(a1)), 3))
                }
                x += 0.25
            }
            // Base pairs, a rung every eighth of a turn.
            let rung = wave / 8
            var k = (centre - half) / rung
            k.round(.up)
            while k * rung < centre + half {
                let x = k * rung
                let a = 2 * Double.pi * (x - centre) / wave + phase
                segments.append((-0.6 + 0.2 * cos(a), CGPoint(x: x, y: h / 2 + amplitude * sin(a)),
                                 CGPoint(x: x, y: h / 2 - amplitude * sin(a)), 1.5))
                k += 1
            }
            // Back to front, so the near strand passes over the far one.
            context.setLineCap(.round)
            for segment in segments.sorted(by: { $0.depth < $1.depth }) {
                let edge = min(1, (segment.from.x - (centre - half)) / 8, ((centre + half) - segment.from.x) / 8)
                let level = (0.3 + 0.7 * (segment.depth + 1) / 2) * max(0, edge) * fade
                context.setStrokeColor(gray: level, alpha: 1)
                context.setLineWidth(segment.width)
                context.strokeLineSegments(between: [segment.from, segment.to])
            }
        }

        if reveal > 0, let mark = Artwork.wordmark {
            // Added by brightness, so the logo grows out of the helix rather
            // than cutting dark holes through it.
            context.setBlendMode(.lighten)
            canvas.fill(mask: mark, in: CGRect(x: markLeft, y: (h - lockupHeight) / 2,
                                               width: lockupWidth, height: lockupHeight), grey: reveal)
            context.setBlendMode(.normal)
        }
        return canvas.image
    }
}
