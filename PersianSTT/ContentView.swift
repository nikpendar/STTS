import SwiftUI
import AVFoundation
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
    @AppStorage(PersonalModel.serverKey) private var trainingServer = PersonalModel.defaultServer
    @AppStorage(PersonalModel.autoUpdateKey) private var trainingAutoUpdate = false
    @AppStorage(KeyboardSession.idleMinutesKey) private var sessionMinutes = KeyboardSession.defaultIdleMinutes
    @AppStorage(KeyboardSession.noiseSuppressionKey) private var noiseSuppression = true
    @AppStorage(KeyboardSession.liveTranscriptionKey) private var liveTranscription = true
    @AppStorage(KeyboardSession.autoStopKey) private var autoStop = KeyboardSession.defaultAutoStop
    @State private var style = KeyStyle.saved
    @State private var options = KeyboardOptions.saved
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
                    NavigationLink { typingPage } label: {
                        SettingLabel("تایپ و پیشنهاد کلمه", symbol: "character.cursor.ibeam", color: .blue)
                    }
                    NavigationLink { appearancePage } label: {
                        SettingLabel("ظاهر دکمه‌ها", symbol: "paintpalette.fill", color: .pink)
                    }
                }

                Section {
                    if !needsModel {
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
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fileImporter(isPresented: $pickingModel, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { importer.importModel(from: url) }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .font(.app(.body))
        .onChange(of: style) { _, new in new.save() }
        .onChange(of: options) { _, new in new.save() }
        // Rewrites the shared pasteboard copies, which a reinstall or reboot can clear.
        .onAppear {
            style.save()
            options.save()
            syncTraining()
        }
        .onOpenURL { url in
            if url.host == "session" {
                keyboard.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.appDidBecomeActive()
                model.loadNewModelIfNeeded()
                syncTraining()
            }
        }
    }

    /// A settings page: a form with a title.
    private func page<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form { content() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .font(.app(.body))
    }

    private var speechPage: some View {
        page("گفتار") {
            Section {
                Toggle(isOn: $liveTranscription) {
                    SettingLabel("نمایش متن هنگام صحبت", symbol: "text.bubble.fill", color: .blue)
                }
                Picker(selection: $autoStop) {
                    Text("۱ ثانیه").tag(1.0)
                    Text("۲ ثانیه").tag(2.0)
                    Text("۳ ثانیه").tag(3.0)
                    Text("۵ ثانیه").tag(5.0)
                    Text("خاموش").tag(0.0)
                } label: {
                    SettingLabel("پایان خودکار بعد از سکوت", symbol: "stop.circle.fill", color: .red)
                }
            } header: {
                Text("دیکته").font(.app(.footnote))
            } footer: {
                Text("وقتی بعد از صحبت به این اندازه سکوت شود، ضبط تمام و متن نوشته می‌شود. اگر ۸ ثانیه هیچ صحبتی نشود، ضبط بدون پردازش بسته می‌شود. نمایش متن هنگام صحبت باتری بیشتری مصرف می‌کند.").font(.app(.footnote))
            }

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
                Text("بگویید: نقطه، ویرگول، علامت سؤال، علامت تعجب، دونقطه، نقطه‌ویرگول، خط بعد، پاراگراف جدید، پرانتز باز و بسته، گیومه باز و بسته. «این نقطه» یا «نقطه‌نظر» همان کلمه می‌ماند و «کلمه‌ی نقطه» همیشه خودِ کلمه را می‌نویسد.\n\n"
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

    private var typingPage: some View {
        page("تایپ و پیشنهاد کلمه") {
            Section {
                Toggle(isOn: $options.predictNextWord) {
                    SettingLabel("پیش‌بینی کلمه‌ی بعدی", symbol: "text.append", color: .blue)
                }
                Toggle(isOn: $options.correctTypos) {
                    SettingLabel("اصلاح غلط تایپی", symbol: "checkmark.seal.fill", color: .green)
                }
            } header: {
                Text("ردیف پیشنهاد").font(.app(.footnote))
            } footer: {
                Text("بعد از هر فاصله، کلمه‌هایی که بیشتر بعد از کلمه‌ی قبلی می‌آیند پیشنهاد می‌شوند؛ از روی ویکی‌پدیای فارسی و کلمه‌هایی که خودتان پشت سر هم می‌نویسید. برای کلمه‌ای که در فهرست نیست، نزدیک‌ترین کلمه‌ی درست هم پیشنهاد می‌شود و چیزی خودکار عوض نمی‌شود.").font(.app(.footnote))
            }
        }
    }

    private var appearancePage: some View {
        page("ظاهر دکمه‌ها") {
            Section {
                KeyPreview(style: style)
                    .listRowBackground(Color(.systemGray5))
                ColorPicker(selection: colorBinding(\.fill), supportsOpacity: false) {
                    SettingLabel("رنگ پس‌زمینه", symbol: "square.fill", color: .pink)
                }
                opacitySlider(\.fill)
                ColorPicker(selection: colorBinding(\.stroke), supportsOpacity: false) {
                    SettingLabel("رنگ دور دکمه", symbol: "square", color: .indigo)
                }
                opacitySlider(\.stroke)
                ColorPicker(selection: textColorBinding, supportsOpacity: false) {
                    SettingLabel("رنگ حروف", symbol: "textformat", color: .teal)
                }
                Button("بازگشت به پیش‌فرض") { style = .standard }
            } footer: {
                Text("تغییرها دفعه‌ی بعد که کیبورد باز شود اعمال می‌شوند.").font(.app(.footnote))
            }
        }
    }

    private var setupSection: some View {
        Section {
            SetupStep(number: "۱", text: "Settings › General › Keyboard › Keyboards › Add New Keyboard")
            SetupStep(number: "۲", text: "«کیلس» را انتخاب و Allow Full Access را روشن کنید.")
            SetupStep(number: "۳", text: "در هر اپی با 🌐 به این کیبورد بروید و میکروفون را بزنید.")
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

    /// Learning from corrections: uploading them to the user's training server and installing
    /// the models it publishes.
    private var trainingSection: some View {
        Section {
            Toggle(isOn: $trainingUpload) {
                SettingLabel("ارسال اصلاح‌ها به سرور", symbol: "arrow.up.circle.fill", color: .blue)
            }
            .onChange(of: trainingUpload) { _, on in
                if on { Task { await personal.upload() } }
            }
            if trainingUpload {
                HStack {
                    SettingLabel("سرور", symbol: "desktopcomputer", color: .gray)
                    TextField(PersonalModel.defaultServer, text: $trainingServer)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .environment(\.layoutDirection, .leftToRight)
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
            }
            Toggle(isOn: $trainingAutoUpdate) {
                SettingLabel("دانلود خودکار مدل جدید", symbol: "arrow.down.circle.fill", color: .green)
            }
            LabeledContent("مدل در حال استفاده",
                           value: personal.version > 0 ? "شخصی، نسخه‌ی \(personal.version)" : "مدل اصلی")
            if let progress = personal.downloadProgress {
                ProgressView(value: progress) {
                    Text("در حال دانلود مدل جدید…")
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
            }
            Button("شروع آموزش روی سرور") {
                Task { await personal.train() }
            }
            if personal.version > 0 {
                Button("بازگشت به مدل اصلی", role: .destructive) {
                    personal.useBundledModel()
                }
            }
        } header: {
            Text("یادگیری از اصلاح‌ها").font(.app(.footnote))
        } footer: {
            Text((personal.serverStatus.isEmpty ? "" : personal.serverStatus + "\n\n")
                 + "وقتی متن دیکته‌شده را با تایپ یا دیکته‌ی دوباره اصلاح کنید، صدای آن دیکته و متن درست به سرور خودتان روی Mac فرستاده می‌شود و جای دیگری نمی‌رود. سرور با این نمونه‌ها مدل را آموزش می‌دهد و فقط وقتی نسخه‌ی جدید روی نمونه‌های کنارگذاشته دقیق‌تر باشد آن را منتشر می‌کند. راه‌اندازی سرور: پوشه‌ی server در مخزن.").font(.app(.footnote))
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
            return "کیبورد آماده است. به اپ قبلی برگردید و با میکروفون کیبورد دیکته کنید."
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
            if let progress = importer.progress {
                ProgressView(value: progress) {
                    Text("در حال کپی مدل…").font(.app(.subheadline))
                }
            }
            LabeledContent("مدل", value: model.modelName.isEmpty ? "—" : model.modelName)
            LabeledContent("وضعیت مدل", value: model.status)
        } header: {
            Text("مدل گفتار").font(.app(.footnote))
        } footer: {
            Text((importer.message.isEmpty ? "" : importer.message + "\n\n")
                 + "فایل مدل (ggml…bin، حدود ۴۰۰ مگابایت) فقط یک بار لازم است و با نصب نسخه‌های بعدی روی همین برنامه می‌ماند؛ اگر برنامه را پاک کنید، مدل هم پاک می‌شود. "
                 + "آن را از بخش Artifacts همان اجرا در GitHub با نام Model دانلود کنید، از zip خارج کنید و با AirDrop یا iCloud Drive به آیفون بفرستید و اینجا انتخاب کنید. "
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

    private func opacitySlider(_ path: WritableKeyPath<KeyStyle, KeyStyle.RGBA>) -> some View {
        HStack {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.secondary)
                .frame(width: 29)
            Slider(value: Binding { style[keyPath: path].a } set: { style[keyPath: path].a = $0 }, in: 0...1)
            Text("\(Int(style[keyPath: path].a * 100))٪")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44)
        }
    }
}

/// A settings row label with a white symbol on a coloured rounded square, as in iOS Settings.
private struct SettingLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(RoundedRectangle(cornerRadius: 7).fill(color))
        }
    }
}

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

/// A row of keys drawn with the chosen style, on a keyboard-like background.
private struct KeyPreview: View {
    let style: KeyStyle

    var body: some View {
        HStack(spacing: 6) {
            ForEach(["ض", "ص", "ق", "ف", "غ", "ع"], id: \.self) { letter in
                Text(letter)
                    .font(.app(.title3))
                    .foregroundStyle(Color(style.textColor))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(style.fill.color)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(style.stroke.color), lineWidth: style.stroke.a > 0 ? 1 : 0))
            }
        }
        .padding(.vertical, 6)
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
