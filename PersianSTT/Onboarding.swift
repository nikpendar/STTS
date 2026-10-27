import SwiftUI
import UIKit

/// The first-run guide: a few short pages from adding the keyboard to the first dictation, in
/// Persian (right to left) or English after the phone's language. Shown once on first launch and
/// again from the settings page (`ContentView`), where the short keyboard setup steps link to it.
struct Onboarding: View {
    /// Set when the guide is finished or skipped; launch argument `-onboardingDone 1` skips it
    /// in the simulator workflows.
    static let doneKey = "onboardingDone"
    /// The speech model the guide downloads: Koochik.aar of the release model.yml publishes.
    static let modelURL = URL(string: "https://github.com/nikpendar/STTS/releases/download/koochik-mlp-int8/Koochik.aar")!

    @Environment(\.dismiss) private var dismiss
    @AppStorage(Onboarding.doneKey) private var done = false
    @ObservedObject private var model = Transcriber.shared
    @ObservedObject private var keyboard = KeyboardSession.shared
    @ObservedObject private var importer = ModelImporter.shared
    @State private var pickingModel = false
    /// CI only: launch argument `-onboardingPage <n>` opens the guide on that page for screenshots.
    @State private var page = UserDefaults.standard.integer(forKey: "onboardingPage")

    private let fa = Onboarding.persian

    /// Persian when it is the phone's (or the app's) first language, otherwise English.
    static var persian: Bool {
        Locale.preferredLanguages.first.map { $0.hasPrefix("fa") } ?? true
    }

    private enum Step { case welcome, keyboard, fullAccess, model, session }

