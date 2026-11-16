import SwiftUI
import AVFoundation
import AudioToolbox
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The app is the settings page of the dictation keyboard: the background session the
/// keyboard records through, speech options, the look of the keys, and setup steps.
struct ContentView: View {
    @ObservedObject private var model = Transcriber.shared
    @ObservedObject private var keyboard = KeyboardSession.shared
    @ObservedObject private var personal = PersonalModel.shared
    @ObservedObject private var importer = ModelImporter.shared
    @ObservedObject private var notes = NotesStore.shared
    /// The notes page pushed by code (an audio file shared to the app), and the note to open there.
    @State private var showingNotes = false
    @State private var openingNote: UUID?
    @StateObject private var gate = KeyboardGate()
    @State private var pickingModel = false
    @AppStorage(PersonalModel.uploadKey) private var trainingUpload = false
    @State private var trainingToken = PersonalModel.shared.token
    @AppStorage(PersonalModel.autoUpdateKey) private var trainingAutoUpdate = false
    @AppStorage(KeyboardSession.idleMinutesKey) private var sessionMinutes = KeyboardSession.defaultIdleMinutes
    @AppStorage(KeyboardSession.noiseSuppressionKey) private var noiseSuppression = true
    @State private var style = KeyStyle.saved
    @State private var options = KeyboardOptions.saved
    @State private var dictionary = PersonalDictionary.saved
    @State private var shortcuts = TypedShortcuts.savedWithSamples()
    /// "fa" or "en": the app's and the keyboard's own words (Rooz, 2026-11-15).
    @AppStorage(AppLanguage.key) private var language = Onboarding.persian ? "fa" : "en"
    /// The «خواندن متن» page in the main list.
    static let showsReadAloud = false
    @State private var photoItem: PhotosPickerItem?
    /// Replaced to bring the app back to its first page, the session.
    @State private var navigationID = UUID()
    /// Raised when the keyboard opened the app to start the session: the mic shows a ripple.
    @State private var sessionStarts = 0
    /// The first-run guide, shown until it is finished once and from the setup page after.
    @AppStorage(Onboarding.doneKey) private var onboardingDone = false
    @State private var showingGuide = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Navigation titles in the app font.
        if let font = AppFont.name.flatMap({ UIFont(name: $0, size: 17) }) {
            UINavigationBar.appearance().titleTextAttributes = [.font: font]
        }
    }

    /// One page with the session and links to a page per topic, as in iOS Settings.
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                }
                .listRowBackground(Color.clear)

                if needsModel { modelSection }

                Section {
                    NavigationLink { NotesListView(opening: $openingNote) } label: {
                        LabeledContent {
                            Text(notes.notes.isEmpty ? "" : notes.notes.count.formatted(.number.locale(AppLanguage.locale)))
                        } label: {
                            SettingLabel(L("یادداشت‌ها", "Notes"), symbol: "note.text", color: .yellow)
                        }
                    }
                }

                // Voice.
                Section {
                    NavigationLink { speechPage } label: {
                        SettingLabel(L("گفتار", "Speech"), symbol: "waveform", color: .red)
                    }
                    NavigationLink { page(L("واژه‌نامه‌ی شخصی", "Personal Dictionary")) { DictionaryPage(dictionary: $dictionary) } } label: {
                        LabeledContent {
                            Text(dictionary.entries.isEmpty ? "" : dictionary.entries.count.formatted(.number.locale(AppLanguage.locale)))
                        } label: {
                            SettingLabel(L("واژه‌نامه‌ی شخصی", "Personal Dictionary"), symbol: "character.book.closed.fill", color: .teal)
                        }
                    }
                    // A build with the model inside has nothing to import.
                    if !needsModel, Transcriber.bundledModel == nil {
                        NavigationLink { page(L("مدل گفتار", "Speech Model")) { modelSection } } label: {
                            LabeledContent {
                                Text(model.modelName.isEmpty ? "—" : model.modelName).lineLimit(1)
                            } label: {
                                SettingLabel(L("مدل گفتار", "Speech Model"), symbol: "cpu", color: .purple)
                            }
                        }
                    }
                    // Nor learning from corrections in the build with the model inside (Rooz, 2026-11-05).
                    if Transcriber.bundledModel == nil {
                        NavigationLink { page(L("یادگیری از اصلاح‌ها", "Learning from Corrections")) { trainingSection } } label: {
                            LabeledContent {
                                Text(trainingUpload ? L("روشن", "On") : L("خاموش", "Off"))
                            } label: {
                                SettingLabel(L("یادگیری از اصلاح‌ها", "Learning from Corrections"), symbol: "brain.head.profile", color: .green)
                            }
                        }
                    }
                } header: {
                    Text(L("صدا", "Voice")).font(.app(.footnote))
                }

                // Typing.
                Section {
                    NavigationLink { typingPage } label: {
                        SettingLabel(L("تایپ و پیشنهاد کلمه", "Typing and Suggestions"), symbol: "character.cursor.ibeam", color: .blue)
                    }
                    NavigationLink { page(L("میان‌برهای تایپ", "Typing Shortcuts")) { ShortcutsPage(shortcuts: $shortcuts) } } label: {
                        LabeledContent {
                            Text(shortcuts.entries.isEmpty ? "" : shortcuts.entries.count.formatted(.number.locale(AppLanguage.locale)))
                        } label: {
                            SettingLabel(L("میان‌برهای تایپ", "Typing Shortcuts"), symbol: "text.insert", color: .indigo)
                        }
                    }
                    NavigationLink { appearancePage } label: {
                        SettingLabel(L("ظاهر دکمه‌ها", "Key Appearance"), symbol: "paintpalette.fill", color: .pink)
                    }
                    NavigationLink { page(L("دست‌خط", "Handwriting")) { HandwritingPage(options: $options) } } label: {
                        SettingLabel(L("دست‌خط", "Handwriting"), symbol: "pencil.and.scribble", color: .indigo)
                    }
                } header: {
                    Text(L("تایپ", "Typing")).font(.app(.footnote))
                }

                Section {
                    // Hidden until the Persian voice is finished (Rooz, 2026-11-04).
                    if Self.showsReadAloud {
                        NavigationLink { ReadAloudPage() } label: {
                            SettingLabel(L("خواندن متن", "Read Aloud"), symbol: "speaker.wave.2.fill", color: .mint)
                        }
                    }
                    NavigationLink { page(L("راه‌اندازی کیبورد", "Keyboard Setup")) { setupSection } } label: {
                        SettingLabel(L("راه‌اندازی کیبورد", "Keyboard Setup"), symbol: "keyboard", color: .gray)
                    }
                    NavigationLink { page(L("گزارش کارکرد", "Usage Report")) { UsageReportPage(dictionary: $dictionary) } } label: {
                        SettingLabel(L("گزارش کارکرد", "Usage Report"), symbol: "chart.bar.fill", color: .indigo)
                    }
                    NavigationLink { page(L("گزارش خرابی‌ها", "Crash Reports")) { CrashReportsPage() } } label: {
                        SettingLabel(L("گزارش خرابی‌ها", "Crash Reports"), symbol: "ladybug.fill", color: .orange)
                    }
                    Picker(selection: $language) {
                        Text("فارسی").font(AppFont.name.map { .custom($0, size: 17, relativeTo: .body) } ?? .body).tag("fa")
                        Text("English").font(.system(.body)).tag("en")
                    } label: {
                        SettingLabel(L("زبان", "Language"), symbol: "globe", color: .teal)
                    }
                    privacyLink
                } header: {
                    Text(L("سایر", "Other")).font(.app(.footnote))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingNotes) { NotesListView(opening: $openingNote) }
        }
        .id(navigationID)
        .fullScreenCover(isPresented: $showingGuide) { Onboarding() }
        .overlay {
            if onboardingDone && !showingGuide && !gate.isReady {
                KeyboardGateView(gate: gate)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: gate.isReady)
        .fileImporter(isPresented: $pickingModel, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { importer.importModel(from: url) }
        }
        .environment(\.layoutDirection, language == "en" ? .leftToRight : .rightToLeft)
        .font(.app(.body))
        .onChange(of: language) { _, new in
            AppLanguage.english = new == "en"
            UserDefaults.standard.set([new], forKey: "AppleLanguages")
            options.english = AppLanguage.english
            navigationID = UUID()
        }
        .onChange(of: style) { _, new in new.save() }
        .onChange(of: options) { _, new in new.save() }
        .onChange(of: dictionary) { _, new in new.save() }
        .onChange(of: shortcuts) { _, new in new.save() }
        // Rewrites the shared pasteboard copies, which a reinstall or reboot can clear.
        .onAppear {
            style.save()
            if !UserDefaults.standard.bool(forKey: "dictionaryStarters") {
                dictionary = dictionary.addingStarters()
                UserDefaults.standard.set(true, forKey: "dictionaryStarters")
            }
            // The keyboard's own settings panel may have changed them since.
            options = KeyboardOptions.load()
            AppLanguage.english = language == "en"
            options.english = AppLanguage.english
            options.save()
            dictionary.save()
            shortcuts.save()
            KeyboardBackground.handToKeyboard(style.backgroundImage)
            syncTraining()
            if !onboardingDone { showingGuide = true }
        }
        .onOpenURL { url in
            // An audio file shared to the app (a Telegram or WhatsApp voice message): a note.
            if url.isFileURL {
                navigationID = UUID()
                openingNote = FileTranscriber.shared.transcribe(url)
                showingNotes = true
                return
            }
            if url.host == "session" {
                // Straight to the session page, whatever page was open. Voice typing starts only
                // when the link carries the bridge key, i.e. came from our keyboard; a link from
                // another app or a web page only opens the page (review, 2026-11-09).
                navigationID = UUID()
                guard BridgeKey.matches(url) else { return }
                keyboard.start()
                if keyboard.isActive {
                    sessionStarts += 1
                    if options.keySounds { AudioServicesPlaySystemSound(1113) }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { notes.flush() }
            if phase == .active {
                gate.check()
                model.loadNewModelIfNeeded()
                importer.importWaitingModel()
                syncTraining()
                CrashReports.shared.collectFromKeyboard()
                var latest = KeyboardOptions.load()
                latest.english = AppLanguage.english
                if latest != options { options = latest }
            }
        }
    }

    /// A settings page: a form with a title.
    private func page<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form { content() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Only the arrow: the system's back title is in English.
            .toolbarRole(.editor)
            .font(.app(.body))
    }

    private var speechPage: some View {
        page(L("گفتار", "Speech")) {
            Section {
                Toggle(isOn: $noiseSuppression) {
                    SettingLabel(L("حذف نویز", "Noise Reduction"), symbol: "waveform.badge.minus", color: .green)
                }
                .onChange(of: noiseSuppression) { _, _ in keyboard.noiseSuppressionChanged() }
                if noiseSuppression {
                    // Voice Isolation keeps only the nearest voice; iOS offers it only while voice processing is on.
                    Button {
                        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                    } label: {
                        SettingLabel(L("فقط صدای من", "Only My Voice"), symbol: "person.wave.2.fill", color: .purple)
                    }
                    .disabled(!keyboard.isActive)
                }
            } header: {
                Text(L("میکروفون", "Microphone")).font(.app(.footnote))
            } footer: {
                if noiseSuppression {
                    Text(L("برای «فقط صدای من»، تایپ صوتی را روشن کنید و در منوی باز شده Voice Isolation را انتخاب کنید.", "For Only My Voice, turn on voice typing and choose Voice Isolation in the menu that opens.")).font(.app(.footnote))
                }
            }

            Section {
                Picker(selection: $sessionMinutes) {
                    Text(L("۱۰ دقیقه", "10 minutes")).tag(10)
                    Text(L("۳۰ دقیقه", "30 minutes")).tag(30)
                    Text(L("۱ ساعت", "1 hour")).tag(60)
                    Text(L("هرگز", "Never")).tag(0)
                } label: {
                    SettingLabel(L("خاموش شدن خودکار تایپ صوتی", "Turn Off Voice Typing After"), symbol: "timer", color: .orange)
                }
                .onChange(of: sessionMinutes) { _, _ in keyboard.idleMinutesChanged() }
                Picker(selection: $options.lockedSilenceSeconds) {
                    ForEach(KeyboardOptions.lockedSilenceChoices, id: \.self) { seconds in
                        Text(Self.durationName(seconds)).tag(seconds)
                    }
                } label: {
                    SettingLabel(L("پایان ضبط قفل‌شده بعد از سکوت", "End Locked Recording After Silence"), symbol: "lock", color: .orange)
                }
            } header: {
                Text(L("تایپ صوتی", "Voice Typing")).font(.app(.footnote))
            } footer: {
                Text(L("تایپ صوتی بعد از این مدت بی‌استفاده خاموش می‌شود. روشن ماندنش باتری مصرف می‌کند. ضبطی که روی اسپیس قفل شده، اگر در این مدت کلمه‌ی تازه‌ای شنیده نشود، خودش تمام می‌شود.", "Voice typing turns off after this long unused; keeping it on uses battery. A recording locked on the space bar ends by itself when no new word is heard for this long.")).font(.app(.footnote))
            }
        }
    }

    /// ۵ ثانیه, ۲ دقیقه (5 s, 2 min in English).
    static func durationName(_ seconds: Double) -> String {
        let whole = Int(seconds)
        if AppLanguage.english { return whole >= 60 && whole % 60 == 0 ? "\(whole / 60) min" : "\(whole) s" }
        let persian = { (n: Int) in String(String(n).map { Array("۰۱۲۳۴۵۶۷۸۹")[$0.wholeNumberValue ?? 0] }) }
        return whole >= 60 && whole % 60 == 0 ? "\(persian(whole / 60)) دقیقه" : "\(persian(whole)) ثانیه"
    }

    /// Where digits are: nowhere extra, a row above the letters, or small on the top row's letters.
    private var numbersPlace: Binding<Int> {
        Binding {
            options.digitsOnLetters ? 2 : options.numberRow ? 1 : 0
        } set: { place in
            options.numberRow = place == 1
            options.digitsOnLetters = place == 2
        }
    }

    private var typingPage: some View {
        page(L("تایپ و پیشنهاد کلمه", "Typing and Suggestions")) {
            Section {
                Toggle(isOn: $options.suggestionBar.animation(.easeInOut(duration: 0.3))) {
                    SettingLabel(L("نمایش ردیف پیشنهاد", "Show Suggestion Bar"), symbol: "rectangle.topthird.inset.filled", color: .cyan)
                }
                // Off, the bar's own option stays in view, greyed, so turning it back on finds it
                // as it was.
                Toggle(isOn: $options.predictNextWord) {
                    SettingLabel(L("پیش‌بینی کلمه‌ی بعدی", "Predict Next Word"), symbol: "text.append", color: .blue)
                }
                .disabled(!options.suggestionBar)
                .opacity(options.suggestionBar ? 1 : 0.45)
            } header: {
                Text(L("ردیف پیشنهاد", "Suggestion Bar")).font(.app(.footnote))
            } footer: {
                Text(options.suggestionBar
                     ? L("کلمه‌هایی که بیشتر بعد از کلمه‌ی قبلی می‌آیند پیشنهاد می‌شوند و کلمه‌های خودتان هم یاد گرفته می‌شوند.", "Words that most often follow the previous word are suggested, and your own words are learned too.")
                     : L("ردیف بالای کلیدها پنهان است و کیبورد کوتاه‌تر می‌شود.", "The bar above the keys is hidden and the keyboard is shorter."))
                    .font(.app(.footnote))
            }

            Section {
                // Corrects on a space, with or without the row.
                Toggle(isOn: $options.correctTypos) {
                    SettingLabel(L("اصلاح غلط تایپی", "Correct Typos"), symbol: "checkmark.seal.fill", color: .green)
                }
                Toggle(isOn: $options.autoZWNJ) {
                    SettingLabel(L("نیم‌فاصله‌ی خودکار", "Automatic ZWNJ"), symbol: "wand.and.stars", color: .indigo)
                }
                Toggle(isOn: $options.doubleSpacePunctuation) {
                    SettingLabel(L("دو فاصله: نقطه، سه فاصله: ویرگول", "Two Spaces: Period, Three: Comma"), symbol: "space", color: .orange)
                }
            } header: {
                Text(L("اصلاح خودکار", "Auto-Correction")).font(.app(.footnote))
            } footer: {
                Text(L("با زدن فاصله، کلمه‌ای که به‌روشنی غلط تایپ شده درست می‌شود و «میخوام» می‌شود «می‌خوام». پاک کردن بلافاصله بعد از آن، تایپ شما را برمی‌گرداند.", "On space, a clearly mistyped word is corrected and Persian words get their zero-width non-joiner (ZWNJ). Deleting right after puts back what you typed.")
                     + (options.autoZWNJ ? "" : L(" بدون نیم‌فاصله‌ی خودکار، دو بار زدن سریع یک حرف پیوندی نیم‌فاصله می‌گذارد: «م ی ی» ← «می‌».", " Without automatic ZWNJ, tapping a joining letter twice quickly adds a ZWNJ.")))
                    .font(.app(.footnote))
            }

            Section {
                Picker(selection: numbersPlace) {
                    Text(L("خاموش", "Off")).tag(0)
                    Text(L("ردیف جدا بالای حروف", "Separate Row Above Letters")).tag(1)
                    Text(L("روی حروف ردیف اول", "On the Top Row Letters")).tag(2)
                } label: {
                    SettingLabel(L("اعداد", "Numbers"), symbol: "number", color: .teal)
                }
            } header: {
                Text(L("اعداد", "Numbers")).font(.app(.footnote))
            } footer: {
                Text(options.digitsOnLetters
                     ? L("عدد کوچک بالای هر حرف ردیف اول است (ض ۱ تا ج ۰). نگه داشتن کلید، حرف و عدد فارسی و انگلیسی را نشان می‌دهد.", "A small digit sits above each top-row letter. Holding a key shows its letter and the Persian and English digit.")
                     : options.numberRow
                        ? L("ردیف کوتاه اعداد کیبورد را کمی بلندتر می‌کند. نگه داشتن هر عدد، شکل فارسی و انگلیسی آن را نشان می‌دهد.", "The short number row makes the keyboard a little taller. Holding a digit shows its Persian and English forms.")
                        : L("اعداد در صفحه‌ی ۱۲۳ هستند.", "Numbers are on the 123 page."))
                    .font(.app(.footnote))
            }

            Section {
                Toggle(isOn: $options.keyPreview) {
                    SettingLabel(L("بزرگ‌نمایی حرف هنگام تایپ", "Key Preview While Typing"), symbol: "character.magnify", color: .purple)
                }
                Toggle(isOn: $options.tiltLetters) {
                    SettingLabel(L("کلیدهای سه‌بعدی", "3D Keys"), symbol: "cube.transparent", color: .teal)
                }
                Toggle(isOn: $options.keySounds) {
                    SettingLabel(L("صدای کلیدها", "Key Sounds"), symbol: "speaker.wave.2.fill", color: .pink)
                }
                Toggle(isOn: $options.haptics) {
                    SettingLabel(L("لرزش (هپتیک)", "Haptics"), symbol: "iphone.radiowaves.left.and.right", color: .red)
                }
            } header: {
                Text(L("بازخورد کلیدها", "Key Feedback")).font(.app(.footnote))
            } footer: {
                Text(L("صدا با سوییچ بی‌صدای گوشی قطع می‌شود. لرزش برای کلیدها، اصلاح کلمه و دسته‌های شکلک فرق دارد.", "Sounds follow the phone's silent switch. Haptics differ for keys, word corrections and emoji categories.")).font(.app(.footnote))
            }

            Section {
                Toggle(isOn: $options.learnTouches) {
                    SettingLabel(L("یادگیری محل لمس (TapMap)", "Learn Touch Positions (TapMap)"), symbol: "hand.point.up.left.fill", color: .orange)
                }
                NavigationLink {
                    page(L("نقشه‌ی لمس شما", "Your Touch Map")) { TapMapPage() }
                } label: {
                    SettingLabel(L("نقشه‌ی لمس شما", "Your Touch Map"), symbol: "scope", color: .blue)
                }
                Button(role: .destructive) {
                    options.touchResets += 1
                    TouchModel.clearFromKeyboard()
                } label: {
                    SettingLabel(L("پاک کردن یادگرفته‌های لمس", "Clear Learned Touches"), symbol: "arrow.counterclockwise", color: .red)
                }
            } header: {
                Text(L("لمس هوشمند", "Smart Touch")).font(.app(.footnote))
            } footer: {
                Text(L("کیبورد یاد می‌گیرد هر حرف را کجای کلید می‌زنید و لمس نزدیک مرز دو کلید را به حرف درست می‌دهد.", "The keyboard learns where on each key you tap and gives a touch near the border of two keys to the right letter.")).font(.app(.footnote))
            }
        }
    }

    private var appearancePage: some View {
        page(L("ظاهر دکمه‌ها", "Key Appearance")) {
            Section {
                KeyPreview(style: style)
                    .listRowBackground(KeyPreviewBackground(style: style))
                    .listRowSeparator(.hidden)
                // Each slider sits in the row of the setting it belongs to, under its title, so
                // every line between rows starts where the titles do.
                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel(L("اندازه‌ی حروف", "Letter Size"), symbol: "textformat.size", color: .orange)
                    SliderLine(small: "textformat.size.smaller", large: "textformat.size.larger") {
                        Slider(value: Binding { style.letterSize ?? KeyStyle.standardLetterSize } set: { style.letterSize = $0.rounded() },
                               in: 16...32, step: 1)
                    } value: {
                        Text(Int(style.letterSize ?? KeyStyle.standardLetterSize).formatted(.number.locale(AppLanguage.locale)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
                ColorPicker(selection: backgroundColorBinding, supportsOpacity: false) {
                    SettingLabel(L("رنگ پس‌زمینه‌ی کیبورد", "Keyboard Background Colour"), symbol: "keyboard.fill", color: .brown)
                }
                VStack(spacing: 6) {
                    ColorPicker(selection: colorBinding(\.fill), supportsOpacity: false) {
                        SettingLabel(L("رنگ دکمه", "Key Colour"), symbol: "square.fill", color: .pink)
                    }
                    opacitySlider(\.fill)
                }
                VStack(spacing: 6) {
                    ColorPicker(selection: colorBinding(\.stroke), supportsOpacity: false) {
                        SettingLabel(L("رنگ دور دکمه", "Key Border Colour"), symbol: "square", color: .indigo)
                    }
                    opacitySlider(\.stroke)
                }
                ColorPicker(selection: textColorBinding, supportsOpacity: false) {
                    SettingLabel(L("رنگ حروف", "Letter Colour"), symbol: "textformat", color: .teal)
                }
                Button(L("بازگشت به پیش‌فرض", "Reset to Default")) { style = .standard }
            } footer: {
                Text(L("تغییرها دفعه‌ی بعد که کیبورد باز شود اعمال می‌شوند.", "Changes apply the next time the keyboard opens.")).font(.app(.footnote))
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        BackgroundChoice(image: nil, title: L("بدون عکس", "No Photo"), selected: style.backgroundImage == nil) {
                            style.backgroundImage = nil
                        }
                        if let id = style.backgroundImage, KeyboardBackground.isPhoto(id) {
                            BackgroundChoice(image: KeyboardBackground.image(id, size: .zero), title: L("عکس شما", "Your Photo"), selected: true) {}
                        }
                        ForEach(KeyboardBackground.presets) { preset in
                            BackgroundChoice(image: KeyboardBackground.thumbnail(preset.id), title: preset.name,
                                             selected: style.backgroundImage == preset.id) {
                                style.backgroundImage = preset.id
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    SettingLabel(L("انتخاب عکس از گالری", "Choose Photo from Library"), symbol: "photo.fill", color: .orange)
                }
            } header: {
                Text(L("عکس پس‌زمینه", "Background Photo")).font(.app(.footnote))
            } footer: {
                Text(L("عکس جای رنگ پس‌زمینه را می‌گیرد و وسط آن به اندازه‌ی کیبورد بریده می‌شود. اگر رنگ حروف را انتخاب نکرده باشید، حروف روی عکس تیره روشن و روی عکس روشن تیره می‌شوند.", "The photo replaces the background colour and its middle is cropped to the keyboard's size. Unless you chose a letter colour, letters are light on a dark photo and dark on a light one.")).font(.app(.footnote))
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       let id = KeyboardBackground.savePhoto(image) {
                        style.backgroundImage = id
                    }
                    photoItem = nil
                }
            }
        }
    }

    private var setupSection: some View {
        Section {
            SetupStep(number: L("۱", "1"), text: "Settings › General › Keyboard › Keyboards › Add New Keyboard")
            SetupStep(number: L("۲", "2"), text: L("«آواک» را انتخاب و Allow Full Access را روشن کنید.", "Choose Avak and turn on Allow Full Access."))
            SetupStep(number: L("۳", "3"), text: L("در هر اپی با 🌐 به این کیبورد بروید و برای دیکته کلید فاصله را نگه دارید.", "In any app switch to this keyboard with 🌐 and hold the space bar to dictate."))
            Button {
                showingGuide = true
            } label: {
                SettingLabel(L("راهنمای قدم‌به‌قدم", "Step-by-Step Guide"), symbol: "book.fill", color: .orange)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                SettingLabel(L("باز کردن تنظیمات آیفون", "Open iPhone Settings"), symbol: "gearshape.fill", color: .gray)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [.pink, .purple, .blue, .teal, .pink], center: .center))
                    .opacity(keyboard.isActive ? 1 : 0.45)
                Image(systemName: "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 88, height: 88)
            .shadow(color: .purple.opacity(keyboard.isActive ? 0.4 : 0), radius: 14)
            .background(SessionRipple(trigger: sessionStarts))

            Text(L("آواک", "Avak"))
                .font(.app(.title2))
            Text(statusText)
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                keyboard.isActive ? keyboard.stop() : keyboard.start()
            } label: {
                Text(keyboard.isActive ? L("خاموش کردن تایپ صوتی", "Turn Off Voice Typing") : L("روشن کردن تایپ صوتی", "Turn On Voice Typing"))
                    .font(.app(.headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            // Grey until the speech model has loaded, then blue (Rooz, 2026-11-09).
            .tint(keyboard.isActive ? .red : model.hasModel ? .accentColor : .gray)
            .disabled(!keyboard.isActive && !model.hasModel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The project website on Cloudflare Pages (Rooz, 2026-11-01), until a domain is bought.
    static let privacyPolicyURL = URL(string: "https://avak.app/privacy")!

    private var privacyLink: some View {
        Link(destination: Self.privacyPolicyURL) {
            SettingLabel(L("سیاست حریم خصوصی", "Privacy Policy"), symbol: "hand.raised.fill", color: .blue)
        }
        .foregroundStyle(.primary)
    }

    /// Learning from corrections: uploading them to the user's private GitHub repository and
    /// installing the models the training workflow publishes there.
    private var trainingSection: some View {
        Section {
            Toggle(isOn: $trainingUpload) {
                SettingLabel(L("ارسال اصلاح‌ها برای آموزش", "Send Corrections for Training"), symbol: "arrow.up.circle.fill", color: .blue)
            }
            .onChange(of: trainingUpload) { _, on in
                if on { Task { await personal.upload() } }
            }
            HStack {
                SettingLabel(L("توکن GitHub", "GitHub Token"), symbol: "key.fill", color: .yellow)
                SecureField("github_pat_…", text: $trainingToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .environment(\.layoutDirection, .leftToRight)
                    .onChange(of: trainingToken) { _, new in personal.token = new }
                    .onSubmit { syncTraining() }
            }
            if personal.pending > 0 {
                Button {
                    Task { await personal.upload() }
                } label: {
                    LabeledContent {
                        Text("\(personal.pending)")
                    } label: {
                        SettingLabel(L("ارسال اصلاح‌های در صف", "Send Queued Corrections"), symbol: "tray.and.arrow.up.fill", color: .orange)
                    }
                }
            }
            Toggle(isOn: $trainingAutoUpdate) {
                SettingLabel(L("دانلود خودکار مدل جدید", "Download New Model Automatically"), symbol: "arrow.down.circle.fill", color: .green)
            }
            LabeledContent(L("مدل در حال استفاده", "Model in Use"),
                           value: personal.version > 0 ? L("شخصی، نسخه‌ی \(personal.version)", "Personal, version \(personal.version)") : L("مدل اصلی", "Original Model"))
            if let progress = personal.downloadProgress {
                ProgressView(value: progress) {
                    Text(progress >= 1 ? L("در حال آماده کردن مدل…", "Preparing the model…") : L("در حال دانلود مدل جدید…", "Downloading the new model…"))
                }
            } else if let release = personal.available {
                Button {
                    personal.download()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("دانلود نسخه‌ی \(release.version)", "Download Version \(release.version)"))
                        Text(releaseSummary(release))
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button(L("بررسی نسخه‌ی جدید", "Check for New Version")) {
                    Task { await personal.check() }
                }
                .disabled(trainingToken.isEmpty)
            }
            if personal.version > 0 {
                Button(L("بازگشت به مدل اصلی", "Back to the Original Model"), role: .destructive) {
                    personal.useBaseModel()
                }
            }
            privacyLink
        } footer: {
            Text((personal.status.isEmpty ? "" : personal.status + "\n\n")
                 + L("وقتی متن دیکته‌شده را با تایپ یا دیکته‌ی دوباره اصلاح کنید، صدای آن دیکته و متن درست به مخزن خصوصی خودتان در GitHub فرستاده می‌شود و جای دیگری نمی‌رود. ", "When you correct dictated text by typing or dictating again, the recording of that dictation and the corrected text are sent to your own private GitHub repository and nowhere else. ")
                 + L("سرور رایگان GitHub هر چند ساعت، اگر اصلاح تازه‌ای باشد، مدل را با همه‌ی نمونه‌ها آموزش می‌دهد و فقط وقتی نسخه‌ی جدید روی نمونه‌های کنارگذاشته دقیق‌تر باشد آن را منتشر می‌کند. ", "Every few hours, if there are new corrections, GitHub's free server trains the model on all samples and publishes the new version only when it is more accurate on held-out samples. ")
                 + L("توکن فقط در Keychain همین آیفون نگه داشته می‌شود.", "The token is kept only in this iPhone's Keychain.")).font(.app(.footnote))
        }
    }

    private func releaseSummary(_ release: PersonalModel.Release) -> String {
        var parts = [L("\(release.size >> 20) مگابایت", "\(release.size >> 20) MB")]
        if let samples = release.samples { parts.append(L("\(samples) نمونه", "\(samples) samples")) }
        if let before = release.werBefore, let after = release.werAfter {
            parts.append(String(format: L("خطای کلمه %.1f٪ ← %.1f٪", "word errors %.1f%% → %.1f%%"), before, after))
        }
        return parts.joined(separator: L("، ", ", "))
    }

    private func syncTraining() {
        Task {
            await personal.upload()
            await personal.check(automatic: true)
        }
    }

    private var statusText: String {
        if model.isBusy && model.modelName.isEmpty || model.status.hasPrefix(L("در حال بارگذاری", "Loading")) {
            return L("در حال بارگذاری مدل…", "Loading the model…")
        }
        if needsModel {
            return L("برای دیکته، یک بار فایل مدل گفتار را وارد کنید.", "To dictate, import the speech model file once.")
        }
        if keyboard.isActive {
            return L("کیبورد آماده است. به اپ قبلی برگردید و با نگه‌داشتن کلید فاصله دیکته کنید.", "The keyboard is ready. Go back to the previous app and hold the space bar to dictate.")
        }
        return keyboard.message.isEmpty ? L("برای دیکته با کیبورد، تایپ صوتی را روشن کنید.", "To dictate with the keyboard, turn on voice typing.") : keyboard.message
    }

    /// No model is loaded and none is loading.
    private var needsModel: Bool { !model.hasModel && !model.isBusy }

    /// The speech model, which builds no longer carry: imported once from Files, it stays
    /// through updates of the app.
    private var modelSection: some View {
        Section {
            Button {
                pickingModel = true
            } label: {
                SettingLabel(needsModel ? L("وارد کردن مدل از Files", "Import Model from Files") : L("جایگزینی مدل از Files", "Replace Model from Files"),
                             symbol: "square.and.arrow.down.fill", color: .blue)
            }
            .disabled(importer.progress != nil)
            if importer.progress != nil {
                ProgressView {
                    Text(L("در حال آماده کردن مدل…", "Preparing the model…")).font(.app(.subheadline))
                }
            }
            LabeledContent(L("مدل", "Model"), value: model.modelName.isEmpty ? "—" : model.modelName)
            LabeledContent(L("وضعیت مدل", "Model Status"), value: model.status)
        } header: {
            Text(L("مدل گفتار", "Speech Model")).font(.app(.footnote))
        } footer: {
            Text((importer.message.isEmpty ? "" : importer.message + "\n\n")
                 + L("فایل مدل گفتار (پسوند aar، حدود ۱۰۰ مگابایت) فقط یک بار لازم است و با نصب نسخه‌های بعدی روی همین برنامه می‌ماند؛ اگر برنامه را پاک کنید، مدل هم پاک می‌شود. ", "The speech model file (.aar, about 100 MB) is needed once and stays when newer versions are installed over this app; deleting the app deletes the model too. ")
                 + L("آن را از بخش Artifacts همان اجرا در GitHub با نام AvakScribeModel دانلود کنید، از zip خارج کنید و با AirDrop یا iCloud Drive به آیفون بفرستید و اینجا انتخاب کنید. ", "Download it from the run's Artifacts on GitHub as AvakScribeModel, unzip it, send it to the iPhone with AirDrop or iCloud Drive and choose it here. ")
                 + L("راه دیگر: آیفون را به Mac وصل کنید، در Finder آیفون را انتخاب کنید و در بخش Files فایل را روی «آواک» بکشید.", "Or connect the iPhone to a Mac, select the iPhone in Finder and drag the file onto Avak under Files.")).font(.app(.footnote))
        }
    }

    private func colorBinding(_ path: WritableKeyPath<KeyStyle, KeyStyle.RGBA>) -> Binding<Color> {
        Binding {
            let c = style[keyPath: path]
            return Color(red: c.r, green: c.g, blue: c.b)
        } set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            style[keyPath: path].r = Double(r)
            style[keyPath: path].g = Double(g)
            style[keyPath: path].b = Double(b)
        }
    }

    /// Letters follow the system colour until a colour is picked.
    private var textColorBinding: Binding<Color> {
        Binding {
            style.text.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color(.label)
        } set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            style.text = KeyStyle.RGBA(r: Double(r), g: Double(g), b: Double(b), a: 1)
        }
    }

    /// The keyboard keeps the system background until a colour is picked.
    private var backgroundColorBinding: Binding<Color> {
        Binding {
            style.background.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color(.systemGray5)
        } set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            style.background = KeyStyle.RGBA(r: Double(r), g: Double(g), b: Double(b), a: 1)
        }
    }

    /// How much of the colour shows, under its picker.
    private func opacitySlider(_ path: WritableKeyPath<KeyStyle, KeyStyle.RGBA>) -> some View {
        SliderLine(small: "circle.dotted", large: "circle.fill") {
            Slider(value: Binding { style[keyPath: path].a } set: { style[keyPath: path].a = $0 }, in: 0...1)
        } value: {
            Text(Int(style[keyPath: path].a * 100).formatted(.number.locale(AppLanguage.locale)) + L("٪", "%"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
    }
}

/// A slider under a row's title, between a small and a large symbol, with its value at the end.
private struct SliderLine<Control: View, Value: View>: View {
    let small: String
    let large: String
    @ViewBuilder let control: Control
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: small)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            control
            Image(systemName: large)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            value
        }
        // Under the title, past the 29-point symbol square and Label's gap.
        .padding(.leading, 41)
    }
}

/// The handwriting pad's own page (Rooz, 2026-11-08): how soon a word is read, and the pen's
/// width and colour, with a sample of the pen.
private struct HandwritingPage: View {
    @Binding var options: KeyboardOptions

    var body: some View {
        Section {
            SliderLine(small: "tortoise.fill", large: "hare.fill") {
                Slider(value: $options.handwritingSpeed, in: 0...1)
            } value: {
                Text(options.handwritingPause.formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.locale)) + L(" ثانیه", " s"))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52)
            }
        } header: {
            Text(L("سرعت", "Speed")).font(.app(.footnote))
        } footer: {
            Text(L("مکث پس از بلند کردن انگشت تا کلمه به متن تبدیل شود. سریع: می‌شود بی‌وقفه نوشت. آرام: برای نوشتن با حوصله‌تر.", "The pause after lifting your finger before the word turns into text. Fast: write without stopping. Slow: for more careful writing.")).font(.app(.footnote))
        }

        Section {
            Picker(selection: $options.handwritingSize) {
                ForEach(0..<3) { Text(KeyboardOptions.handwritingSizeNames[$0]).tag($0) }
            } label: {
                SettingLabel(L("اندازه‌ی صفحه", "Pad Size"), symbol: "arrow.up.and.down", color: .orange)
            }
        } footer: {
            Text(L("روی صفحه‌ی دست‌خط هم می‌شود دستگیره‌ی بالای آن را گرفت و کمی بالا یا پایین کشید تا یک اندازه بزرگ‌تر یا کوچک‌تر شود. دو ضربه روی دستگیره اندازه‌ی متوسط را برمی‌گرداند.", "On the handwriting pad you can also drag its top handle up or down a little for one size larger or smaller. Double-tapping the handle restores the medium size.")).font(.app(.footnote))
        }

        Section {
            Toggle(isOn: $options.handwritingSlide) {
                SettingLabel(L("کنار رفتن نوشته", "Slide Writing Aside"), symbol: "arrow.left.and.right", color: .teal)
            }
        } footer: {
            Text(options.handwritingSlide
                 ? L("کلمه‌ی نوشته‌شده مثل کاغذ از زیر قلم کنار می‌رود (فارسی به راست، انگلیسی به چپ) و چند ثانیه بعد از آخرین نوشتن محو می‌شود.", "The written word slides out from under the pen like paper (Persian to the right, English to the left) and fades a few seconds after you last wrote.")
                 : L("هر کلمه همان لحظه که خوانده شد، از جایی که شروع شده دود می‌شود و بالا می‌رود؛ سرعتش با سرعت دست‌خط است.", "Each word turns to smoke where it started as soon as it is read and rises; its speed follows the handwriting speed.")).font(.app(.footnote))
        }

        Section {
            Toggle(isOn: $options.handwritingGuide) {
                SettingLabel(L("خط راهنما", "Guide Line"), symbol: "ruler", color: .gray)
            }
        } footer: {
            Text(L("یک خط کم‌رنگ هم‌رنگ حروف روی کاغذ، تا اندازه و راستای نوشته یکدست بماند.", "A faint line in the letter colour on the paper, to keep the writing's size and direction even.")).font(.app(.footnote))
        }

        Section {
            Toggle(isOn: $options.handwritingStrip) {
                SettingLabel(L("نوار کنار بردن", "Slide-Aside Strip"), symbol: "arrow.right.to.line", color: .gray)
            }
        } footer: {
            Text(L("نواری کم‌رنگ در لبه‌ی کاغذ (فارسی راست، انگلیسی چپ). یک ضربه روی آن کلمه را همان لحظه می‌خواند و کنار می‌برد؛ روی خود نوار هم می‌شود نوشت.", "A faint strip at the paper's edge (right for Persian, left for English). A tap on it reads the word at once and slides it aside; you can also write on the strip.")).font(.app(.footnote))
        }

        Section {
            SliderLine(small: "line.diagonal", large: "scribble.variable") {
                Slider(value: $options.handwritingInkWidth, in: KeyboardOptions.handwritingWidths, step: 0.5)
            } value: {
                Text(options.handwritingInkWidth.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.locale)))
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28)
            }
            Toggle(isOn: Binding {
                options.handwritingInk == nil
            } set: { automatic in
                options.handwritingInk = automatic ? nil : KeyStyle.RGBA(r: 0.0, g: 0.48, b: 1.0, a: 1)
            }) {
                SettingLabel(L("هم‌رنگ حروف کیبورد", "Same as Keyboard Letters"), symbol: "circle.lefthalf.filled", color: .gray)
            }
            if options.handwritingInk != nil {
                ColorPicker(selection: inkBinding, supportsOpacity: false) {
                    SettingLabel(L("رنگ قلم", "Pen Colour"), symbol: "paintbrush.pointed.fill", color: .blue)
                }
            }
            PenSample(width: options.handwritingInkWidth,
                      color: options.handwritingInk.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .primary)
                .frame(height: 70)
                .listRowBackground(Color(.secondarySystemGroupedBackground))
        } header: {
            Text(L("قلم", "Pen")).font(.app(.footnote))
        }
    }

    private var inkBinding: Binding<Color> {
        Binding {
            options.handwritingInk.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .blue
        } set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            options.handwritingInk = KeyStyle.RGBA(r: Double(r), g: Double(g), b: Double(b), a: 1)
        }
    }
}

