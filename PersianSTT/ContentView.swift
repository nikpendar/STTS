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
    @State private var pickingModel = false
    @AppStorage(PersonalModel.uploadKey) private var trainingUpload = false
    @State private var trainingToken = PersonalModel.shared.token
    @AppStorage(PersonalModel.autoUpdateKey) private var trainingAutoUpdate = false
    @AppStorage(KeyboardSession.idleMinutesKey) private var sessionMinutes = KeyboardSession.defaultIdleMinutes
    @AppStorage(KeyboardSession.noiseSuppressionKey) private var noiseSuppression = true
    @State private var style = KeyStyle.saved
    @State private var options = KeyboardOptions.saved
    @State private var dictionary = PersonalDictionary.saved
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
                    NavigationLink { speechPage } label: {
                        SettingLabel("گفتار", symbol: "waveform", color: .red)
                    }
                    NavigationLink { page("واژه‌نامه‌ی شخصی") { DictionaryPage(dictionary: $dictionary) } } label: {
                        LabeledContent {
                            Text(dictionary.entries.isEmpty ? "" : "\(dictionary.entries.count)")
                        } label: {
                            SettingLabel("واژه‌نامه‌ی شخصی", symbol: "character.book.closed.fill", color: .teal)
                        }
                    }
                    NavigationLink { typingPage } label: {
                        SettingLabel("تایپ و پیشنهاد کلمه", symbol: "character.cursor.ibeam", color: .blue)
                    }
                    NavigationLink { appearancePage } label: {
                        SettingLabel("ظاهر دکمه‌ها", symbol: "paintpalette.fill", color: .pink)
                    }
                }

                Section {
                    // A build with the model inside has nothing to import.
                    if !needsModel, Transcriber.bundledModel == nil {
                        NavigationLink { page("مدل گفتار") { modelSection } } label: {
                            LabeledContent {
                                Text(model.modelName.isEmpty ? "—" : model.modelName).lineLimit(1)
                            } label: {
                                SettingLabel("مدل گفتار", symbol: "cpu", color: .purple)
                            }
                        }
                    }
                    NavigationLink { page("یادگیری از اصلاح‌ها") { trainingSection } } label: {
                        LabeledContent {
                            Text(trainingUpload ? "روشن" : "خاموش")
                        } label: {
                            SettingLabel("یادگیری از اصلاح‌ها", symbol: "brain.head.profile", color: .green)
                        }
                    }
                    NavigationLink { page("راه‌اندازی کیبورد") { setupSection } } label: {
                        SettingLabel("راه‌اندازی کیبورد", symbol: "keyboard", color: .gray)
                    }
                    NavigationLink { page("گزارش خرابی‌ها") { CrashReportsPage() } } label: {
                        SettingLabel("گزارش خرابی‌ها", symbol: "ladybug.fill", color: .orange)
                    }
                    privacyLink
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .id(navigationID)
        .fullScreenCover(isPresented: $showingGuide) { Onboarding() }
        .fileImporter(isPresented: $pickingModel, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { importer.importModel(from: url) }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .font(.app(.body))
        .onChange(of: style) { _, new in new.save() }
        .onChange(of: options) { _, new in new.save() }
        .onChange(of: dictionary) { _, new in new.save() }
        // Rewrites the shared pasteboard copies, which a reinstall or reboot can clear.
        .onAppear {
            style.save()
            options.save()
            dictionary.save()
            KeyboardBackground.handToKeyboard(style.backgroundImage)
            syncTraining()
            if !onboardingDone { showingGuide = true }
        }
        .onOpenURL { url in
            if url.host == "session" {
                // Straight to the session, whatever page was open, and a sign that it started.
                navigationID = UUID()
                keyboard.start()
                if keyboard.isActive {
                    sessionStarts += 1
                    if options.keySounds { AudioServicesPlaySystemSound(1113) }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.appDidBecomeActive()
                model.loadNewModelIfNeeded()
                importer.importWaitingModel()
                syncTraining()
                CrashReports.shared.collectFromKeyboard()
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
        page("گفتار") {
            Section {
                Toggle(isOn: $options.voicePunctuation) {
                    SettingLabel("نشانه‌گذاری با گفتن", symbol: "textformat.abc.dottedunderline", color: .orange)
                }
                Toggle(isOn: $options.voiceCommands) {
                    SettingLabel("فرمان‌های ویرایش", symbol: "delete.left.fill", color: .indigo)
                }
            } header: {
                Text("فرمان‌های صوتی").font(.app(.footnote))
            } footer: {
                Text("بگویید: نقطه، ویرگول، علامت سؤال، علامت تعجب، دونقطه، نقطه‌ویرگول، خط بعد، پاراگراف جدید، پرانتز باز و بسته، گیومه باز و بسته. «این نقطه» یا «نقطه‌نظر» همان کلمه می‌ماند و «کلمه‌ی نقطه» همیشه خودِ کلمه را می‌نویسد. عددها با رقم نوشته می‌شوند: «بیست و سه» ← ۲۳؛ «یک» و «نه» و «ده» تنها، کلمه می‌مانند مگر «نه تا».\n\n"
                     + "فرمان‌های ویرایش وقتی جدا و با مکث گفته شوند اجرا می‌شوند: «پاک کن» آخرین جمله را پاک می‌کند، «همه رو پاک کن» همه‌ی متن پیش از مکان‌نما را، و «برگردون» آخرین دیکته یا پاک‌کردن را برمی‌گرداند.").font(.app(.footnote))
            }

            Section {
                Toggle(isOn: $noiseSuppression) {
                    SettingLabel("حذف نویز", symbol: "waveform.badge.minus", color: .green)
                }
                .onChange(of: noiseSuppression) { _, _ in keyboard.noiseSuppressionChanged() }
                if noiseSuppression {
                    // Voice Isolation keeps only the nearest voice; iOS offers it only while voice processing is on.
                    Button {
                        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                    } label: {
                        SettingLabel("فقط صدای من", symbol: "person.wave.2.fill", color: .purple)
                    }
                    .disabled(!keyboard.isActive)
                }
            } header: {
                Text("میکروفون").font(.app(.footnote))
            } footer: {
                if noiseSuppression {
                    Text("برای «فقط صدای من»، جلسه را شروع کنید و در منوی باز شده Voice Isolation را انتخاب کنید.").font(.app(.footnote))
                }
            }

            Section {
                Picker(selection: $sessionMinutes) {
                    Text("۱۰ دقیقه").tag(10)
                    Text("۳۰ دقیقه").tag(30)
                    Text("۱ ساعت").tag(60)
                    Text("هرگز").tag(0)
                } label: {
                    SettingLabel("بستن خودکار جلسه", symbol: "timer", color: .orange)
                }
                .onChange(of: sessionMinutes) { _, _ in keyboard.idleMinutesChanged() }
            } header: {
                Text("جلسه").font(.app(.footnote))
            } footer: {
                Text("جلسه بعد از این مدت بی‌استفاده بسته می‌شود. جلسه‌ی باز باتری مصرف می‌کند.").font(.app(.footnote))
            }
        }
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
        page("تایپ و پیشنهاد کلمه") {
            Section {
                Toggle(isOn: $options.suggestionBar.animation(.easeInOut(duration: 0.3))) {
                    SettingLabel("نمایش ردیف پیشنهاد", symbol: "rectangle.topthird.inset.filled", color: .cyan)
                }
                // Off, the bar's own option stays in view, greyed, so turning it back on finds it
                // as it was.
                Toggle(isOn: $options.predictNextWord) {
                    SettingLabel("پیش‌بینی کلمه‌ی بعدی", symbol: "text.append", color: .blue)
                }
                .disabled(!options.suggestionBar)
                .opacity(options.suggestionBar ? 1 : 0.45)
            } header: {
                Text("ردیف پیشنهاد").font(.app(.footnote))
            } footer: {
                Text(options.suggestionBar
                     ? "کلمه‌هایی که بیشتر بعد از کلمه‌ی قبلی می‌آیند پیشنهاد می‌شوند و کلمه‌های خودتان هم یاد گرفته می‌شوند."
                     : "ردیف بالای کلیدها پنهان است و کیبورد کوتاه‌تر می‌شود.")
                    .font(.app(.footnote))
            }

            Section {
                // Corrects on a space, with or without the row.
                Toggle(isOn: $options.correctTypos) {
                    SettingLabel("اصلاح غلط تایپی", symbol: "checkmark.seal.fill", color: .green)
                }
                Toggle(isOn: $options.autoZWNJ) {
                    SettingLabel("نیم‌فاصله‌ی خودکار", symbol: "wand.and.stars", color: .indigo)
                }
                Toggle(isOn: $options.doubleSpacePunctuation) {
                    SettingLabel("دو فاصله: نقطه، سه فاصله: ویرگول", symbol: "space", color: .orange)
                }
            } header: {
                Text("اصلاح خودکار").font(.app(.footnote))
            } footer: {
                Text("با زدن فاصله، کلمه‌ای که به‌روشنی غلط تایپ شده درست می‌شود و «میخوام» می‌شود «می‌خوام». پاک کردن بلافاصله بعد از آن، تایپ شما را برمی‌گرداند."
                     + (options.autoZWNJ ? "" : " بدون نیم‌فاصله‌ی خودکار، دو بار زدن سریع یک حرف پیوندی نیم‌فاصله می‌گذارد: «م ی ی» ← «می‌»."))
                    .font(.app(.footnote))
            }

            Section {
                Picker(selection: numbersPlace) {
                    Text("خاموش").tag(0)
                    Text("ردیف جدا بالای حروف").tag(1)
                    Text("روی حروف ردیف اول").tag(2)
                } label: {
                    SettingLabel("اعداد", symbol: "number", color: .teal)
                }
            } header: {
                Text("اعداد").font(.app(.footnote))
            } footer: {
                Text(options.digitsOnLetters
                     ? "عدد کوچک بالای هر حرف ردیف اول است (ض ۱ تا ج ۰). نگه داشتن کلید، حرف و عدد فارسی و انگلیسی را نشان می‌دهد."
                     : options.numberRow
                        ? "ردیف کوتاه اعداد کیبورد را کمی بلندتر می‌کند. نگه داشتن هر عدد، شکل فارسی و انگلیسی آن را نشان می‌دهد."
                        : "اعداد در صفحه‌ی ۱۲۳ هستند.")
                    .font(.app(.footnote))
            }

            Section {
                Toggle(isOn: $options.keyPreview) {
                    SettingLabel("بزرگ‌نمایی حرف هنگام تایپ", symbol: "character.magnify", color: .purple)
                }
                Toggle(isOn: $options.keySounds) {
                    SettingLabel("صدای کلیدها", symbol: "speaker.wave.2.fill", color: .pink)
                }
                Toggle(isOn: $options.haptics) {
                    SettingLabel("لرزش (هپتیک)", symbol: "iphone.radiowaves.left.and.right", color: .red)
                }
            } header: {
                Text("بازخورد کلیدها").font(.app(.footnote))
            } footer: {
                Text("صدا با سوییچ بی‌صدای گوشی قطع می‌شود. لرزش برای کلیدها، اصلاح کلمه و دسته‌های شکلک فرق دارد.").font(.app(.footnote))
            }

            Section {
                Toggle(isOn: $options.learnTouches) {
                    SettingLabel("یادگیری محل لمس (TapMap)", symbol: "hand.point.up.left.fill", color: .orange)
                }
                NavigationLink {
                    page("نقشه‌ی لمس شما") { TapMapPage() }
                } label: {
                    SettingLabel("نقشه‌ی لمس شما", symbol: "scope", color: .blue)
                }
                Button(role: .destructive) {
                    options.touchResets += 1
                    TouchModel.clearFromKeyboard()
                } label: {
                    SettingLabel("پاک کردن یادگرفته‌های لمس", symbol: "arrow.counterclockwise", color: .red)
                }
            } header: {
                Text("لمس هوشمند").font(.app(.footnote))
            } footer: {
                Text("کیبورد یاد می‌گیرد هر حرف را کجای کلید می‌زنید و لمس نزدیک مرز دو کلید را به حرف درست می‌دهد.").font(.app(.footnote))
            }
        }
    }

    private var appearancePage: some View {
        page("ظاهر دکمه‌ها") {
            Section {
                KeyPreview(style: style)
                    .listRowBackground(KeyPreviewBackground(style: style))
                    .listRowSeparator(.hidden)
                // Each slider sits in the row of the setting it belongs to, under its title, so
                // every line between rows starts where the titles do.
                VStack(alignment: .leading, spacing: 6) {
                    SettingLabel("اندازه‌ی حروف", symbol: "textformat.size", color: .orange)
                    SliderLine(small: "textformat.size.smaller", large: "textformat.size.larger") {
                        Slider(value: Binding { style.letterSize ?? KeyStyle.standardLetterSize } set: { style.letterSize = $0.rounded() },
                               in: 16...32, step: 1)
                    } value: {
                        Text("\(Int(style.letterSize ?? KeyStyle.standardLetterSize))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
                ColorPicker(selection: backgroundColorBinding, supportsOpacity: false) {
                    SettingLabel("رنگ پس‌زمینه‌ی کیبورد", symbol: "keyboard.fill", color: .brown)
                }
                VStack(spacing: 6) {
                    ColorPicker(selection: colorBinding(\.fill), supportsOpacity: false) {
                        SettingLabel("رنگ دکمه", symbol: "square.fill", color: .pink)
                    }
                    opacitySlider(\.fill)
                }
                VStack(spacing: 6) {
                    ColorPicker(selection: colorBinding(\.stroke), supportsOpacity: false) {
                        SettingLabel("رنگ دور دکمه", symbol: "square", color: .indigo)
                    }
                    opacitySlider(\.stroke)
                }
                ColorPicker(selection: textColorBinding, supportsOpacity: false) {
                    SettingLabel("رنگ حروف", symbol: "textformat", color: .teal)
                }
                Button("بازگشت به پیش‌فرض") { style = .standard }
            } footer: {
                Text("تغییرها دفعه‌ی بعد که کیبورد باز شود اعمال می‌شوند.").font(.app(.footnote))
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        BackgroundChoice(image: nil, title: "بدون عکس", selected: style.backgroundImage == nil) {
                            style.backgroundImage = nil
                        }
                        if let id = style.backgroundImage, KeyboardBackground.isPhoto(id) {
                            BackgroundChoice(image: KeyboardBackground.image(id, size: .zero), title: "عکس شما", selected: true) {}
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
                    SettingLabel("انتخاب عکس از گالری", symbol: "photo.fill", color: .orange)
                }
            } header: {
                Text("عکس پس‌زمینه").font(.app(.footnote))
            } footer: {
                Text("عکس جای رنگ پس‌زمینه را می‌گیرد و وسط آن به اندازه‌ی کیبورد بریده می‌شود. اگر رنگ حروف را انتخاب نکرده باشید، حروف روی عکس تیره روشن و روی عکس روشن تیره می‌شوند.").font(.app(.footnote))
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
            SetupStep(number: "۱", text: "Settings › General › Keyboard › Keyboards › Add New Keyboard")
            SetupStep(number: "۲", text: "«کیلس» را انتخاب و Allow Full Access را روشن کنید.")
            SetupStep(number: "۳", text: "در هر اپی با 🌐 به این کیبورد بروید و برای دیکته کلید فاصله را نگه دارید.")
            Button {
                showingGuide = true
            } label: {
                SettingLabel("راهنمای قدم‌به‌قدم", symbol: "book.fill", color: .orange)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                SettingLabel("باز کردن تنظیمات آیفون", symbol: "gearshape.fill", color: .gray)
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

            Text("کیلس")
                .font(.app(.title2))
            Text(statusText)
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                keyboard.isActive ? keyboard.stop() : keyboard.start()
            } label: {
                Text(keyboard.isActive ? "پایان جلسه" : "شروع جلسه")
                    .font(.app(.headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(keyboard.isActive ? .red : .accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The privacy policy, published from docs/privacy.html of the repository by GitHub Pages.
    static let privacyPolicyURL = URL(string: "https://nikpendar.github.io/STTS/privacy.html")!

    private var privacyLink: some View {
        Link(destination: Self.privacyPolicyURL) {
            SettingLabel("سیاست حریم خصوصی", symbol: "hand.raised.fill", color: .blue)
        }
        .foregroundStyle(.primary)
    }

    /// Learning from corrections: uploading them to the user's private GitHub repository and
    /// installing the models the training workflow publishes there.
    private var trainingSection: some View {
        Section {
            Toggle(isOn: $trainingUpload) {
                SettingLabel("ارسال اصلاح‌ها برای آموزش", symbol: "arrow.up.circle.fill", color: .blue)
            }
            .onChange(of: trainingUpload) { _, on in
                if on { Task { await personal.upload() } }
            }
            HStack {
                SettingLabel("توکن GitHub", symbol: "key.fill", color: .yellow)
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
                        SettingLabel("ارسال اصلاح‌های در صف", symbol: "tray.and.arrow.up.fill", color: .orange)
                    }
                }
            }
            Toggle(isOn: $trainingAutoUpdate) {
                SettingLabel("دانلود خودکار مدل جدید", symbol: "arrow.down.circle.fill", color: .green)
            }
            LabeledContent("مدل در حال استفاده",
                           value: personal.version > 0 ? "شخصی، نسخه‌ی \(personal.version)" : "مدل اصلی")
            if let progress = personal.downloadProgress {
                ProgressView(value: progress) {
                    Text(progress >= 1 ? "در حال آماده کردن مدل…" : "در حال دانلود مدل جدید…")
                }
            } else if let release = personal.available {
                Button {
                    personal.download()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("دانلود نسخه‌ی \(release.version)")
                        Text(releaseSummary(release))
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button("بررسی نسخه‌ی جدید") {
                    Task { await personal.check() }
                }
                .disabled(trainingToken.isEmpty)
            }
            if personal.version > 0 {
                Button("بازگشت به مدل اصلی", role: .destructive) {
                    personal.useBaseModel()
                }
            }
            privacyLink
        } footer: {
            Text((personal.status.isEmpty ? "" : personal.status + "\n\n")
                 + "وقتی متن دیکته‌شده را با تایپ یا دیکته‌ی دوباره اصلاح کنید، صدای آن دیکته و متن درست به مخزن خصوصی خودتان در GitHub فرستاده می‌شود و جای دیگری نمی‌رود. "
                 + "سرور رایگان GitHub هر چند ساعت، اگر اصلاح تازه‌ای باشد، مدل را با همه‌ی نمونه‌ها آموزش می‌دهد و فقط وقتی نسخه‌ی جدید روی نمونه‌های کنارگذاشته دقیق‌تر باشد آن را منتشر می‌کند. "
                 + "توکن فقط در Keychain همین آیفون نگه داشته می‌شود.").font(.app(.footnote))
        }
    }

    private func releaseSummary(_ release: PersonalModel.Release) -> String {
        var parts = ["\(release.size >> 20) مگابایت"]
        if let samples = release.samples { parts.append("\(samples) نمونه") }
        if let before = release.werBefore, let after = release.werAfter {
            parts.append(String(format: "خطای کلمه %.1f٪ ← %.1f٪", before, after))
        }
        return parts.joined(separator: "، ")
    }

    private func syncTraining() {
        Task {
            await personal.upload()
            await personal.check(automatic: true)
        }
    }

    private var statusText: String {
        if model.isBusy && model.modelName.isEmpty || model.status.hasPrefix("در حال بارگذاری") {
            return "در حال بارگذاری مدل…"
        }
        if needsModel {
            return "برای دیکته، یک بار فایل مدل گفتار را وارد کنید."
        }
        if keyboard.isActive {
            return "کیبورد آماده است. به اپ قبلی برگردید و با نگه‌داشتن کلید فاصله دیکته کنید."
        }
        return keyboard.message.isEmpty ? "برای دیکته با کیبورد، جلسه را شروع کنید." : keyboard.message
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
                SettingLabel(needsModel ? "وارد کردن مدل از Files" : "جایگزینی مدل از Files",
                             symbol: "square.and.arrow.down.fill", color: .blue)
            }
            .disabled(importer.progress != nil || model.isRecording)
            if importer.progress != nil {
                ProgressView {
                    Text("در حال آماده کردن مدل…").font(.app(.subheadline))
                }
            }
            LabeledContent("مدل", value: model.modelName.isEmpty ? "—" : model.modelName)
            LabeledContent("وضعیت مدل", value: model.status)
        } header: {
            Text("مدل گفتار").font(.app(.footnote))
        } footer: {
            Text((importer.message.isEmpty ? "" : importer.message + "\n\n")
                 + "فایل مدل (Koochik.aar، حدود ۱۰۰ مگابایت) فقط یک بار لازم است و با نصب نسخه‌های بعدی روی همین برنامه می‌ماند؛ اگر برنامه را پاک کنید، مدل هم پاک می‌شود. "
                 + "آن را از بخش Artifacts همان اجرا در GitHub با نام ShenavaModel دانلود کنید، از zip خارج کنید و با AirDrop یا iCloud Drive به آیفون بفرستید و اینجا انتخاب کنید. "
                 + "راه دیگر: آیفون را به Mac وصل کنید، در Finder آیفون را انتخاب کنید و در بخش Files فایل را روی «کیلس» بکشید.").font(.app(.footnote))
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
            Text("\(Int(style[keyPath: path].a * 100))٪")
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
                Text("گزارشی نیست.")
                    .foregroundStyle(.secondary)
            }
            ForEach(reports) { report in
                ShareLink(item: report.url) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(report.source) · \(report.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "fa_IR"))))")
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                        Text(report.summary)
                            .foregroundStyle(.primary)
                    }
                }
            }
        } footer: {
            Text("iOS خرابی‌ها، گیرکردن‌ها و بسته شدن‌های ناگهانی برنامه و کیبورد را ثبت می‌کند و حداکثر یک روز بعد به برنامه می‌دهد. چیزی خودکار فرستاده نمی‌شود؛ برای فرستادن، روی گزارش بزنید.")
        }
        if !reports.isEmpty {
            Section {
                ShareLink(items: reports.map(\.url)) {
                    Text("فرستادن همه")
                }
                Button("پاک کردن همه", role: .destructive) {
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
private struct DictionaryPage: View {
    @Binding var dictionary: PersonalDictionary
    @State private var heard = ""
    @State private var written = ""
    @State private var suggestions: [DictionarySuggestions.Suggestion] = []

    private var canAdd: Bool {
        !PersonalDictionary.key(heard).isEmpty && !written.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group { sections }
            .onAppear(perform: refresh)
    }

    @ViewBuilder private var sections: some View {
        Section {
            TextField("آنچه مدل می‌نویسد", text: $heard)
            TextField("درستش", text: $written)
            Button {
                add(heard: heard, written: written)
                heard = ""
                written = ""
            } label: {
                Label("افزودن", systemImage: "plus.circle.fill")
            }
            .disabled(!canAdd)
        } header: {
            Text("واژه‌ی تازه").font(.app(.footnote))
        } footer: {
            Text("نام‌ها و اصطلاح‌هایی که مدل اشتباه می‌نویسد، بعد از تشخیص با نوشته‌ی درست جایگزین می‌شوند. فاصله و نیم‌فاصله و ی و ک عربی در مقایسه مهم نیستند و فقط کلمه‌ی کامل جایگزین می‌شود.")
                .font(.app(.footnote))
        }

        if !dictionary.entries.isEmpty {
            Section {
                ForEach($dictionary.entries) { $entry in
                    HStack(spacing: 8) {
                        TextField("آنچه مدل می‌نویسد", text: $entry.heard)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.left")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        TextField("درستش", text: $entry.written)
                    }
                }
                .onDelete { dictionary.entries.remove(atOffsets: $0) }
            } header: {
                Text("واژه‌های شما").font(.app(.footnote))
            } footer: {
                Text("برای پاک کردن، ردیف را به کنار بکشید.").font(.app(.footnote))
            }
        }

        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(suggestion.heard) ← \(suggestion.written)")
                            Text("\(suggestion.count) بار اصلاح شده")
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
                Text("پیشنهاد از اصلاح‌های شما").font(.app(.footnote))
            } footer: {
                Text("کلمه‌هایی که در متن دیکته‌شده \(DictionarySuggestions.minimum) بار یا بیشتر به یک شکل اصلاح کرده‌اید. برای این کار جلسه باید باز و دسترسی کامل کیبورد روشن باشد.")
                    .font(.app(.footnote))
            }
        }
    }

    private func add(heard: String, written: String) {
        let key = PersonalDictionary.key(heard)
        let written = written.trimmingCharacters(in: .whitespaces)
        if let index = dictionary.entries.firstIndex(where: { PersonalDictionary.key($0.heard) == key }) {
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
/// TapMap as the keyboard learned it: on each key, a dot where the user's touches for it
/// centre (larger and darker the more touches it has seen), with a line from the key's middle.
private struct TapMapPage: View {
    @State private var model = TouchModel.fromKeyboard()
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
                Text("فارسی").tag(false)
                Text("English").tag(true)
            }
            .pickerStyle(.segmented)
            if let model, !model.isEmpty {
                map(model)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            } else {
                Text("هنوز چیزی یاد گرفته نشده. با کیبورد تایپ کنید و دوباره اینجا را باز کنید.")
                    .font(.app(.footnote))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("نقطه‌ی آبی جایی است که معمولاً هر کلید را می‌زنید؛ هرچه پررنگ‌تر، لمس بیشتری دیده شده. کیبورد لمس نزدیک مرز کلیدها را با همین نقشه به حرف درست می‌دهد.")
                .font(.app(.footnote))
        }
        .onAppear { model = TouchModel.fromKeyboard() }
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
                    context.draw(Text(english ? key.uppercased() : key).font(.custom(AppFont.name ?? "", size: 15))
                        .foregroundStyle(.secondary), at: CGPoint(x: face.midX, y: face.minY + 11))
                    let offset = model.offset(key: key, layout: layout)
                    let middle = CGPoint(x: cell.midX, y: cell.midY + 4)
                    let point = CGPoint(x: middle.x + offset.x * cell.width, y: middle.y + offset.y * cell.height)
                    let seen = min(1, model.touches(key: key, layout: layout) / TouchModel.keyLimit)
                    var line = Path()
                    line.move(to: middle)
                    line.addLine(to: point)
                    context.stroke(line, with: .color(.blue.opacity(0.35 + 0.4 * seen)), lineWidth: 1)
                    let radius = 2.5 + 2.5 * seen
                    context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)),
                                 with: .color(.blue.opacity(0.35 + 0.65 * seen)))
                    context.fill(Path(ellipseIn: CGRect(x: middle.x - 1, y: middle.y - 1, width: 2, height: 2)), with: .color(.secondary))
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
        guard let name = AppFont.name else { return .system(style) }
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