    /// A build with the model inside has nothing to import.
    private var steps: [Step] {
        Transcriber.bundledModel == nil
            ? [.welcome, .keyboard, .fullAccess, .model, .session]
            : [.welcome, .keyboard, .fullAccess, .session]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < steps.count - 1 {
                    Button(fa ? "رد شدن" : "Skip") { finish() }
                        .font(font(.body))
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 44)

            TabView(selection: $page) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    ScrollView {
                        content(step)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color(.systemGray4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 16)
            .accessibilityHidden(true)

            Button {
                if page < steps.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < steps.count - 1 ? (fa ? "بعدی" : "Next") : (fa ? "تمام" : "Done"))
                    .font(font(.headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .environment(\.layoutDirection, fa ? .rightToLeft : .leftToRight)
        .font(font(.body))
        .fileImporter(isPresented: $pickingModel, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { importer.importModel(from: url) }
        }
        .onAppear { page = min(max(page, 0), steps.count - 1) }
    }

    private func finish() {
        done = true
        dismiss()
    }

    @ViewBuilder
    private func content(_ step: Step) -> some View {
        switch step {
        case .welcome:
            StepPage(symbol: "mic.fill", color: .purple, font: font,
                     title: fa ? "به کیلس خوش آمدید" : "Welcome to Keyless",
                     text: fa ? "کیبورد فارسی با دیکته‌ی آفلاین. صدای شما روی همین آیفون به متن تبدیل می‌شود و برای آن اینترنت لازم نیست.\n\nچند قدم کوتاه تا اولین دیکته: افزودن کیبورد، روشن کردن دسترسی کامل، وارد کردن مدل گفتار و شروع جلسه."
                              : "A Persian keyboard with offline dictation. Your speech turns into text on this iPhone, with no internet needed.\n\nA few short steps to your first dictation: add the keyboard, turn on Full Access, import the speech model and start a session.") {
                EmptyView()
            }

        case .keyboard:
            StepPage(symbol: "keyboard", color: .gray, font: font,
                     title: fa ? "افزودن کیبورد" : "Add the keyboard",
                     text: fa ? "دکمه‌ی زیر تنظیمات کیلس را باز می‌کند. در آن «کیبوردها» (Keyboards) را بزنید و «کیلس» را روشن کنید.\n\nراه دیگر: تنظیمات › عمومی › کیبورد › کیبوردها › افزودن کیبورد جدید › کیلس."
                              : "The button below opens Keyless in Settings. Tap Keyboards and turn on Keyless.\n\nOr: Settings › General › Keyboard › Keyboards › Add New Keyboard › Keyless.") {
                settingsButton
            }

        case .fullAccess:
            StepPage(symbol: "lock.open.fill", color: .orange, font: font,
                     title: fa ? "روشن کردن دسترسی کامل" : "Turn on Full Access",
                     text: fa ? "در همان صفحه «اجازه‌ی دسترسی کامل» (Allow Full Access) را روشن کنید و «اجازه دادن» را بزنید.\n\nکیبورد با دسترسی کامل متن دیکته‌شده را از برنامه‌ی کیلس می‌گیرد و تنظیمات شما مثل رنگ‌ها و واژه‌نامه را می‌خواند. بدون آن، دیکته و این تنظیمات کار نمی‌کنند. چیزی که تایپ می‌کنید بدون اجازه‌ی شما از آیفون بیرون نمی‌رود."
                              : "On the same page, turn on Allow Full Access and confirm with Allow.\n\nWith Full Access the keyboard receives the dictated text from the Keyless app and reads your settings, such as colours and your dictionary. Without it, dictation and these settings do not work. What you type does not leave the iPhone without your permission.") {
                settingsButton
            }

        case .model:
            StepPage(symbol: "cpu", color: .blue, font: font,
                     title: fa ? "وارد کردن مدل گفتار" : "Import the speech model",
                     text: fa ? "مدل گفتار (Koochik.aar، حدود ۱۰۰ مگابایت) فقط یک بار لازم است و با به‌روزرسانی برنامه می‌ماند.\n\n۱. «دانلود مدل» را بزنید و فایل را در Files ذخیره کنید.\n۲. «وارد کردن از Files» را بزنید و Koochik.aar را انتخاب کنید. آماده شدن مدل حدود یک دقیقه طول می‌کشد."
                              : "The speech model (Koochik.aar, about 100 MB) is needed once and stays through app updates.\n\n1. Tap Download Model and save the file to Files.\n2. Tap Import from Files and choose Koochik.aar. Preparing the model takes about a minute.") {
                VStack(spacing: 12) {
                    Link(destination: Self.modelURL) {
                        wideLabel(fa ? "دانلود مدل" : "Download Model", symbol: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    Button { pickingModel = true } label: {
                        wideLabel(fa ? "وارد کردن از Files" : "Import from Files", symbol: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(importer.progress != nil || model.isRecording)
                    modelStatus
                }
            }

        case .session:
            StepPage(symbol: "waveform", color: .red, font: font,
                     title: fa ? "شروع جلسه و دیکته" : "Start a session and dictate",
                     text: fa ? "جلسه میکروفون را برای کیبورد آماده نگه می‌دارد. آن را اینجا یا در صفحه‌ی اول کیلس شروع کنید؛ بعد از مدتی بی‌استفاده خودش بسته می‌شود.\n\nدر هر برنامه با کلید \(Image(systemName: "globe")) به کیلس بروید، کلید فاصله را نگه دارید و حرف بزنید؛ با رها کردن، متن نوشته می‌شود. برای حرف زدن طولانی انگشت را بالا بکشید تا قفل شود و برای پایان روی دایره بزنید."
                              : "A session keeps the microphone ready for the keyboard. Start it here or on the first page of Keyless; it ends by itself after a while unused.\n\nIn any app switch to Keyless with the \(Image(systemName: "globe")) key, hold the space bar and speak; let go and the text is written. For longer dictation, slide up to lock and tap the circle to finish.") {
                Button {
                    keyboard.isActive ? keyboard.stop() : keyboard.start()
                } label: {
                    wideLabel(keyboard.isActive ? (fa ? "پایان جلسه" : "End Session") : (fa ? "شروع جلسه" : "Start Session"),
                              symbol: keyboard.isActive ? "stop.fill" : "mic.fill")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(keyboard.isActive ? .red : .accentColor)
            }
        }
    }

    /// Opens the app's own page in Settings, which lists its keyboard and Full Access.
    private var settingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            wideLabel(fa ? "باز کردن تنظیمات" : "Open Settings", symbol: "gearshape")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder
    private var modelStatus: some View {
        if importer.progress != nil {
            ProgressView {
                Text(fa ? "در حال آماده کردن مدل…" : "Preparing the model…").font(font(.subheadline))
            }
        } else if model.hasModel {
            Label(fa ? "مدل آماده است." : "The model is ready.", systemImage: "checkmark.circle.fill")
                .font(font(.subheadline))
                .foregroundStyle(.green)
        } else if !importer.message.isEmpty {
            Text(fa ? importer.message : "This is not the speech model. Choose Koochik.aar (if it is a zip, open it in Files first).")
                .font(font(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func wideLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(font(.headline))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    /// The app font for Persian; English text, which that font lacks, in the system font.
    private func font(_ style: Font.TextStyle) -> Font {
        fa ? .app(style) : .system(style)
    }
}

/// One page of the guide: a symbol, a title, the text and the page's buttons.
private struct StepPage<Actions: View>: View {
    let symbol: String
    let color: Color
    let font: (Font.TextStyle) -> Font
    let title: String
    let text: LocalizedStringKey
    @ViewBuilder let actions: Actions

    init(symbol: String, color: Color, font: @escaping (Font.TextStyle) -> Font,
         title: String, text: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.color = color
        self.font = font
        self.title = title
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(RoundedRectangle(cornerRadius: 22).fill(color.gradient))
                .padding(.top, 24)
            Text(title)
                .font(font(.title2))
                .multilineTextAlignment(.center)
            Text(text)
                .font(font(.body))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .padding(.top, 4)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }
}
