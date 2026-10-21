import UIKit

/// The emoji panel, laid out as the iOS emoji keyboard: a search field on top, a grid in
/// sections that scrolls up and down, and a row of category buttons at the bottom (between
/// الفبا and backspace, which the keyboard places), scrolling sideways when they do not fit.
/// The first section mixes emoji for the words just typed (`EmojiPanel.suggestions`) with the
/// recently used ones. Cells are reused, so the panel stays light however many emoji it lists.
final class EmojiPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    struct Category {
        let symbol: String
        let title: String
        var emojis: [String]
    }

    var onPick: ((String) -> Void)?
    /// The search field was tapped: the keyboard shows its letters to type the search.
    var onSearch: (() -> Void)?
    var textColor = UIColor.label {
        didSet {
            searchField.textColor = textColor
            highlightCategory()
            grid.reloadData()
        }
    }
    /// The size of the letters on the keys over the standard size: the emoji and the category
    /// buttons follow it, the buttons within bounds.
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            buildCategoryButtons()
            setNeedsLayout()
            grid.reloadData()
        }
    }
    /// Heights of the search field and of the category row (a key row), and the room the
    /// keyboard keeps beside the category row for الفبا on the left and backspace on the right.
    var searchHeight: CGFloat = 38
    var bottomHeight: CGFloat = 54
    var bottomInsets: (left: CGFloat, right: CGFloat) = (0, 0)
    var isEnglish = false {
        didSet {
            guard isEnglish != oldValue else { return }
            searchField.placeholder = isEnglish ? "Search Emoji" : "جستجوی شکلک"
            searchField.isEnglish = isEnglish
            // English reads from the left: the recent emoji and the sections fill from there.
            grid.semanticContentAttribute = isEnglish ? .forceLeftToRight : .forceRightToLeft
            categoryScroll.semanticContentAttribute = grid.semanticContentAttribute
            grid.reloadData()
            setNeedsLayout()
        }
    }

    private var categories: [Category] = EmojiPanel.standard
    private let searchField = EmojiSearchField()
    private let grid: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private let categoryScroll = UIScrollView()
    private var categoryButtons: [UIButton] = []
    private var current = 0
    private static let recentKey = "recentEmoji"

    /// The emoji's point size: 28 at the standard letter size.
    static func emojiSize(scale: CGFloat) -> CGFloat { min(44, max(20, (28 * scale).rounded())) }

    override init(frame: CGRect) {
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        layout.headerReferenceSize = CGSize(width: 0, height: 22)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        searchField.placeholder = "جستجوی شکلک"
        searchField.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)
        addSubview(searchField)
        grid.backgroundColor = .clear
        grid.showsVerticalScrollIndicator = false
        grid.dataSource = self
        grid.delegate = self
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "emoji")
        grid.register(EmojiHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                      withReuseIdentifier: "header")
        addSubview(grid)
        categoryScroll.showsHorizontalScrollIndicator = false
        // Categories read right to left, like the keyboard.
        categoryScroll.semanticContentAttribute = .forceRightToLeft
        addSubview(categoryScroll)
        buildCategoryButtons()
        textColor = .label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildCategoryButtons() {
        categoryButtons.forEach { $0.removeFromSuperview() }
        let pointSize = min(20, max(13, (15 * scale).rounded()))
        categoryButtons = categories.enumerated().map { index, category in
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: category.symbol,
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)),
                            for: .normal)
            button.accessibilityLabel = category.title
            button.addAction(UIAction { [weak self] _ in self?.jump(to: index) }, for: .touchUpInside)
            categoryScroll.addSubview(button)
            return button
        }
        highlightCategory()
    }

    /// Fills the first section: emoji for `text` (the words before the cursor), then the
    /// recently used ones.
    func refresh(for text: String) {
        var first = Self.suggestions(for: text)
        for emoji in Self.recent where !first.contains(emoji) {
            first.append(emoji)
        }
        if first.isEmpty { first = Self.starters }
        categories[0].emojis = Array(first.prefix(32))
        grid.reloadData()
    }

    static let starters = ["😂", "❤️", "👍", "🙏", "😍", "😊", "🌹", "🎉"]

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = min(searchHeight, bounds.height / 4)
        let bottom = min(bottomHeight, bounds.height / 3)
        searchField.frame = CGRect(x: 6, y: 4, width: bounds.width - 12, height: max(0, top - 8))
        grid.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top - bottom)
        categoryScroll.frame = CGRect(x: bottomInsets.left, y: bounds.height - bottom,
                                      width: max(0, bounds.width - bottomInsets.left - bottomInsets.right), height: bottom)
        // Equal shares of the row when they fit, else each a fixed width and the row scrolls.
        let least = min(52, max(34, 38 * scale))
        let count = CGFloat(max(categoryButtons.count, 1))
        let buttonWidth = max(least, categoryScroll.bounds.width / count)
        for (index, button) in categoryButtons.enumerated() {
            // The first category at the right end in Persian, the left end in English.
            let x = (isEnglish ? CGFloat(index) : count - 1 - CGFloat(index)) * buttonWidth
            button.frame = CGRect(x: x, y: 0, width: buttonWidth, height: bottom)
        }
        let contentWidth = buttonWidth * count
        if categoryScroll.contentSize.width != contentWidth {
            categoryScroll.contentSize = CGSize(width: contentWidth, height: bottom)
            categoryScroll.contentOffset = CGPoint(x: isEnglish ? 0 : max(0, contentWidth - categoryScroll.bounds.width), y: 0)
        }
        layout.invalidateLayout()
    }

    private var cellSide: CGFloat {
        let wanted = Self.emojiSize(scale: scale) * 1.45
        let columns = max(6, floor(grid.bounds.width / wanted))
        return floor(grid.bounds.width / columns)
    }

    private func jump(to section: Int) {
        guard section < categories.count, !categories[section].emojis.isEmpty else { return }
        UIDevice.current.playInputClick()
        let header = grid.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader,
                                                                 at: IndexPath(item: 0, section: section))
        let y = min(header?.frame.minY ?? 0, max(0, grid.contentSize.height - grid.bounds.height))
        grid.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        current = section
        highlightCategory()
    }

    private func highlightCategory() {
        for (index, button) in categoryButtons.enumerated() {
            button.tintColor = index == current ? textColor : textColor.withAlphaComponent(0.45)
        }
        guard current < categoryButtons.count else { return }
        categoryScroll.scrollRectToVisible(categoryButtons[current].frame, animated: false)
    }

    // MARK: - Recent

    static var recent: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    static func remember(_ emoji: String) {
        var recent = Self.recent
        recent.removeAll { $0 == emoji }
        recent.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(24)), forKey: recentKey)
    }

    private func picked(_ emoji: String) {
        Self.remember(emoji)
        onPick?(emoji)
    }

    // MARK: - Grid

    func numberOfSections(in collectionView: UICollectionView) -> Int { categories.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        categories[section].emojis.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath) as! EmojiCell
        cell.label.text = categories[indexPath.section].emojis[indexPath.item]
        let size = Self.emojiSize(scale: scale)
        if cell.label.font.pointSize != size { cell.label.font = .systemFont(ofSize: size) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header",
                                                                     for: indexPath) as! EmojiHeader
        header.label.text = categories[indexPath.section].title
        header.label.textColor = textColor.withAlphaComponent(0.55)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let side = cellSide
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        referenceSizeForHeaderInSection section: Int) -> CGSize {
        categories[section].emojis.isEmpty ? .zero : CGSize(width: collectionView.bounds.width, height: 22)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        UIDevice.current.playInputClick()
        picked(categories[indexPath.section].emojis[indexPath.item])
    }

    /// The category button follows the section at the top of the grid.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === grid else { return }
        let top = CGPoint(x: 1, y: scrollView.contentOffset.y + 30)
        let section = grid.indexPathForItem(at: top)?.section
            ?? grid.indexPathsForVisibleItems.map(\.section).min() ?? current
        if section != current {
            current = section
            highlightCategory()
        }
    }

    // MARK: - Search

    /// Persian and English names and keywords of each emoji (emoji_names.txt, from CLDR),
    /// read the first time a search is typed.
    private static let names: [(emoji: String, terms: [String])] = {
        // The keyboard's copy; the app, which hosts the keyboard for tests, finds it in the extension.
        guard let url = Bundle(for: EmojiPanel.self).url(forResource: "emoji_names", withExtension: "txt")
                ?? Bundle.main.builtInPlugInsURL?.appendingPathComponent("PersianSTTKeyboard.appex/emoji_names.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1].split(separator: "|").map { normalized(String($0)) })
        }
    }()

    /// Lower case, Arabic ي and ك as Persian ی and ک, ZWNJ as a space.
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{064A}", with: "\u{06CC}")
            .replacingOccurrences(of: "\u{0643}", with: "\u{06A9}")
            .replacingOccurrences(of: "\u{200C}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Emoji whose name or a keyword starts with the query, or has a word that does: names
    /// and whole keywords first, as the iOS emoji search ranks them.
    static func search(_ query: String, limit: Int = 60) -> [String] {
        let query = normalized(query)
        guard !query.isEmpty else { return [] }
        var ranked: [(emoji: String, rank: Int, index: Int)] = []
        for (index, entry) in names.enumerated() {
            var best = Int.max
            for (position, term) in entry.terms.enumerated() {
                let rank: Int
                if term == query { rank = 0 }
                else if term.hasPrefix(query) { rank = 1 }
                else if term.contains(" " + query) { rank = 2 }
                else { continue }
                // The emoji's own name (the first term in each language) ranks a little higher.
                best = min(best, rank * 2 + (position == 0 ? 0 : 1))
            }
            if best != .max { ranked.append((entry.emoji, best, index)) }
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return ranked.prefix(limit).map(\.emoji)
    }

    // MARK: - Suggestions

    /// Emoji for the last words typed, latest word first. Persian stems of three letters or more
    /// and English ones of five or more match a word's start («خندیدم» finds «خند»); shorter
    /// ones only the whole word, so «نه» does not find «نهار».
    static func suggestions(for text: String) -> [String] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "\u{200C}")))
            .filter { !$0.isEmpty }
            .suffix(4)
            .reversed()
        var found: [String] = []
        for word in words {
            let plain = word.replacingOccurrences(of: "\u{200C}", with: "")
            for (stem, emojis) in keywords {
                let latin = stem.unicodeScalars.first.map(\.isASCII) ?? false
                guard plain == stem || (stem.count >= (latin ? 5 : 3) && plain.hasPrefix(stem)) else { continue }
                for emoji in emojis where !found.contains(emoji) { found.append(emoji) }
            }
        }
        return found
    }

    private static let keywords: [(String, [String])] = [
        ("سلام", ["👋", "🙂"]), ("درود", ["👋"]), ("خداحافظ", ["👋", "😊"]), ("بای", ["👋"]),
        ("مرسی", ["🙏", "🌹"]), ("ممنون", ["🙏", "🌹"]), ("تشکر", ["🙏"]), ("سپاس", ["🙏"]), ("لطف", ["🙏", "😊"]),
        ("دوستت", ["❤️", "😍", "😘"]), ("عاشق", ["😍", "❤️"]), ("عشق", ["❤️", "😍", "💕"]), ("قلب", ["❤️"]),
        ("بوس", ["😘", "💋"]), ("دلم", ["🥺", "❤️"]), ("دلتنگ", ["🥺", "💔"]),
        ("خند", ["😂", "🤣"]), ("هههه", ["😂", "🤣"]), ("باحال", ["😂", "😎"]), ("شوخی", ["😜", "😂"]),
        ("خوشحال", ["😊", "😁"]), ("شاد", ["😊", "🥳"]), ("عالی", ["👌", "👍", "🔥"]), ("خوب", ["👍", "😊"]),
        ("آفرین", ["👏", "👍"]), ("دمت", ["👏", "🙌"]), ("ایول", ["👏", "🔥"]), ("باشه", ["👌", "👍"]), ("اوکی", ["👌"]),
        ("بد", ["👎", "😕"]), ("ناراحت", ["😢", "😔"]), ("غمگین", ["😢", "💔"]), ("گریه", ["😭", "😢"]),
        ("عصبانی", ["😡", "😠"]), ("اعصاب", ["😤", "😡"]), ("ترس", ["😱", "😨"]), ("تعجب", ["😮", "😲"]),
        ("خسته", ["😩", "😴"]), ("خواب", ["😴", "🌙"]), ("شب", ["🌙", "✨"]), ("صبح", ["☀️", "☕"]),
        ("مریض", ["🤒", "😷"]), ("سرما", ["🥶", "🤧"]), ("گرم", ["🥵", "☀️"]), ("فکر", ["🤔"]),
        ("تبریک", ["🎉", "🥳", "👏"]), ("تولد", ["🎂", "🎉", "🎁"]), ("جشن", ["🎉", "🥳"]), ("کادو", ["🎁"]),
        ("هدیه", ["🎁"]), ("عید", ["🎉", "🌷"]), ("نوروز", ["🌷", "🐟", "🎉"]), ("یلدا", ["🍉", "🌙"]),
        ("غذا", ["🍽️", "😋"]), ("گرسنه", ["😋", "🍕"]), ("پیتزا", ["🍕"]), ("همبرگر", ["🍔"]), ("کباب", ["🍢"]),
        ("قهوه", ["☕"]), ("چای", ["🍵"]), ("کیک", ["🍰", "🎂"]), ("بستنی", ["🍦"]), ("میوه", ["🍎", "🍇"]),
        ("هندوانه", ["🍉"]), ("گل", ["🌹", "🌸"]), ("باران", ["🌧️", "☔"]), ("برف", ["❄️", "⛄"]),
        ("آفتاب", ["☀️"]), ("هوا", ["🌤️"]), ("دریا", ["🌊", "🏖️"]), ("سفر", ["✈️", "🧳"]), ("ماشین", ["🚗"]),
        ("خانه", ["🏠"]), ("خونه", ["🏠"]), ("کار", ["💼", "💻"]), ("درس", ["📚", "✏️"]), ("امتحان", ["📝", "📚"]),
        ("پول", ["💰", "💵"]), ("تلفن", ["📱"]), ("زنگ", ["📞"]), ("عکس", ["📷"]), ("آهنگ", ["🎵", "🎶"]),
        ("موسیقی", ["🎵"]), ("فیلم", ["🎬", "🍿"]), ("فوتبال", ["⚽"]), ("ورزش", ["💪", "🏃"]), ("بازی", ["🎮"]),
        ("ایران", ["🇮🇷"]), ("آتش", ["🔥"]), ("داغ", ["🔥"]), ("ستاره", ["⭐", "✨"]), ("بچه", ["👶"]),
        ("گربه", ["🐱"]), ("سگ", ["🐶"]), ("بله", ["✅", "👍"]), ("آره", ["👍"]), ("نه", ["❌"]), ("خیر", ["❌"]),
        ("hello", ["👋"]), ("hi", ["👋"]), ("bye", ["👋"]), ("thank", ["🙏"]), ("love", ["❤️", "😍"]),
        ("kiss", ["😘"]), ("haha", ["😂"]), ("lol", ["😂"]), ("happy", ["😊"]), ("sad", ["😢"]),
        ("cry", ["😭"]), ("angry", ["😡"]), ("sleep", ["😴"]), ("night", ["🌙"]), ("morning", ["☀️"]),
        ("birthday", ["🎂", "🎉"]), ("congrat", ["🎉", "👏"]), ("party", ["🥳"]), ("food", ["🍽️"]),
        ("pizza", ["🍕"]), ("coffee", ["☕"]), ("tea", ["🍵"]), ("cake", ["🍰"]), ("flower", ["🌹"]),
        ("rain", ["🌧️"]), ("sun", ["☀️"]), ("car", ["🚗"]), ("home", ["🏠"]), ("work", ["💼"]),
        ("money", ["💰"]), ("music", ["🎵"]), ("fire", ["🔥"]), ("ok", ["👌"]), ("yes", ["👍"]), ("no", ["❌"]),
        ("cool", ["😎"]), ("great", ["👍", "🔥"]), ("good", ["👍"]), ("cat", ["🐱"]), ("dog", ["🐶"]),
    ]

    // MARK: - Categories

    private static func list(_ text: String) -> [String] {
        var emojis: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byComposedCharacterSequences) { item, _, _, _ in
            if let item, item.trimmingCharacters(in: .whitespaces).isEmpty == false { emojis.append(item) }
        }
        return emojis
    }

    static let standard: [Category] = [
        Category(symbol: "clock", title: "پیشنهادی و اخیر", emojis: []),
        Category(symbol: "face.smiling", title: "شکلک‌ها", emojis: list(
            "😀😃😄😁😆😅😂🤣🥲🥹☺️😊😇🙂🙃😉😌😍🥰😘😗😙😚😋😛😝😜🤪🤨🧐🤓😎🥸🤩🥳🙂‍↕️😏😒🙂‍↔️😞😔😟😕🙁☹️😣😖😫😩🥺😢😭😮‍💨😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🫣🤗🫡🤔🫢🤭🤫🤥😶😶‍🌫️😐😑😬🫨🫠🙄😯😦😧😮😲🥱😴🤤😪😵😵‍💫🫥🤐🥴🤢🤮🤧😷🤒🤕🤑🤠😈👿👹👺🤡💩👻💀☠️👽👾🤖🎃😺😸😹😻😼😽🙀😿😾🙈🙉🙊")),
        Category(symbol: "hand.wave", title: "آدم‌ها و دست‌ها", emojis: list(
            "👋🤚🖐️✋🖖🫱🫲🫳🫴🫷🫸👌🤌🤏✌️🤞🫰🤟🤘🤙👈👉👆🖕👇☝️🫵👍👎✊👊🤛🤜👏🙌🫶👐🤲🤝🙏✍️💅🤳💪🦾🦵🦶👂👃🧠🫀🫁🦷🦴👀👁️👅👄🫦💋👶🧒👦👧🧑👱👨🧔👩🧓👴👵🙍🙎🙅🙆💁🙋🧏🙇🤦🤷👮🕵️💂🥷👷🫅🤴👸👳👲🧕🤵👰🤰🫄🤱👼🎅🤶🦸🦹🧙🧚🧛🧜🧝🧞🧟💆💇🚶🧍🧎🏃💃🕺👯🧖🧗🤺🏇⛷️🏂🏌️🏄🚣🏊⛹️🏋️🚴🚵🤸🤼🤽🤾🤹🧘🛀🛌👭👫👬💏💑👪🗣️👤👥🫂👣")),
        Category(symbol: "heart", title: "قلب‌ها و نمادها", emojis: list(
            "❤️🧡💛💚💙🩵💜🤎🖤🩶🤍🩷💔❤️‍🔥❤️‍🩹❣️💕💞💓💗💖💘💝💟☮️✝️☪️🕉️☸️✡️🔯🕎☯️☦️🛐⛎♈♉♊♋♌♍♎♏♐♑♒♓🆔⚛️🉑☢️☣️📴📳🈶🈚🈸🈺🈷️✴️🆚💮🉐㊙️㊗️🈴🈵🈹🈲🅰️🅱️🆎🆑🅾️🆘❌⭕🛑⛔📛🚫💯💢♨️🚷🚯🚳🚱🔞📵🚭❗❕❓❔‼️⁉️🔅🔆〽️⚠️🚸🔱⚜️🔰♻️✅🈯💹❇️✳️❎🌐💠Ⓜ️🌀💤🏧🚾♿🅿️🛗🈳🈂️🛂🛃🛄🛅🚹🚺🚼⚧️🚻🚮🎦📶🈁🔣ℹ️🔤🔡🔠🆖🆗🆙🆒🆕🆓0️⃣1️⃣2️⃣3️⃣4️⃣5️⃣6️⃣7️⃣8️⃣9️⃣🔟🔢#️⃣*️⃣⏏️▶️⏸️⏯️⏹️⏺️⏭️⏮️⏩⏪⏫⏬◀️🔼🔽➡️⬅️⬆️⬇️↗️↘️↙️↖️↕️↔️↪️↩️⤴️⤵️🔀🔁🔂🔄🔃🎵🎶➕➖➗✖️🟰♾️💲💱™️©️®️〰️➰➿🔚🔙🔛🔝🔜✔️☑️🔘🔴🟠🟡🟢🔵🟣⚫⚪🟤🔺🔻🔸🔹🔶🔷🔳🔲▪️▫️◾◽◼️◻️🟥🟧🟨🟩🟦🟪⬛⬜🟫🔈🔇🔉🔊🔔🔕📣📢💬💭🗯️♠️♣️♥️♦️🃏🎴🀄🕐🕑🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛")),
        Category(symbol: "leaf", title: "حیوانات و طبیعت", emojis: list(
            "🐶🐱🐭🐹🐰🦊🐻🐼🐻‍❄️🐨🐯🦁🐮🐷🐽🐸🐵🐔🐧🐦🐤🐣🐥🦆🦅🦉🦇🐺🐗🐴🦄🫎🐝🪱🐛🦋🐌🐞🐜🪰🪲🪳🦟🦗🕷️🕸️🦂🐢🐍🦎🦖🦕🐙🦑🦐🦞🦀🪼🐡🐠🐟🐬🐳🐋🦈🦭🐊🐅🐆🦓🦍🦧🦣🐘🦛🦏🐪🐫🦒🦘🦬🐃🐂🐄🐎🐖🐏🐑🦙🐐🦌🐕🐩🦮🐈🐈‍⬛🪶🐓🦃🦤🦚🦜🦢🦩🕊️🐇🦝🦨🦡🦫🦦🦥🐁🐀🐿️🦔🐾🐉🐲🌵🎄🌲🌳🌴🪵🌱🌿☘️🍀🎍🪴🎋🍃🍂🍁🍄🐚🪨🌾💐🌷🌹🥀🪻🪷🌺🌸🌼🌻🌞🌝🌛🌜🌚🌕🌖🌗🌘🌑🌒🌓🌔🌙🌎🌍🌏🪐💫⭐🌟✨⚡☄️💥🔥🌪️🌈☀️🌤️⛅🌥️☁️🌦️🌧️⛈️🌩️🌨️❄️☃️⛄🌬️💨💧💦🫧☔☂️🌊🌫️")),
        Category(symbol: "fork.knife", title: "خوراکی‌ها", emojis: list(
            "🍏🍎🍐🍊🍋🍌🍉🍇🍓🫐🍈🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🫛🥬🥒🌶️🫑🌽🥕🫒🧄🧅🥔🍠🫚🥐🥯🍞🥖🥨🧀🥚🍳🧈🥞🧇🥓🥩🍗🍖🦴🌭🍔🍟🍕🫓🥪🥙🧆🌮🌯🫔🥗🥘🫕🥫🍝🍜🍲🍛🍣🍱🥟🦪🍤🍙🍚🍘🍥🥠🥮🍢🍡🍧🍨🍦🥧🧁🍰🎂🍮🍭🍬🍫🍿🍩🍪🌰🥜🫘🍯🥛🍼🫖☕🍵🧃🥤🧋🍶🍺🍻🥂🍷🥃🍸🍹🧉🍾🧊🥄🍴🍽️🥣🥡🥢🧂")),
        Category(symbol: "soccerball", title: "فعالیت‌ها", emojis: list(
            "⚽🏀🏈⚾🥎🎾🏐🏉🥏🎱🪀🏓🏸🏒🏑🥍🏏🪃🥅⛳🪁🏹🎣🤿🥊🥋🎽🛹🛼🛷⛸️🥌🎿🏆🥇🥈🥉🏅🎖️🏵️🎗️🎫🎟️🎪🤹🎭🩰🎨🎬🎤🎧🎼🎹🥁🪘🪇🎷🎺🪗🎸🪕🎻🪈🎲♟️🎯🎳🎮🎰🧩🎉🎊🎈🎁🎀🪅🪩🧨🎆🎇🎃🎄🎋🎍🎎🎏🎐🎑🧧")),
        Category(symbol: "car", title: "سفر و مکان‌ها", emojis: list(
            "🚗🚕🚙🚌🚎🏎️🚓🚑🚒🚐🛻🚚🚛🚜🦯🦽🦼🛴🚲🛵🏍️🛺🚨🚔🚍🚘🚖🛞🚡🚠🚟🚃🚋🚞🚝🚄🚅🚈🚂🚆🚇🚊🚉✈️🛫🛬🛩️💺🛰️🚀🛸🚁🛶⛵🚤🛥️🛳️⛴️🚢⚓🛟🪝⛽🚧🚦🚥🚏🗺️🗿🗽🗼🏰🏯🏟️🎡🎢🛝🎠⛲⛱️🏖️🏝️🏜️🌋⛰️🏔️🗻🏕️⛺🛖🏠🏡🏘️🏚️🏗️🏭🏢🏬🏣🏤🏥🏦🏨🏪🏫🏩💒🏛️⛪🕌🕍🛕🕋⛩️🛤️🛣️🗾🎑🏞️🌅🌄🌠🎇🎆🌇🌆🏙️🌃🌌🌉🌁")),
        Category(symbol: "lightbulb", title: "اشیا", emojis: list(
            "⌚📱📲💻⌨️🖥️🖨️🖱️🖲️🕹️🗜️💽💾💿📀📼📷📸📹🎥📽️🎞️📞☎️📟📠📺📻🎙️🎚️🎛️🧭⏱️⏲️⏰🕰️⌛⏳📡🔋🪫🔌💡🔦🕯️🪔🧯🛢️💸💵💴💶💷🪙💰💳🪪💎⚖️🪜🧰🪛🔧🔨⚒️🛠️⛏️🪚🔩⚙️🪤🧱⛓️🧲🔫💣🧨🪓🔪🗡️⚔️🛡️🚬⚰️🪦⚱️🏺🔮📿🧿🪬💈⚗️🔭🔬🕳️🩹🩺🩻🩼💊💉🩸🧬🦠🧫🧪🌡️🧹🪠🧺🧻🚽🚰🚿🛁🛀🧼🪥🪒🧽🪣🧴🛎️🔑🗝️🚪🪑🛋️🛏️🛌🧸🪆🖼️🪞🪟🛍️🛒🎁🎈🎏🎀🪄🪅🎊🎉🎎🏮🎐🧧✉️📩📨📧💌📥📤📦🏷️🪧📪📫📬📭📮📯📜📃📄📑🧾📊📈📉🗒️🗓️📆📅🗑️📇🗃️🗳️🗄️📋📁📂🗂️🗞️📰📓📔📒📕📗📘📙📚📖🔖🧷🔗📎🖇️📐📏🧮📌📍✂️🖊️🖋️✒️🖌️🖍️📝✏️🔍🔎🔏🔐🔒🔓")),
        Category(symbol: "flag", title: "پرچم‌ها", emojis: list(
            "🇮🇷🏳️🏴🏁🚩🏳️‍🌈🇦🇫🇹🇯🇮🇶🇹🇷🇦🇿🇦🇲🇦🇪🇸🇦🇶🇦🇰🇼🇧🇭🇴🇲🇵🇰🇮🇳🇨🇳🇯🇵🇰🇷🇷🇺🇺🇦🇩🇪🇫🇷🇬🇧🇮🇹🇪🇸🇳🇱🇧🇪🇨🇭🇦🇹🇸🇪🇳🇴🇩🇰🇫🇮🇵🇱🇬🇷🇵🇹🇮🇪🇺🇸🇨🇦🇲🇽🇧🇷🇦🇷🇦🇺🇳🇿🇿🇦🇪🇬🇲🇦🇳🇬🇰🇪🇹🇭🇲🇾🇮🇩🇸🇬🇪🇺🇺🇳")),
    ]
}

