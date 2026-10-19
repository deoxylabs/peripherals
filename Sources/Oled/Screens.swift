import AppKit
import CoreText

/// What goes on the OLED: the now-playing frame, the clock's backgrounds, and
/// the bytes that tell the firmware how to lay the clock out.
enum Screens {
    static let width = 232          // the home screen; the right 24 px are the dial's icons
    static let height = 64

    struct Track: Equatable, Sendable {
        var id: String
        var name: String
        var artist: String
        var album: String
    }

    /// The cover's own glow across the panel, the cover sharp on the left,
    /// then title, artist and album as Music has them. `backdrop` is `Artwork.ambient`'s.
    static func nowPlaying(_ track: Track, backdrop: GreyImage?) -> GreyImage {
        let canvas = Canvas(width: width, height: height)
        if let backdrop { canvas.paste(backdrop, x: 0, y: 0) }
        let left: CGFloat = 68
        let room = CGFloat(width) - left - 4
        let (title, titleFont) = Typeface.fit(track.name, sizes: [16, 15, 14], weight: .bold, grey: 1, width: room)
        let (artist, artistFont) = Typeface.fit(track.artist, sizes: [12, 11, 10], weight: .medium, grey: 200 / 255, width: room)
        canvas.text(title, x: left, top: 8, font: titleFont)
        canvas.text(artist, x: left, top: 28, font: artistFont)
        if !track.album.isEmpty, track.album != track.name {
            let (album, albumFont) = Typeface.fit(track.album, sizes: [10], weight: .regular, grey: 150 / 255, width: room)
            canvas.text(album, x: left, top: 45, font: albumFont)
        }
        return canvas.image
    }

    // MARK: - The clock

    /// The firmware draws the live items itself; these say where, on each of
    /// the three slides it rotates through. Each slide nudges everything a few
    /// pixels so nothing stays lit in one place. Its digits advance 12 px, so
    /// "12:59 PM" runs about 84 px wide.
    struct Slide: Sendable {
        let time: (x: UInt8, y: UInt8)
        let value: (x: UInt8, y: UInt8)
        let item: UInt8               // 1 CPU, 5 memory
        let label: String
        let shift: (x: Int, y: Int)   // for the wordmark
    }

    static let slides = [
        Slide(time: (8, 10), value: (150, 10), item: 1, label: "CPU", shift: (0, 0)),
        Slide(time: (14, 14), value: (156, 14), item: 5, label: "MEM", shift: (6, 4)),
        Slide(time: (11, 7), value: (153, 7), item: 1, label: "CPU", shift: (3, -3)),
    ]
    static let timeItem: UInt8 = 7

    /// Behind the live digits: the date under the time, a label under the
    /// value, and the wordmark in the corner.
    static func clockBackground(_ slide: Slide, date: Date) -> GreyImage {
        let canvas = Canvas(width: width, height: height)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "EEE d MMM"
        let dateFont = Typeface.font(11, .medium)
        canvas.text(Typeface.line(format.string(from: date), dateFont, grey: 150 / 255),
                    x: CGFloat(slide.time.x), top: CGFloat(slide.time.y) + 24, font: dateFont)
        let labelFont = Typeface.font(9, .semibold)
        canvas.text(Typeface.line(slide.label, labelFont, grey: 110 / 255),
                    x: CGFloat(slide.value.x), top: CGFloat(slide.value.y) + 24, font: labelFont)
        if let mark = Artwork.wordmark {
            let markHeight: CGFloat = 9
            let markWidth = (CGFloat(mark.width) * markHeight / CGFloat(mark.height)).rounded()
            let rect = CGRect(x: CGFloat(width) - markWidth - 8 + CGFloat(slide.shift.x),
                              y: CGFloat(height) - markHeight - 6 + CGFloat(slide.shift.y),
                              width: markWidth, height: markHeight)
            canvas.fill(mask: mark, in: rect, grey: 110 / 255)
        }
        return canvas.image
    }

    /// Home type 6's parameters: the items on each slide, seconds per slide,
    /// then each slide's label positions.
    static var clockRecord: [UInt8] {
        var record: [UInt8] = [6]
        record += slides.map { timeItem << 4 | $0.item }
        record += [5, 0, 0]
        for slide in slides {
            record += [slide.time.x, slide.time.y, slide.value.x, slide.value.y]
        }
        return record
    }

    /// The 40-byte live buffer: eight fixed 5-byte slots, item N at (N-1)*5.
    /// The firmware reads them by position, so the order of the items matters
    /// and nothing can be packed together.
    static func liveValues(hour: Int, minute: Int, second: Int, cpu: Int, memory: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 40)
        buffer[0...1] = [1, UInt8(clamping: cpu)]
        buffer[20...21] = [5, UInt8(clamping: memory)]
        buffer[30...34] = [timeItem, UInt8(hour % 12 == 0 ? 12 : hour % 12), UInt8(minute), UInt8(second),
                           hour >= 12 ? 1 : 0]
        return buffer
    }
}
