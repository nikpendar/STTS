import UIKit

/// Heights of the suggestion bar, the letter rows and the number row in one orientation. They
/// are worked out the first time the keyboard runs after install, for both orientations, and
/// kept from then on, so the keys are the same size in every app whatever height iOS offers.
struct KeyboardMetrics: Codable, Equatable {
    var bar: CGFloat
    var row: CGFloat
    var numberRow: CGFloat

    /// Bump when the measurements change, so installed keyboards work them out again.
    private static let version = 2

    /// The kept metrics, saved on first use (deleting the app deletes them).
    static func saved(landscape: Bool) -> KeyboardMetrics {
        let key = "keyboardMetrics.v\(version).\(landscape ? "landscape" : "portrait")"
        if let data = UserDefaults.standard.data(forKey: key),
           let metrics = try? JSONDecoder().decode(KeyboardMetrics.self, from: data) {
            return metrics
        }
        let metrics = measure(landscape: landscape)
        if let data = try? JSONEncoder().encode(metrics) { UserDefaults.standard.set(data, forKey: key) }
        return metrics
    }

    /// The system keyboard's sizes on this iPhone, from the screen alone (the same in every app):
    /// - rows: 54 points apart on iPhones up to 393 points wide (SE, 11 Pro, 16), 56 on the
    ///   wider ones (11, Plus, Pro Max), as measured in the iOS simulator (ios-keyboard.yml on
    ///   the ios-ref branch); the simulator's keyboard stays upright, so landscape takes 40;
    /// - suggestion bar: 38, 32 in landscape (44 looked taller than the system's on the phone);
    /// - number row: keys as tall as they are wide, never flatter, at most a letter row.
    static func measure(landscape: Bool) -> KeyboardMetrics {
        let screen = UIScreen.main.bounds.size
        let short = min(screen.width, screen.height)
        let long = max(screen.width, screen.height)
        let row: CGFloat = landscape ? 40 : (short >= 414 ? 56 : 54)
        // KeyView draws 2.5 points in from each side and a tenth of the height (at least 3)
        // from the top and the bottom. In landscape the keys are far wider than the row is
        // tall, so the notch's safe area does not change the result.
        let face = (landscape ? long : short) / 10 - 5
        let numberRow = min(row, max(face / 0.8, face + 6).rounded(.up))
        return KeyboardMetrics(bar: landscape ? 32 : 38, row: row, numberRow: numberRow)
    }
}