/// A scribble in the pen's width and colour.
private struct PenSample: View {
    let width: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = size.width, h = size.height
            path.move(to: CGPoint(x: w * 0.12, y: h * 0.62))
            path.addCurve(to: CGPoint(x: w * 0.38, y: h * 0.42),
                          control1: CGPoint(x: w * 0.2, y: h * 0.15), control2: CGPoint(x: w * 0.3, y: h * 0.9))
            path.addCurve(to: CGPoint(x: w * 0.62, y: h * 0.5),
                          control1: CGPoint(x: w * 0.46, y: h * 0.0), control2: CGPoint(x: w * 0.52, y: h * 0.95))
            path.addCurve(to: CGPoint(x: w * 0.88, y: h * 0.38),
                          control1: CGPoint(x: w * 0.72, y: h * 0.1), control2: CGPoint(x: w * 0.8, y: h * 0.75))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Whether the keyboard is added in Settings and has Full Access: the app opens only then
/// (Rooz, 2026-11-09). Only the keyboard can tell, so it marks a shared pasteboard and sends a
/// notification each time it opens with Full Access.
@MainActor
final class KeyboardGate: ObservableObject {
    @Published private(set) var isAdded = true
    @Published private(set) var hasFullAccess = true
    var isReady: Bool { hasFullAccess }

