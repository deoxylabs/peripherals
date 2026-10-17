import CoreGraphics
import Foundation
import ImageIO

typealias RGB = (r: Double, g: Double, b: Double)

/// The cover, one pixel per key, made to read on an LED.
///
/// Two failed versions are worth recording, because the fix is a balance. A
/// flat multiplier washed everything toward white: clipping one channel while
/// the others keep climbing is precisely how a colour desaturates. Stretching
/// brightness between the image's own percentiles went too far the other way,
/// turning a near-black brown into a plain purple. So: a gentle gamma that
/// lifts the low end, a saturation nudge only where there is light to carry
/// it, and nothing that maps the darkest part of an image to anything but dark.
enum ArtworkGrid {
    // NSCache is thread-safe; lighting reads it from its own queue.
    nonisolated(unsafe) private static let cache = NSCache<NSString, Box>()
    private final class Box { let grid: [[RGB]]; init(_ grid: [[RGB]]) { self.grid = grid } }

    static func grid(path: String, cols: Int, rows: Int) -> [[RGB]]? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(path)|\(cols)|\(rows)|\(modified)" as NSString
        if let hit = cache.object(forKey: key) { return hit.grid }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = sample(image, cols: cols, rows: rows) else { return nil }
        let grid = adjust(pixels)
        cache.setObject(Box(grid), forKey: key)
        return grid
    }

    /// A square cover squashed into a strip loses its composition, so the
    /// middle band is cropped at the device's own aspect instead.
    static func sample(_ image: CGImage, cols: Int, rows: Int) -> [[RGB]]? {
        let width = Double(image.width), height = Double(image.height)
        let want = Double(cols) / Double(rows)
        let crop: CGRect
        if width / height > want {
            let band = max(1, (height * want).rounded(.down))
            crop = CGRect(x: ((width - band) / 2).rounded(.down), y: 0, width: band, height: height)
        } else {
            let band = max(1, (width / want).rounded(.down))
            crop = CGRect(x: 0, y: ((height - band) / 2).rounded(.down), width: width, height: band)
        }
        guard let cropped = image.cropping(to: crop),
              let context = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: cols * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        // A bitmap context keeps the top of the image in its first row.
        return (0..<rows).map { y in
            (0..<cols).map { x in
                let i = (y * cols + x) * 4
                return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
            }
        }
    }

    /// How bright the cover is overall decides how much help it gets: a dark
    /// sleeve is lifted a little, a bright one left alone.
    static func adjust(_ pixels: [[RGB]]) -> [[RGB]] {
        let values = pixels.flatMap { $0 }.map { HSV(rgb: $0).v }.sorted()
        let typical = values[values.count / 2]
        let gamma = typical < 0.35 ? 0.75 : 0.9
        return pixels.map { row in
            row.map { pixel in
                var hsv = HSV(rgb: pixel)
                hsv.v = min(1, pow(hsv.v, gamma))
                // Only where there is already light to colour: boosting the
                // saturation of a near-black pixel is how brown became purple.
                hsv.s = min(1, hsv.s * (1 + 0.2 * hsv.v))
                return hsv.rgb
            }
        }
    }
}

/// Python's colorsys, so the colours match razerlight exactly.
struct HSV {
    var h: Double, s: Double, v: Double

    init(rgb: RGB) {
        let high = max(rgb.r, rgb.g, rgb.b), low = min(rgb.r, rgb.g, rgb.b)
        v = high
        guard high != low else { h = 0; s = 0; return }
        s = (high - low) / high
        let rc = (high - rgb.r) / (high - low)
        let gc = (high - rgb.g) / (high - low)
        let bc = (high - rgb.b) / (high - low)
        var hue: Double
        if rgb.r == high { hue = bc - gc } else if rgb.g == high { hue = 2 + rc - bc } else { hue = 4 + gc - rc }
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        h = hue < 0 ? hue + 1 : hue
    }

    var rgb: RGB {
        guard s != 0 else { return (v, v, v) }
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
