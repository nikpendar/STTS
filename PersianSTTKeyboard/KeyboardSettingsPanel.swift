import Accelerate
import AudioToolbox
import CoreMotion
import UIKit

extension KeyboardViewController {
    // MARK: - Settings panel

    /// Takes new options: the app's when the keyboard appears, or the settings panel's.
    func applyOptions(_ new: KeyboardOptions) {
        let old = options
        options = new
        handwritingPad?.pause = new.handwritingPause
        handwritingPad?.inkWidth = CGFloat(new.handwritingInkWidth)
        handwritingPad?.slides = new.handwritingSlide
        handwritingPad?.speed = new.handwritingSpeed
        if new.handwritingSize != old.handwritingSize, handwritingPad != nil { heightChanged() }
        handwritingPad?.inkColor = new.handwritingInk.map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
        if new.numberRow != old.numberRow || new.digitsOnLetters != old.digitsOnLetters { buildCharacterKeys() }
        if new.suggestionBar != old.suggestionBar {
            view.setNeedsLayout()
            updateSuggestions()
        }
        if new.numberRow != old.numberRow || new.suggestionBar != old.suggestionBar { heightChanged() }
        if new.tiltLetters != old.tiltLetters { updateTilt() }
    }
}

/// The keyboard's settings, opened from the emoji key's menu over the keys: the switches of the
/// app's keyboard page. Colours, the background picture and the dictionary stay in the app.
final class KeyboardSettingsPanel: UIView {
    var options = KeyboardOptions.standard {
        didSet { if options != oldValue { refresh() } }
    }
    var onChange: ((KeyboardOptions) -> Void)?
    var onClose: (() -> Void)?
    /// «بقیه‌ی تنظیمات در آواک», shown when the keyboard may open the app.
    var onOpenApp: (() -> Void)?
    var textColor = UIColor.label {
        didSet { applyColours() }
    }
    /// The keyboard's background, drawn solid under the panel.
    var fill = UIColor.systemBackground {
        didSet { applyColours() }
    }

    private struct Row {
        let title: String
        let key: WritableKeyPath<KeyboardOptions, Bool>
    }

    private static let sections: [(title: String, rows: [Row])] = [
        ("ردیف پیشنهاد", [Row(title: "نمایش ردیف پیشنهاد", key: \.suggestionBar),
                          Row(title: "پیش‌بینی کلمه‌ی بعدی", key: \.predictNextWord)]),
        ("اصلاح خودکار", [Row(title: "اصلاح غلط تایپی", key: \.correctTypos),
                          Row(title: "نیم‌فاصله‌ی خودکار", key: \.autoZWNJ),
                          Row(title: "دو فاصله: نقطه، سه فاصله: ویرگول", key: \.doubleSpacePunctuation)]),
        ("بازخورد کلیدها", [Row(title: "بزرگ‌نمایی حرف هنگام تایپ", key: \.keyPreview),
                            Row(title: "کلیدهای سه‌بعدی", key: \.tiltLetters),
                            Row(title: "صدای کلیدها", key: \.keySounds),
                            Row(title: "لرزش (هپتیک)", key: \.haptics)]),
        ("لمس", [Row(title: "یادگیری محل لمس", key: \.learnTouches)]),
    ]

    private let header = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let numbers = UISegmentedControl(items: ["خاموش", "ردیف جدا", "روی حروف"])
    private let handwritingSpeed = UISegmentedControl(items: KeyboardOptions.handwritingSpeedNames)
    private let appButton = UIButton(type: .system)
    /// The title's mark: a gear in a soft round tile, and a hairline under the title, so the
    /// title reads apart from the rows (Rooz, 2026-11-08).
    private let badge = UIView()
    private let badgeIcon = UIImageView(image: UIImage(systemName: "gearshape.fill",
                                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
    private let divider = UIView()
    /// A little taller than the keyboard's suggestion bar (Rooz, 2026-11-08).
    var headerHeight: CGFloat = 38 {
        didSet { if headerHeight != oldValue { setNeedsLayout() } }
    }
    private var switches: [(UISwitch, WritableKeyPath<KeyboardOptions, Bool>)] = []
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        semanticContentAttribute = .forceRightToLeft

        titleLabel.text = "تنظیمات کیبورد"
        // Larger, so it stands apart from the rows below it. The app's font has no bold face:
        // asking for bold handed back another font.
        titleLabel.font = AppFont.font(ofSize: 20)
        titleLabel.textAlignment = .right
        closeButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), for: .normal)
        closeButton.accessibilityLabel = "بستن تنظیمات"
        closeButton.accessibilityIdentifier = "settingsClose"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        badge.layer.cornerRadius = 8
        badge.layer.cornerCurve = .continuous
        badgeIcon.contentMode = .center
        badge.addSubview(badgeIcon)
        header.addSubview(badge)
        header.addSubview(titleLabel)
        header.addSubview(closeButton)
        header.addSubview(divider)
        addSubview(header)

        stack.axis = .vertical
        stack.spacing = 2
        stack.semanticContentAttribute = .forceRightToLeft
        scroll.addSubview(stack)
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        addSubview(scroll)