    private static let seenKey = "keyboardFullAccessSeen"
    private let observer = DarwinObserver()

    init() {
        observer.observe(DictationBridge.fullAccess) { [weak self] in
            UserDefaults.standard.set(true, forKey: "keyboardFullAccessSeen")
            Task { @MainActor in self?.check() }
        }
        check()
    }

    func check() {
        #if targetEnvironment(simulator)
        // The simulator tests cannot switch on Full Access.
        isAdded = true
        hasFullAccess = true
        #else
        if UIPasteboard(name: DictationBridge.fullAccessPasteboard, create: false)?.string == "on" {
            UserDefaults.standard.set(true, forKey: Self.seenKey)
        }
        hasFullAccess = UserDefaults.standard.bool(forKey: Self.seenKey)
        // Added and allowed are known together, from the keyboard's own report (iOS's list of
        // keyboards was not readable on the phone and is no longer read).
        isAdded = hasFullAccess
        #endif
    }
}

/// Shown over the app until the keyboard is added and has Full Access.
private struct KeyboardGateView: View {
    @ObservedObject var gate: KeyboardGate
    @State private var probe = ""
    @FocusState private var probing: Bool

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "keyboard.badge.exclamationmark")
                        .font(.system(size: 54, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.top, 40)
                    Text(L("اول کیبورد آواک را آماده کنید", "Set Up the Avak Keyboard First"))
                        .font(.app(.title2))
                        .multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 14) {
                        step(done: gate.isAdded, title: L("افزودن کیبورد", "Add the Keyboard"),
                             text: L("تنظیمات › آواک › کیبوردها › آواک را روشن کنید.", "Settings › Avak › Keyboards › turn on Avak."))
                        step(done: gate.hasFullAccess, title: L("روشن کردن دسترسی کامل", "Turn On Full Access"),
                             text: L("در همان صفحه «اجازه‌ی دسترسی کامل» را روشن کنید. دیکته، رنگ‌ها و واژه‌نامه بدون آن کار نمی‌کنند.", "On the same page turn on Allow Full Access. Dictation, colours and the dictionary do not work without it."))
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text(L("باز کردن تنظیمات", "Open Settings"))
                            .font(.app(.headline))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)