private final class EmojiCell: UICollectionViewCell {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 28)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.4 : 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }
}

private final class EmojiHeader: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = AppFont.font(ofSize: 12)
        label.textAlignment = .right
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 6, dy: 0)
    }
}

/// The field at the top of the emoji panel, and of the search row while a search is typed:
/// a magnifier, the query or a placeholder, on a grey capsule as in iOS. Persian reads from
/// the right, English from the left. While a search is typed a caret blinks after the query.
final class EmojiSearchField: UIControl {
    var placeholder = "" { didSet { update() } }
    /// The search typed so far; nil shows the placeholder.
    var query: String? { didSet { update() } }
    var textColor = UIColor.label { didSet { update() } }
    var isEnglish = false { didSet { if isEnglish != oldValue { setNeedsLayout() } } }
    /// The blinking caret of a search being typed.
    var showsCaret = false {
        didSet {
            guard showsCaret != oldValue else { return }
            caret.isHidden = !showsCaret
            updateBlink()
        }
    }
    private let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let label = UILabel()
    private let caret = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.label.withAlphaComponent(0.08)
        layer.cornerCurve = .continuous
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        label.isUserInteractionEnabled = false
        caret.backgroundColor = .systemBlue
        caret.layer.cornerRadius = 1
        caret.isHidden = true
        caret.isUserInteractionEnabled = false
        addSubview(icon)
        addSubview(label)
        addSubview(caret)
        isAccessibilityElement = true
        accessibilityTraits = .searchField
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The blink runs only while the caret shows and the field is on screen.
    private func updateBlink() {
        caret.layer.removeAnimation(forKey: "blink")
        guard showsCaret, window != nil else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = 0.5
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        caret.layer.add(blink, forKey: "blink")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBlink()
    }

