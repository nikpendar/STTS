import UIKit

/// Pictures behind the keyboard (`KeyStyle.backgroundImage`): presets drawn in code, which add
/// nothing to the download and fit any keyboard size, or the user's own photo. A free Apple ID
/// has no App Groups, so the photo reaches the keyboard as the settings do, on a named
/// pasteboard, and each side keeps a copy of its own.
enum KeyboardBackground {
    struct Preset: Identifiable {
        let id: String
        let name: String
    }

    static let presets: [Preset] = [
        Preset(id: "aurora", name: "شفق"),
        Preset(id: "sunset", name: "غروب"),
        Preset(id: "ocean", name: "دریا"),
        Preset(id: "night", name: "شب پرستاره"),
        Preset(id: "tile", name: "کاشی"),
        Preset(id: "pastel", name: "پاستل"),
    ]

    private static let photoPrefix = "photo:"
    static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.keyboardBackground")
    private static let jpegType = "public.jpeg"
    private static let idType = "public.utf8-plain-text"

    static func isPhoto(_ id: String) -> Bool { id.hasPrefix(photoPrefix) }

    /// The picture for `id`, drawn at `size` points for a preset; nil for a photo that has not
    /// reached this process.
    static func image(_ id: String, size: CGSize) -> UIImage? {
        if isPhoto(id) { return photo(id) }
        guard size.width > 0, size.height > 0, presets.contains(where: { $0.id == id }) else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(id, in: CGRect(origin: .zero, size: size), context.cgContext)
        }
    }

    /// A small copy for the settings page, kept once drawn.
    static func thumbnail(_ id: String) -> UIImage? {
        if let image = thumbnails[id] { return image }
        let image = image(id, size: CGSize(width: 90, height: 60))
        thumbnails[id] = image
        return image
    }
    private static var thumbnails: [String: UIImage] = [:]

    /// Whether light letters read better on the picture, by its average colour as the keyboard
    /// judges it; nil while a photo is missing.
    static func isDark(_ id: String) -> Bool? {
        guard let image = isPhoto(id) ? photo(id) : thumbnail(id) else { return nil }
        return luminance(averageColor(of: image)) < 0.5
    }

    static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// The picture's average colour, for the glide lens and the letters' colour.
    static func averageColor(of image: UIImage) -> UIColor {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cgImage = image.cgImage,
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return .gray }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = [0.0, 0.0, 0.0]
        for i in 0..<(side * side) {
            for c in 0..<3 { sum[c] += Double(pixels[4 * i + c]) }
        }
        let n = Double(side * side) * 255
        return UIColor(red: sum[0] / n, green: sum[1] / n, blue: sum[2] / n, alpha: 1)
    }

    // MARK: - Photo

    /// App side: crops the photo to a keyboard's shape (3:2, its middle), keeps it, hands it to
    /// the keyboard and returns its id.
    static func savePhoto(_ original: UIImage) -> String? {
        let pixels = CGSize(width: original.size.width * original.scale, height: original.size.height * original.scale)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let target = CGSize(width: 1500, height: 1000)
        let scale = max(target.width / pixels.width, target.height / pixels.height)
        let drawn = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let cropped = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            original.draw(in: CGRect(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2,
                                     width: drawn.width, height: drawn.height))
        }
        guard let data = cropped.jpegData(compressionQuality: 0.85) else { return nil }
        let id = photoPrefix + UUID().uuidString
        keep(data, id)
        handToKeyboard(id)
        return id
    }

    /// App side: puts the kept photo back on the pasteboard, which a reboot can clear.
    static func handToKeyboard(_ id: String?) {
        guard let id, isPhoto(id), let data = try? Data(contentsOf: file(for: id)) else { return }
        UIPasteboard(name: pasteboardName, create: true)?.setItems([[jpegType: data, idType: id]])
    }

    /// The photo from this process's copy, else from the pasteboard (keyboard side, with Full
    /// Access), which is then kept.
    private static func photo(_ id: String) -> UIImage? {
        if let cached = photoCache, cached.id == id { return cached.image }
        var image = UIImage(contentsOfFile: file(for: id).path)
        if image == nil, let board = UIPasteboard(name: pasteboardName, create: false),
           board.string == id, let data = board.data(forPasteboardType: jpegType) {
            image = UIImage(data: data)
            if image != nil { keep(data, id) }
        }
        if let image { photoCache = (id, image) }
        return image
    }
    private static var photoCache: (id: String, image: UIImage)?

    private static func file(for id: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = id.dropFirst(photoPrefix.count).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return folder.appendingPathComponent("keyboard-background-\(name).jpg")
    }

    /// Writes the photo and removes the ones it replaces.
    private static func keep(_ data: Data, _ id: String) {
        let url = file(for: id)
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where old.hasPrefix("keyboard-background-") && old != url.lastPathComponent {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Presets

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        UIColor(red: r, green: g, blue: b, alpha: a).cgColor
    }

    private static func linear(_ colors: [CGColor], in rect: CGRect, _ cg: CGContext,
                               from start: CGPoint? = nil, to end: CGPoint? = nil) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) else { return }
        cg.drawLinearGradient(gradient, start: start ?? CGPoint(x: rect.midX, y: rect.minY),
                              end: end ?? CGPoint(x: rect.midX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// A soft round glow of `color`, fading out at `radius`.
    private static func glow(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat,
                             at centre: CGPoint, radius: CGFloat, _ cg: CGContext) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [rgb(r, g, b, alpha), rgb(r, g, b, alpha * 0.4), rgb(r, g, b, 0)] as CFArray,
                                        locations: [0, 0.45, 1]) else { return }
        cg.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
    }

    /// The same stars every time.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 33) / CGFloat(UInt64(1) << 31)
        }
    }

    private static func draw(_ id: String, in rect: CGRect, _ cg: CGContext) {
        let w = rect.width, h = rect.height
        let span = max(w, h)
        switch id {
        case "aurora":
            linear([rgb(0.03, 0.05, 0.14), rgb(0.08, 0.06, 0.2)], in: rect, cg)
            glow(0.15, 0.9, 0.6, alpha: 0.55, at: CGPoint(x: w * 0.22, y: h * 0.25), radius: span * 0.45, cg)
            glow(0.1, 0.6, 0.95, alpha: 0.45, at: CGPoint(x: w * 0.72, y: h * 0.15), radius: span * 0.4, cg)
            glow(0.65, 0.3, 0.95, alpha: 0.5, at: CGPoint(x: w * 0.6, y: h * 0.95), radius: span * 0.45, cg)
        case "sunset":
            linear([rgb(0.93, 0.45, 0.25), rgb(0.75, 0.22, 0.4), rgb(0.25, 0.1, 0.38)], in: rect, cg)
            glow(1, 0.8, 0.5, alpha: 0.45, at: CGPoint(x: w * 0.75, y: h * 0.1), radius: span * 0.3, cg)
        case "ocean":
            linear([rgb(0.0, 0.45, 0.6), rgb(0.02, 0.12, 0.3)], in: rect, cg)
            glow(0.4, 0.85, 0.9, alpha: 0.3, at: CGPoint(x: w * 0.3, y: 0), radius: span * 0.5, cg)
            cg.setLineWidth(1.4)
            for line in 0..<9 {
                let y0 = h * (0.12 + 0.11 * CGFloat(line))
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: y0))
                for step in stride(from: CGFloat(0), through: w, by: 4) {
                    let phase = CGFloat(line) * 0.9
                    path.addLine(to: CGPoint(x: step, y: y0 + 6 * sin(step / w * 2 * .pi * 1.5 + phase)))
                }
                cg.addPath(path)
                cg.setStrokeColor(rgb(1, 1, 1, 0.05 + 0.012 * CGFloat(line)))
                cg.strokePath()
            }
        case "night":
            linear([rgb(0.02, 0.02, 0.1), rgb(0.1, 0.07, 0.24)], in: rect, cg)
            glow(0.45, 0.3, 0.8, alpha: 0.35, at: CGPoint(x: w * 0.85, y: h), radius: span * 0.45, cg)
            var random = Seeded(state: 1404)
            for _ in 0..<Int(w * h / 900) {
                let point = CGPoint(x: random.next() * w, y: random.next() * h)
                let radius = 0.35 + 1.1 * pow(random.next(), 3)
                cg.setFillColor(rgb(1, 1, 1, 0.35 + 0.6 * random.next()))
                cg.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
                if radius > 1.1 { glow(0.8, 0.85, 1, alpha: 0.35, at: point, radius: radius * 5, cg) }
            }
        case "tile":
            // Eight-pointed stars of Persian tilework, in turquoise and gold.
            linear([rgb(0.04, 0.24, 0.38), rgb(0.02, 0.13, 0.25)], in: rect, cg)
            let cell: CGFloat = 46
            cg.setLineWidth(1)
            for row in -1...Int(h / cell) + 1 {
                for column in -1...Int(w / cell) + 1 {
                    let centre = CGPoint(x: CGFloat(column) * cell + (row % 2 == 0 ? 0 : cell / 2), y: CGFloat(row) * cell * 0.87)
                    let star = CGMutablePath()
                    for i in 0..<16 {
                        let angle = CGFloat(i) * .pi / 8 - .pi / 2
                        let radius = i % 2 == 0 ? cell * 0.42 : cell * 0.27
                        let point = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
                        if i == 0 { star.move(to: point) } else { star.addLine(to: point) }
                    }
                    star.closeSubpath()
                    cg.addPath(star)
                    cg.setFillColor(rgb(0.1, 0.5, 0.62, 0.45))
                    cg.fillPath()
                    cg.addPath(star)
                    cg.setStrokeColor(rgb(0.9, 0.74, 0.38, 0.55))
                    cg.strokePath()
                    cg.setFillColor(rgb(0.9, 0.74, 0.38, 0.5))
                    cg.fillEllipse(in: CGRect(x: centre.x - 2.5, y: centre.y - 2.5, width: 5, height: 5))
                }
            }
            linear([rgb(0, 0, 0, 0.1), rgb(0, 0, 0, 0.4)], in: rect, cg)
        default:
            // "pastel": light, for dark letters.
            linear([rgb(0.99, 0.9, 0.93), rgb(0.88, 0.91, 1)], in: rect, cg)
            glow(1, 0.83, 0.7, alpha: 0.7, at: CGPoint(x: w * 0.15, y: h * 0.85), radius: span * 0.4, cg)
            glow(0.72, 0.95, 0.85, alpha: 0.7, at: CGPoint(x: w * 0.85, y: h * 0.2), radius: span * 0.4, cg)
        }
    }
}