                    Group {
                        VStack(spacing: 8) {
                            Text(L("بعد از افزودن کیبورد و روشن کردن دسترسی کامل، اینجا بزنید و با کلید کره کیبورد آواک را انتخاب کنید تا تأیید شود.", "After adding the keyboard and turning on Full Access, tap here and switch to the Avak keyboard with the globe key to confirm."))
                                .font(.app(.footnote))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            TextField(L("اینجا بزنید", "Tap here"), text: $probe)
                                .focused($probing)
                                .multilineTextAlignment(.center)
                                .padding(12)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .environment(\.layoutDirection, AppLanguage.english ? .leftToRight : .rightToLeft)
        .font(.app(.body))
        .onChange(of: gate.isReady) { _, ready in if ready { probing = false } }
    }

    private func step(done: Bool, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.app(.headline))
                Text(text).font(.app(.footnote)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A settings row label with a white symbol on a coloured rounded square, as in iOS Settings.
/// Rings that spread from the mic and fade, each time `trigger` changes.
private struct SessionRipple: View {
    let trigger: Int
    @State private var spread = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(AngularGradient(colors: [.pink, .purple, .blue, .teal, .pink], center: .center), lineWidth: 3)
                    .scaleEffect(spread ? 2.1 : 1)
                    .opacity(spread ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.1).delay(Double(ring) * 0.22), value: spread)
            }
        }
        .opacity(trigger == 0 ? 0 : 1)
        .onChange(of: trigger) { _, _ in
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { spread = false }
            // The next frame, so the rings start again from the mic.
            DispatchQueue.main.async { spread = true }
        }
        .allowsHitTesting(false)
    }
}

