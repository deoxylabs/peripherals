import AppKit
import CoreGraphics
import CoreText
import ImageIO

/// 8-bit greys, top row first. The display shows the top four bits of each.
struct GreyImage: Sendable, Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? [UInt8](repeating: 0, count: width * height)
    }

    /// Four bits a pixel, two to a byte, the LEFT pixel in the LOW nibble.
    /// The other way round looks almost right and is horrible.
    func packed() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(pixels.count / 2)
        for y in 0..<height {
            let row = y * width
            for x in stride(from: 0, to: width, by: 2) {
                let left = pixels[row + x] >> 4
                let right = x + 1 < width ? pixels[row + x + 1] >> 4 : 0
                out.append(right << 4 | left)
            }
        }
        return out
    }
}

/// A grey drawing surface addressed from the top left, like the panel.
final class Canvas {
    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
    }

    var image: GreyImage {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return GreyImage(width: width, height: height,
                         pixels: Array(UnsafeBufferPointer(start: data, count: width * height)))
    }

    /// Text with its ascender line at `top`, as Pillow places it, so layouts
    /// carried over from the Python prototypes land where they did there.
    func text(_ line: CTLine, x: CGFloat, top: CGFloat, font: CTFont) {
        context.textPosition = CGPoint(x: x, y: CGFloat(height) - top - CTFontGetAscent(font))
        CTLineDraw(line, context)
    }

    /// Fills `mask`'s shape at a grey level, scaled to `rect` (top-left origin).
    func fill(mask: CGImage, in rect: CGRect, grey: CGFloat) {
        let flipped = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
        context.saveGState()
        context.clip(to: flipped, mask: mask)
        context.setFillColor(gray: grey, alpha: 1)
        context.fill(flipped)
        context.restoreGState()
    }

    func paste(_ image: GreyImage, x: Int, y: Int) {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<image.height where y + row >= 0 && y + row < height {
            for column in 0..<image.width where x + column >= 0 && x + column < width {
                data[(y + row) * width + x + column] = image.pixels[row * image.width + column]
            }
        }
    }
}

enum Typeface {
    static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    }

    static func line(_ text: String, _ font: CTFont, grey: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: grey, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The largest size the text fits at, or the smallest with an ellipsis.
    static func fit(_ text: String, sizes: [CGFloat], weight: NSFont.Weight, grey: CGFloat,
                    width limit: CGFloat) -> (CTLine, CTFont) {
        for size in sizes {
            let font = font(size, weight)
            let line = line(text, font, grey: grey)
            if width(line) <= limit { return (line, font) }
        }
        let font = font(sizes.last!, weight)
        let token = line("…", font, grey: grey)
        let truncated = CTLineCreateTruncatedLine(line(text, font, grey: grey), Double(limit), .end, token)
        return (truncated ?? token, font)
    }
}

enum Artwork {
    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The cover in 16 greys: stretched so it uses the whole range (one per
    /// cent clipped at each end), then dithered to the levels the panel has.
    static func cover(_ data: Data, size: Int = 64) -> GreyImage? {
        guard let image = cgImage(data) else { return nil }
        let canvas = Canvas(width: size, height: size)
        canvas.context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var pixels = canvas.image.pixels.map(Float.init)
        autocontrast(&pixels, cutoff: 0.01)
        return GreyImage(width: size, height: size, pixels: dither(pixels, width: size, height: size))
    }

    static func autocontrast(_ pixels: inout [Float], cutoff: Float) {
        var histogram = [Int](repeating: 0, count: 256)
        for p in pixels { histogram[Int(p)] += 1 }
        let clip = Int(Float(pixels.count) * cutoff)
        var low = 0, high = 255, seen = 0
        while low < 255, seen + histogram[low] <= clip { seen += histogram[low]; low += 1 }
        seen = 0
        while high > 0, seen + histogram[high] <= clip { seen += histogram[high]; high -= 1 }
        guard high > low else { return }
        let scale = 255 / Float(high - low)
        for i in pixels.indices {
            pixels[i] = min(255, max(0, (pixels[i] - Float(low)) * scale))
        }
    }

    /// Floyd–Steinberg to the 16 levels the panel shows (0, 17, … 255).
    static func dither(_ input: [Float], width: Int, height: Int) -> [UInt8] {
        var p = input
        var out = [UInt8](repeating: 0, count: p.count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let level = min(15, max(0, (p[i] / 17).rounded()))
                let value = level * 17
                out[i] = UInt8(value)
                let error = p[i] - value
                if x + 1 < width { p[i + 1] += error * 7 / 16 }
                if y + 1 < height {
                    if x > 0 { p[i + width - 1] += error * 3 / 16 }
                    p[i + width] += error * 5 / 16
                    if x + 1 < width { p[i + width + 1] += error * 1 / 16 }
                }
            }
        }
        return out
    }

    /// An image's alpha as a grey CGImage, for use as a clip mask.
    static func alphaMask(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let rgba = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        rgba.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let source = rgba.data!.assumingMemoryBound(to: UInt8.self)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for i in 0..<alpha.count { alpha[i] = source[i * 4 + 3] }
        let provider = CGDataProvider(data: Data(alpha) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The deoxy lockup, white on clear, bundled from the brand folder.
    static let wordmark: CGImage? = {
        guard let url = Bundle.main.url(forResource: "deoxy-lockup-white", withExtension: "png"),
              let data = try? Data(contentsOf: url), let image = cgImage(data) else { return nil }
        return alphaMask(image)
    }()
}