        for section in Self.sections {
            addSectionTitle(section.title)
            for row in section.rows { addSwitch(row) }
            if section.title == "ردیف پیشنهاد" { addNumbers() }
        }
        handwritingSpeed.semanticContentAttribute = .forceRightToLeft
        handwritingSpeed.setTitleTextAttributes([.font: AppFont.font(ofSize: 13)], for: .normal)
        handwritingSpeed.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.options.handwritingSpeed = Double(self.handwritingSpeed.selectedSegmentIndex) / 2
            self.onChange?(self.options)
        }, for: .valueChanged)
        addSectionTitle("سرعت دست‌خط")
        stack.addArrangedSubview(handwritingSpeed)
        let note = makeLabel("رنگ‌ها، تصویر زمینه، قلم دست‌خط و واژه‌نامه در برنامه‌ی آواک.", size: 13, secondary: true)
        note.numberOfLines = 0
        stack.addArrangedSubview(note)
        if DictationBridge.keyboardOpensApp {
            var config = UIButton.Configuration.bordered()
            config.cornerStyle = .capsule
            config.image = UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
            config.imagePadding = 6
            config.attributedTitle = AttributedString("بقیه‌ی تنظیمات در آواک",
                                                      attributes: AttributeContainer([.font: AppFont.font(ofSize: 15)]))
            appButton.configuration = config
            appButton.semanticContentAttribute = .forceRightToLeft
            appButton.accessibilityIdentifier = "settingsOpenApp"
            appButton.addAction(UIAction { [weak self] _ in self?.onOpenApp?() }, for: .touchUpInside)
            appButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
            stack.setCustomSpacing(10, after: note)
            stack.addArrangedSubview(appButton)
        }
        refresh()
        applyColours()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeLabel(_ text: String, size: CGFloat, secondary: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = AppFont.font(ofSize: size)
        label.textAlignment = .right
        label.tag = secondary ? 1 : 0
        labels.append(label)
        return label
    }

    private func addSectionTitle(_ text: String) {
        let label = makeLabel(text, size: 13, secondary: true)
        let box = UIView()
        box.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        stack.addArrangedSubview(box)
    }

    private func row(_ label: UILabel, _ control: UIView) -> UIStackView {
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.semanticContentAttribute = .forceRightToLeft
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func addSwitch(_ item: Row) {
        let toggle = UISwitch()
        toggle.accessibilityLabel = item.title
        let key = item.key
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            self.options[keyPath: key] = toggle.isOn
            self.onChange?(self.options)
        }, for: .valueChanged)
        switches.append((toggle, key))
        stack.addArrangedSubview(row(makeLabel(item.title, size: 16), toggle))
    }

    /// The number row's three places, as the app's picker.
    private func addNumbers() {
        numbers.semanticContentAttribute = .forceRightToLeft
        numbers.setTitleTextAttributes([.font: AppFont.font(ofSize: 13)], for: .normal)
        numbers.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let place = self.numbers.selectedSegmentIndex
            self.options.numberRow = place == 1
            self.options.digitsOnLetters = place == 2
            self.onChange?(self.options)
        }, for: .valueChanged)
        addSectionTitle("اعداد")
        stack.addArrangedSubview(numbers)
    }

    private func refresh() {
        for (toggle, key) in switches { toggle.isOn = options[keyPath: key] }
        numbers.selectedSegmentIndex = options.digitsOnLetters ? 2 : options.numberRow ? 1 : 0
        handwritingSpeed.selectedSegmentIndex = Int((max(0, min(1, options.handwritingSpeed)) * 2).rounded())
        if let predict = switches.first(where: { $0.1 == \KeyboardOptions.predictNextWord })?.0 {
            predict.isEnabled = options.suggestionBar
        }
    }

    private func applyColours() {
        for label in labels {
            label.textColor = label.tag == 1 ? textColor.withAlphaComponent(0.6) : textColor
        }
        titleLabel.textColor = textColor
        badge.backgroundColor = textColor.withAlphaComponent(0.12)
        badgeIcon.tintColor = textColor
        divider.backgroundColor = textColor.withAlphaComponent(0.18)
        closeButton.tintColor = textColor
        appButton.tintColor = textColor
        backgroundColor = fill.resolvedColor(with: traitCollection)
    }

    /// The colours are the system ones unless chosen, and they resolve only once the panel sits
    /// in the keyboard: before that they took the phone's dark mode.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyColours() }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColours()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Content is at most 440 pt wide and centred, so in landscape titles sit near their switches.
        let inset: CGFloat = 16 + max(safeAreaInsets.left, safeAreaInsets.right)
        let width = min(bounds.width - 2 * inset, 440)
        let side = (bounds.width - width) / 2
        let top = headerHeight
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top)
        closeButton.frame = CGRect(x: side - 8, y: 0, width: 44, height: top)
        // Right to left: the gear tile, then the title beside it.
        let tile: CGFloat = min(28, top - 10)
        badge.frame = CGRect(x: side + width - tile, y: (top - tile) / 2, width: tile, height: tile)
        badgeIcon.frame = badge.bounds
        titleLabel.frame = CGRect(x: side + 40, y: 0, width: width - 40 - tile - 8, height: top)
        let hairline = 1 / max(1, traitCollection.displayScale)
        divider.frame = CGRect(x: side, y: top - hairline, width: width, height: hairline)
        scroll.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        let height = stack.systemLayoutSizeFitting(CGSize(width: width, height: 0),
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel).height
        stack.frame = CGRect(x: side, y: 0, width: width, height: height)
        scroll.contentSize = CGSize(width: bounds.width, height: height + 12)
    }
}