private struct SettingLabel: View {
    let title: String
    let symbol: String
    let color: Color
    /// A disabled row turns grey, its symbol's square too.
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                // The line under the row starts at the title, wherever the label sits in it.
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(RoundedRectangle(cornerRadius: 7).fill(isEnabled ? color : Color(uiColor: .systemGray3)))
        }
    }
}

/// The crash, hang and abnormal-exit reports iOS gave the app and the keyboard (`CrashReports`),
/// newest first, each to share as its JSON file.
private struct CrashReportsPage: View {
    @State private var reports = CrashReports.all()

    var body: some View {
        Section {
            if reports.isEmpty {
                Text(L("گزارشی نیست.", "No reports."))
                    .foregroundStyle(.secondary)
            }
            ForEach(reports) { report in
                ShareLink(item: report.url) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(report.source) · \(report.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.locale)))")
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                        Text(report.summary)
                            .foregroundStyle(.primary)
                    }
                }
            }
        } footer: {
            Text(L("iOS خرابی‌ها، گیرکردن‌ها و بسته شدن‌های ناگهانی برنامه و کیبورد را ثبت می‌کند و حداکثر یک روز بعد به برنامه می‌دهد. چیزی خودکار فرستاده نمی‌شود؛ برای فرستادن، روی گزارش بزنید.", "iOS records crashes, hangs and sudden exits of the app and keyboard and hands them to the app within a day. Nothing is sent automatically; to send one, tap the report."))
        }
        if !reports.isEmpty {
            Section {
                ShareLink(items: reports.map(\.url)) {
                    Text(L("فرستادن همه", "Send All"))
                }
                Button(L("پاک کردن همه", "Delete All"), role: .destructive) {
                    CrashReports.removeAll()
                    reports = []
                }
            }
        }
    }
}