    private func update() {
        let empty = (query ?? "").isEmpty
        label.text = empty ? placeholder : query
        label.textColor = empty ? textColor.withAlphaComponent(0.45) : textColor
        label.font = AppFont.font(ofSize: min(17, max(13, bounds.height * 0.45)))
        icon.tintColor = textColor.withAlphaComponent(0.45)
        accessibilityLabel = placeholder
        accessibilityValue = query
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        let side = bounds.height
        let textRoom = max(0, bounds.width - side - 14)
        let empty = (query ?? "").isEmpty
        let textWidth = min(textRoom, ceil(label.intrinsicContentSize.width))
        let caretHeight = min(bounds.height - 10, label.font.lineHeight)
        if isEnglish {
            // Magnifier on the left, text from the left, the caret after it.
            icon.frame = CGRect(x: 4, y: 0, width: side, height: side)
            label.textAlignment = .left
            label.frame = CGRect(x: side + 4, y: 0, width: textRoom, height: side)
            let x = side + 4 + (empty ? 0 : textWidth) + 1
            caret.frame = CGRect(x: x, y: (side - caretHeight) / 2, width: 2, height: caretHeight)
        } else {
            icon.frame = CGRect(x: bounds.width - side - 4, y: 0, width: side, height: side)
            label.textAlignment = .right
            label.frame = CGRect(x: 10, y: 0, width: textRoom, height: side)
            let x = 10 + textRoom - (empty ? 0 : textWidth) - 3
            caret.frame = CGRect(x: x, y: (side - caretHeight) / 2, width: 2, height: caretHeight)
        }
    }
}

