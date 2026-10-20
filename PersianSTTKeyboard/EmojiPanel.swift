import UIKit

/// The emoji panel: a grid in sections, with a bar of category buttons under it. The first
/// section mixes emoji for the words just typed (`EmojiPanel.suggestions`) with the recently
/// used ones. Cells are reused, so the panel stays light however many emoji it lists.
final class EmojiPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    struct Category {
        let symbol: String
        let title: String
        var emojis: [String]
    }

    var onPick: ((String) -> Void)?
    var textColor = UIColor.label {
        didSet {
            categoryButtons.forEach { $0.tintColor = textColor.withAlphaComponent(0.45) }
            highlightCategory()
            grid.reloadData()
        }
    }

    private var categories: [Category] = EmojiPanel.standard
    private let grid: UICollectionView
    private let layout = UICollectionViewFlowLayout()
    private let categoryBar = UIStackView()
    private var categoryButtons: [UIButton] = []
    private var current = 0
    private static let barHeight: CGFloat = 30
    private static let recentKey = "recentEmoji"

    override init(frame: CGRect) {
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        layout.headerReferenceSize = CGSize(width: 0, height: 22)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        grid.backgroundColor = .clear
        grid.showsVerticalScrollIndicator = false
        grid.dataSource = self
        grid.delegate = self
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "emoji")
        grid.register(EmojiHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                      withReuseIdentifier: "header")
        addSubview(grid)
        categoryBar.axis = .horizontal
        categoryBar.distribution = .fillEqually
        // Categories read right to left, like the keyboard.
        categoryBar.semanticContentAttribute = .forceRightToLeft
        for (index, category) in categories.enumerated() {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: category.symbol,
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)),
                            for: .normal)
            button.accessibilityLabel = category.title
            button.addAction(UIAction { [weak self] _ in self?.jump(to: index) }, for: .touchUpInside)
            categoryButtons.append(button)
            categoryBar.addArrangedSubview(button)
        }
        addSubview(categoryBar)
        textColor = .label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Fills the first section: emoji for `text` (the words before the cursor), then the
    /// recently used ones.
    func refresh(for text: String) {
        var first = Self.suggestions(for: text)
        for emoji in UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [] where !first.contains(emoji) {
            first.append(emoji)
        }
        if first.isEmpty { first = ["😂", "❤️", "👍", "🙏", "😍", "😊", "🌹", "🎉"] }
        categories[0].emojis = Array(first.prefix(32))
        grid.reloadData()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barHeight = min(Self.barHeight, bounds.height / 4)
        grid.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
        categoryBar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        layout.invalidateLayout()
    }

    private var columns: Int { bounds.width > 500 ? 14 : 8 }

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
    }

    private func picked(_ emoji: String) {
        var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        recent.removeAll { $0 == emoji }
        recent.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(24)), forKey: Self.recentKey)
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
        let side = floor(collectionView.bounds.width / CGFloat(columns))
        return CGSize(width: side, height: min(side, 42))
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
        let top = CGPoint(x: 1, y: scrollView.contentOffset.y + 30)
        let section = grid.indexPathForItem(at: top)?.section
            ?? grid.indexPathsForVisibleItems.map(\.section).min() ?? current
        if section != current {
            current = section
            highlightCategory()
        }
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