/// A numbered step of the keyboard setup instructions.
private struct SetupStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.app(.footnote))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.app(.subheadline))
        }
    }
}

/// The personal dictionary: what the model writes and how it should be written, each pair
/// editable in place, and pairs the user keeps correcting in dictations offered to add.
/// Typed shortcuts: a word typed in the keyboard that becomes a longer text on space. Separate
/// from the personal dictionary, which is for dictation.
private struct ShortcutsPage: View {
    @Binding var shortcuts: TypedShortcuts
    @State private var shortcut = ""
    @State private var text = ""

    private var canAdd: Bool {
        let typed = shortcut.trimmingCharacters(in: .whitespaces)
        return !typed.isEmpty && !typed.contains(" ") && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Section {
            TextField(L("میان‌بر، یک کلمه (مثل آدف)", "Shortcut, one word (like omw)"), text: $shortcut)
                .rightAligned()
            TextField(L("متن کامل", "Full text"), text: $text)
                .rightAligned()
            Button {
                shortcuts.entries.insert(.init(shortcut: shortcut.trimmingCharacters(in: .whitespaces),
                                               text: text.trimmingCharacters(in: .whitespaces)), at: 0)
                shortcut = ""
                text = ""
            } label: {
                Label(L("افزودن", "Add"), systemImage: "plus.circle.fill")
            }
            .disabled(!canAdd)
        } header: {
            Text(L("میان‌بر تازه", "New Shortcut")).font(.app(.footnote))
        } footer: {
            Text(L("در کیبورد میان‌بر را بنویسید: متن کاملش وسط نوار پیشنهاد می‌آید و با فاصله جایش می‌نشیند؛ پاک کردن بلافاصله میان‌بر را برمی‌گرداند. فقط در تایپ کار می‌کند، نه در گفتار. میان‌برهای «جایگزینی متن» تنظیمات آیفون (عمومی › صفحه‌کلید) هم کار می‌کنند. کیبورد میان‌بر تازه را دفعه‌ی بعد که باز شود می‌خواند.", "Type the shortcut on the keyboard: its full text appears in the middle of the suggestion bar and replaces it on space; deleting right after puts the shortcut back. Works in typing only, not in speech. The iPhone's Text Replacement shortcuts (General › Keyboard) work too. The keyboard reads a new shortcut the next time it opens."))
                .font(.app(.footnote))
        }

        if !shortcuts.entries.isEmpty {
            Section {
                ForEach($shortcuts.entries) { $entry in
                    HStack(spacing: 8) {
                        TextField(L("میان‌بر", "Shortcut"), text: $entry.shortcut)
                            .rightAligned()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 90)
                        Image(systemName: "arrow.left")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        TextField(L("متن کامل", "Full text"), text: $entry.text)
                            .rightAligned()
                    }
                }
                .onDelete { shortcuts.entries.remove(atOffsets: $0) }
            } header: {
                Text(L("میان‌برهای شما", "Your Shortcuts")).font(.app(.footnote))
            } footer: {
                Text(L("برای پاک کردن، ردیف را به کنار بکشید.", "To delete, swipe the row aside.")).font(.app(.footnote))
            }
        }
    }
}