/// While an emoji search is typed: the search field, and under it a row of the emoji found,
/// which scrolls sideways (from the right in Persian, from the left in English).
final class EmojiSearchView: UIView {
    var onPick: ((String) -> Void)?
    var textColor = UIColor.label {
        didSet {
            field.textColor = textColor
            empty.textColor = textColor.withAlphaComponent(0.45)
        }
    }
    var scale: CGFloat = 1 { didSet { if scale != oldValue { show(results) } } }
    var fieldHeight: CGFloat = 44
    let field = EmojiSearchField()
    private let row = UIScrollView()
    private let empty = UILabel()
    private var buttons: [UIButton] = []
    private var results: [String] = []
    private var isEnglish = false

    /// The emoji in the row of results: smaller than in the grid.
    static func resultSize(scale: CGFloat) -> CGFloat { (EmojiPanel.emojiSize(scale: scale) * 0.8).rounded() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.isUserInteractionEnabled = false
        addSubview(field)
        row.showsHorizontalScrollIndicator = false
        addSubview(row)
        empty.font = AppFont.font(ofSize: 13)
        empty.textAlignment = .center
        addSubview(empty)
        textColor = .label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHidden: Bool {
        didSet { field.showsCaret = !isHidden }
    }

    /// Shows the query and what it finds; with no query yet, the recently used emoji.
    func update(query: String, isEnglish: Bool) {
        self.isEnglish = isEnglish
        field.isEnglish = isEnglish
        field.placeholder = isEnglish ? "Search Emoji" : "جستجوی شکلک"
        field.query = query
        field.showsCaret = !isHidden
        let found = query.isEmpty ? (EmojiPanel.recent.isEmpty ? EmojiPanel.starters : EmojiPanel.recent)
                                  : EmojiPanel.search(query)
        empty.text = found.isEmpty ? (isEnglish ? "No Emoji Found" : "شکلکی پیدا نشد") : nil
        show(found)
    }

    private func show(_ found: [String]) {
        results = found
        // Buttons are kept and reused: a search changes with every letter typed.
        let size = Self.resultSize(scale: scale)
        while buttons.count < found.count {
            let button = UIButton(type: .custom)
            let index = buttons.count
            button.addAction(UIAction { [weak self] _ in
                guard let self, index < self.results.count else { return }
                let emoji = self.results[index]
                UIDevice.current.playInputClick()
                EmojiPanel.remember(emoji)
                self.onPick?(emoji)
            }, for: .touchUpInside)
            row.addSubview(button)
            buttons.append(button)
        }
        for (index, button) in buttons.enumerated() {
            button.isHidden = index >= found.count
            guard index < found.count else { continue }
            button.setTitle(found[index], for: .normal)
            if button.titleLabel?.font.pointSize != size { button.titleLabel?.font = .systemFont(ofSize: size) }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = min(fieldHeight, bounds.height * 0.6)
        field.frame = CGRect(x: 6, y: 3, width: max(0, bounds.width - 12), height: max(0, top - 6))
        row.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        empty.frame = row.frame
        let side = Self.resultSize(scale: scale) * 1.5
        let count = CGFloat(results.count)
        for (index, button) in buttons.enumerated() where index < results.count {
            // The best match first: at the right end in Persian, the left end in English.
            let slot = isEnglish ? CGFloat(index) : count - 1 - CGFloat(index)
            button.frame = CGRect(x: slot * side, y: 0, width: side, height: row.bounds.height)
        }
        row.contentSize = CGSize(width: max(row.bounds.width, side * count), height: row.bounds.height)
        row.contentOffset = CGPoint(x: isEnglish ? 0 : max(0, row.contentSize.width - row.bounds.width), y: 0)
    }
}
