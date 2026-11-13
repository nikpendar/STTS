import Accelerate
import AudioToolbox
import CoreMotion
import UIKit

/// The row of word suggestions above the keys: three slots, read right to left, with thin
/// dividers between them as on the system keyboard.
/// A label with room around its text, for the highlight behind a corrected word.
final class PaddedLabel: UILabel {
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(size)
        return CGSize(width: fitted.width + 16, height: fitted.height + 6)
    }
}

final class SuggestionBar: UIView {
    struct Item {
        let text: String
        /// The typed word itself, shown in quotes; picking it teaches it to the lexicon.
        var literal = false
        /// A reading of the last glide, which replaces the glided word.
        var replacesGlide = false
        /// A typed shortcut's text: not taught to the lexicon.
        var shortcut = false
    }

    var onPick: ((Item) -> Void)?
    /// The mic at the bar's right end (`KeyboardOptions.dictationButton`).
    var onMic: (() -> Void)?
    enum MicLook { case off, waiting, ready, recording, busy }
    var showsMic = false {
        didSet {
            guard showsMic != oldValue else { return }
            mic.isHidden = !showsMic
            setNeedsLayout()
        }
    }
    var micLook = MicLook.ready {
        didSet { if micLook != oldValue { applyMicLook() } }
    }
    private let mic = UIButton(type: .system)
    private static let micWidth: CGFloat = 38
    var textColor = UIColor.label {
        didSet {
            slots.forEach { $0.setTitleColor(textColor, for: .normal) }
            applyMicLook()
        }
    }
    /// Follows the letters' size setting: 19 points at the standard 23.
    var fontSize: CGFloat = 19 {
        didSet { if fontSize != oldValue { show(items) } }
    }
    private var slots: [UIButton] = []
    private var dividers: [UIView] = []
    /// Right, middle, left.
    private var items: [Item?] = [nil, nil, nil]

    override init(frame: CGRect) {
        super.init(frame: frame)
        for index in 0..<3 {
            let slot = UIButton(type: .custom)
            slot.titleLabel?.font = AppFont.font(ofSize: 19)
            slot.titleLabel?.adjustsFontSizeToFitWidth = true
            slot.titleLabel?.minimumScaleFactor = 0.6
            slot.titleLabel?.lineBreakMode = .byClipping
            slot.setTitleColor(textColor, for: .normal)
            slot.accessibilityIdentifier = "suggestion-\(index)"
            slot.addAction(UIAction { [weak self] _ in
                guard let item = self?.items[index] else { return }
                self?.onPick?(item)
            }, for: .touchUpInside)
            slots.append(slot)
            addSubview(slot)
        }
        for _ in 0..<2 {
            let divider = UIView()
            divider.backgroundColor = UIColor.label.withAlphaComponent(0.18)
            dividers.append(divider)
            addSubview(divider)
        }
        mic.isHidden = true
        mic.accessibilityIdentifier = "barMic"
        mic.addAction(UIAction { [weak self] _ in self?.onMic?() }, for: .touchUpInside)
        addSubview(mic)
        applyMicLook()
    }

    /// Orange and beating while it records, dim while the text is being finished, crossed out
    /// with no voice typing on in the app.
    private func applyMicLook() {
        let symbol: String
        var tint = textColor
        switch micLook {
        case .off: symbol = "mic.slash"; tint = textColor.withAlphaComponent(0.45)
        case .waiting: symbol = "mic"; tint = textColor.withAlphaComponent(0.6)
        case .ready: symbol = "mic.fill"
        case .recording: symbol = "mic.fill"; tint = .systemOrange
        case .busy: symbol = "mic.fill"; tint = UIColor.systemOrange.withAlphaComponent(0.5)
        }
        mic.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)),
                     for: .normal)
        mic.tintColor = tint
        mic.accessibilityLabel = micLook == .recording ? "پایان تایپ صوتی" : "تایپ صوتی"
        mic.layer.removeAnimation(forKey: "beat")
        guard micLook == .recording, !UIAccessibility.isReduceMotionEnabled else { return }
        let beat = CABasicAnimation(keyPath: "transform.scale")
        beat.fromValue = 1
        beat.toValue = 1.18
        beat.duration = 0.55
        beat.autoreverses = true
        beat.repeatCount = .infinity
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mic.layer.add(beat, forKey: "beat")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var flash: UILabel?

    /// A word just corrected, on a solid yellow highlight, falls into the middle of the bar and
    /// stays a moment while the suggestions step aside; the host's text cannot be marked by a
    /// keyboard, so the bar shows it instead.
    func flashCorrection(_ word: String) {
        flash?.removeFromSuperview()
        let label = PaddedLabel()
        label.text = word
        label.font = keyFont(for: word, size: fontSize)
        label.textColor = .black
        label.backgroundColor = UIColor(red: 1, green: 0.84, blue: 0.24, alpha: 1)
        label.layer.cornerRadius = 8
        label.layer.cornerCurve = .continuous
        label.layer.masksToBounds = true
        label.textAlignment = .center
        let size = label.sizeThatFits(bounds.size)
        let width = min(bounds.width * 0.6, size.width)
        let height = min(bounds.height - 4, size.height)
        label.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        addSubview(label)
        flash = label
        slots.forEach { $0.isHidden = true }
        dividers.forEach { $0.alpha = 0 }
        label.alpha = 0
        label.transform = CGAffineTransform(translationX: 0, y: -bounds.height * 0.7).scaledBy(x: 1.15, y: 1.15)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.8) {
            label.alpha = 1
            label.transform = .identity
        }
        UIView.animate(withDuration: 0.25, delay: 1.3, options: [.beginFromCurrentState, .allowUserInteraction]) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
            guard self.flash === label else { return }
            self.flash = nil
            self.slots.forEach { $0.isHidden = false }
            self.dividers.forEach { $0.alpha = 1 }
        }
    }

    /// Items right to left; nil leaves a slot empty.
    func show(_ items: [Item?]) {
        self.items = (items + [nil, nil, nil]).prefix(3).map { $0 }
        for (slot, item) in zip(slots, self.items) {
            slot.setTitle(item.map { $0.literal ? "«\($0.text)»" : $0.text }, for: .normal)
            slot.titleLabel?.font = keyFont(for: item?.text, size: fontSize)
            slot.isEnabled = item != nil
        }
        let filled = self.items.compactMap { $0 }.count
        dividers.forEach { $0.isHidden = filled < 2 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The mic, when shown, keeps the right end; the three slots share the rest.
        let micWidth = showsMic ? Self.micWidth : 0
        mic.frame = CGRect(x: bounds.width - micWidth, y: 0, width: micWidth, height: bounds.height)
        let room = bounds.width - micWidth
        let width = room / 3
        // Slot 0 is on the right.
        for (index, slot) in slots.enumerated() {
            slot.frame = CGRect(x: room - CGFloat(index + 1) * width, y: 0, width: width, height: bounds.height)
                .insetBy(dx: 6, dy: 0)
        }
        for (index, divider) in dividers.enumerated() {
            divider.frame = CGRect(x: CGFloat(index + 1) * width - 0.5, y: bounds.height * 0.25,
                                   width: 1, height: bounds.height * 0.5)
        }
    }
}