private struct DictionaryPage: View {
    @Binding var dictionary: PersonalDictionary
    @State private var heard = ""
    @State private var written = ""
    @State private var suggestions: [DictionarySuggestions.Suggestion] = []

    private var canAdd: Bool {
        !written.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group { sections }
            .onAppear(perform: refresh)
    }

    @ViewBuilder private var sections: some View {
        Section {
            TextField(L("درستش", "Correct form"), text: $written)
                .rightAligned()
            TextField(L("آنچه مدل می‌نویسد (اختیاری)", "What the model writes (optional)"), text: $heard)
                .rightAligned()
            Button {
                add(heard: heard, written: written)
                heard = ""
                written = ""
            } label: {
                Label(L("افزودن", "Add"), systemImage: "plus.circle.fill")
            }
            .disabled(!canAdd)
        } header: {
            Text(L("واژه‌ی تازه", "New Word")).font(.app(.footnote))
        } footer: {
            Text(L("مدل هنگام تشخیص گفتار نام‌ها و اصطلاح‌های شما را به واژه‌های نزدیک دیگر ترجیح می‌دهد. اگر باز هم شکل دیگری نوشت، آن شکل را در «آنچه مدل می‌نویسد» بگذارید تا بعد از تشخیص با نوشته‌ی درست جایگزین شود. فاصله و نیم‌فاصله و ی و ک عربی در مقایسه مهم نیستند و فقط کلمه‌ی کامل جایگزین می‌شود. این واژه‌نامه فقط برای گفتار است؛ مثلاً «شکلک لبخند» در «آنچه مدل می‌نویسد» و 😊 در «درستش». میان‌بر تایپ صفحه‌ی جدای خودش را دارد.", "When recognizing speech the model prefers your names and terms over similar words. If it still writes another form, put that form under What the model writes and it is replaced with the correct form after recognition. Spaces, ZWNJ and Arabic ye and kaf do not matter in the comparison, and only whole words are replaced. This dictionary is for speech only; typing shortcuts have their own page."))
                .font(.app(.footnote))
        }

        if !dictionary.entries.isEmpty {
            Section {
                ForEach($dictionary.entries) { $entry in
                    HStack(spacing: 8) {
                        TextField(L("آنچه مدل می‌نویسد", "What the model writes"), text: $entry.heard)
                            .rightAligned()
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.left")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        TextField(L("درستش", "Correct form"), text: $entry.written)
                            .rightAligned()
                    }
                }
                .onDelete { dictionary.entries.remove(atOffsets: $0) }
            } header: {
                Text(L("واژه‌های شما", "Your Words")).font(.app(.footnote))
            } footer: {
                Text(L("برای پاک کردن، ردیف را به کنار بکشید.", "To delete, swipe the row aside.")).font(.app(.footnote))
            }
        }

        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(suggestion.heard) ← \(suggestion.written)")
                            Text(L("\(suggestion.count) بار اصلاح شده", "corrected \(suggestion.count) times"))
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            add(heard: suggestion.heard, written: suggestion.written)
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        Button {
                            DictionarySuggestions.dismiss(suggestion)
                            refresh()
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text(L("پیشنهاد از اصلاح‌های شما", "Suggested from Your Corrections")).font(.app(.footnote))
            } footer: {
                Text(L("کلمه‌هایی که در متن دیکته‌شده \(DictionarySuggestions.minimum) بار یا بیشتر به یک شکل اصلاح کرده‌اید. برای این کار تایپ صوتی و دسترسی کامل کیبورد باید روشن باشند.", "Words you corrected the same way \(DictionarySuggestions.minimum) times or more in dictated text. This needs voice typing and the keyboard's Full Access on."))
                    .font(.app(.footnote))
            }
        }
    }

    private func add(heard: String, written: String) {
        let key = PersonalDictionary.key(heard)
        let written = written.trimmingCharacters(in: .whitespaces)
        // Without what the model writes, the word is only favoured in recognition; one entry a word.
        let same: (PersonalDictionary.Entry) -> Bool = key.isEmpty
            ? { PersonalDictionary.key($0.heard).isEmpty && PersonalDictionary.key($0.written) == PersonalDictionary.key(written) }
            : { PersonalDictionary.key($0.heard) == key }
        if let index = dictionary.entries.firstIndex(where: same) {
            dictionary.entries[index].written = written
        } else {
            dictionary.entries.insert(.init(heard: heard.trimmingCharacters(in: .whitespaces), written: written), at: 0)
        }
        refresh()
    }

    private func refresh() {
        suggestions = DictionarySuggestions.list(excluding: dictionary)
    }
}

/// A row of keys drawn with the chosen style, on a keyboard-like background.
/// TapMap as the keyboard learned it: every key with its letter, drawn where the user's
/// touches for it centre. Letters start in the middle of their keys and drift as touches are
/// learned (the model's own prior keeps the drift gradual); a line shows how far each moved.
private struct TapMapPage: View {
    @State private var model = TouchModel.fromKeyboard() ?? TouchModel()
    @State private var english = false

    private static let persian = [["ض", "ص", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "چ"],
                                  ["ش", "س", "ی", "ب", "ل", "ا", "ت", "ن", "م", "ک", "گ"],
                                  ["ظ", "ط", "ز", "ر", "ذ", "د", "پ", "و", "ث"]]
    private static let latin = [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                                ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
                                ["z", "x", "c", "v", "b", "n", "m"]]

    var body: some View {
        Section {
            Picker("", selection: $english) {
                Text(L("فارسی", "Persian")).tag(false)
                Text("English").tag(true)
            }
            .pickerStyle(.segmented)
            map(model)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            LabeledContent(L("لمس‌های یادگرفته", "Learned Touches"), value: "\(model.touches(layout: english ? "en.p" : "fa.p"))")
        } footer: {
            Text(model.isEmpty
                 ? L("هر حرف وسط کلید خودش است. با تایپ کردن، کیبورد یاد می‌گیرد هر کلید را کجا می‌زنید و حرف‌ها کم‌کم به همان‌جا جابه‌جا می‌شوند.", "Each letter is in the middle of its key. As you type, the keyboard learns where you tap each key and the letters gradually move there.")
                 : L("هر حرف جایی است که معمولاً آن کلید را می‌زنید؛ ابر رنگی محدوده‌ی لمس‌هاست و هرچه پررنگ‌تر، لمس بیشتری دیده شده؛ خط از وسط کلید تا جای تازه‌ی حرف است. کیبورد لمس نزدیک مرز کلیدها را با همین نقشه به حرف درست می‌دهد.", "Each letter is where you usually tap its key; the coloured cloud is the spread of touches, darker where more were seen; the line runs from the key's middle to the letter's new place. The keyboard uses this map to give touches near key borders to the right letter."))
                .font(.app(.footnote))
        }
        .onAppear { model = TouchModel.fromKeyboard() ?? TouchModel() }
    }

    private func map(_ model: TouchModel) -> some View {
        let rows = english ? Self.latin : Self.persian
        let layout = english ? "en.p" : "fa.p"
        return Canvas { context, size in
            let columns: CGFloat = english ? 10 : 11
            let unit = size.width / columns
            let rowHeight = size.height / 3
            for (index, row) in rows.enumerated() {
                // Persian rows start at the left as on the keyboard; English rows are centred.
                let start = english ? (size.width - CGFloat(row.count) * unit) / 2 : 0
                for (column, key) in row.enumerated() {
                    let cell = CGRect(x: start + CGFloat(column) * unit, y: CGFloat(index) * rowHeight, width: unit, height: rowHeight)
                    let face = cell.insetBy(dx: 2, dy: 4)
                    context.fill(Path(roundedRect: face, cornerRadius: 5), with: .color(Color(.secondarySystemFill)))
                    let offset = model.offset(key: key, layout: layout)
                    let middle = CGPoint(x: cell.midX, y: cell.midY)
                    let point = CGPoint(x: middle.x + offset.x * cell.width, y: middle.y + offset.y * cell.height)
                    let seen = min(1, model.touches(key: key, layout: layout) / TouchModel.keyLimit)
                    if seen > 0 {
                        // A heat cloud where the touches land, as in SwiftKey's typing heatmap:
                        // as wide as their usual spread, stronger the more touches were seen.
                        let radius = TouchModel.spread * cell.width
                        let cloud = CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)
                        context.fill(Path(ellipseIn: cloud), with: .radialGradient(
                            Gradient(colors: [Color.orange.opacity(0.25 + 0.5 * seen), Color.red.opacity(0.15 * seen), .clear]),
                            center: point, startRadius: 0, endRadius: radius))
                    }
                    if hypot(point.x - middle.x, point.y - middle.y) > 1.5 {
                        var line = Path()
                        line.move(to: middle)
                        line.addLine(to: point)
                        context.stroke(line, with: .color(.blue.opacity(0.25 + 0.35 * seen)), lineWidth: 1)
                        context.fill(Path(ellipseIn: CGRect(x: middle.x - 1.5, y: middle.y - 1.5, width: 3, height: 3)), with: .color(.secondary))
                    }
                    let tint = seen > 0 ? Color.blue.opacity(0.45 + 0.55 * seen) : Color.primary
                    context.draw(Text(english ? key.uppercased() : key).font(.custom(AppFont.name ?? "", size: 16))
                        .foregroundStyle(tint), at: point)
                }
            }
        }
        .frame(height: 170)
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct KeyPreview: View {
    let style: KeyStyle

    var body: some View {
        HStack(spacing: 6) {
            ForEach(["ض", "ص", "ق", "ف", "غ", "ع"], id: \.self) { letter in
                Text(letter)
                    .font(.custom(AppFont.name ?? "", size: CGFloat(style.letterSize ?? KeyStyle.standardLetterSize)))
                    .foregroundStyle(Color(style.textColor))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(style.fill.color)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(style.stroke.color), lineWidth: style.stroke.a > 0 ? 1 : 0))
            }
        }
        .padding(.vertical, 6)
        // As on the keyboard: letters left to the system colour follow the background's lightness.
        .environment(\.colorScheme, KeyPreviewBackground.isDark(style).map { $0 ? ColorScheme.dark : ColorScheme.light } ?? colorScheme)
    }

    @Environment(\.colorScheme) private var colorScheme
}

/// The keyboard's background behind the preview: the picture, else the colour, else the system's.
private struct KeyPreviewBackground: View {
    let style: KeyStyle

    var body: some View {
        if let id = style.backgroundImage, let image = KeyboardBackground.isPhoto(id)
            ? KeyboardBackground.image(id, size: .zero) : KeyboardBackground.thumbnail(id) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            style.backgroundColor.map { Color($0) } ?? Color(.systemGray5)
        }
    }

    /// Whether the keyboard turns letters of the system colour light: nil when they keep it.
    static func isDark(_ style: KeyStyle) -> Bool? {
        guard style.text == nil else { return nil }
        if let id = style.backgroundImage, let dark = KeyboardBackground.isDark(id) { return dark }
        return style.backgroundColor.map { KeyboardBackground.luminance($0) < 0.5 }
    }
}

/// One picture to choose in the background row, outlined when chosen.
private struct BackgroundChoice: View {
    let image: UIImage?
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color(.systemGray5).overlay(Image(systemName: "nosign").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(title)
                    .font(.app(.caption))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

extension Font {
    /// The app font (`AppFont`) at the size of a text style, scaling with Dynamic Type.
    static func app(_ style: Font.TextStyle) -> Font {
        // English words in the system font, which the app font (Persian only) lacks.
        guard let name = AppFont.name, !AppLanguage.english else { return .system(style) }
        let uiStyle: UIFont.TextStyle
        switch style {
        case .largeTitle: uiStyle = .largeTitle
        case .title: uiStyle = .title1
        case .title2: uiStyle = .title2
        case .title3: uiStyle = .title3
        case .headline: uiStyle = .headline
        case .subheadline: uiStyle = .subheadline
        case .callout: uiStyle = .callout
        case .footnote: uiStyle = .footnote
        case .caption: uiStyle = .caption1
        case .caption2: uiStyle = .caption2
        default: uiStyle = .body
        }
        return .custom(name, size: UIFont.preferredFont(forTextStyle: uiStyle).pointSize, relativeTo: style)
    }
}

extension View {
    /// Persian text fields start on the right: under the right-to-left layout SwiftUI still
    /// starts them on the left.
    func rightAligned() -> some View {
        multilineTextAlignment(AppLanguage.english ? .leading : .trailing).environment(\.layoutDirection, .leftToRight)
    }
}
