import SwiftUI
import AVFoundation
import UIKit

/// The app is the settings page of the dictation keyboard: the background session the
/// keyboard records through, speech options, the look of the keys, and setup steps.
struct ContentView: View {
    @ObservedObject private var model = Transcriber.shared
    @ObservedObject private var keyboard = KeyboardSession.shared
    @AppStorage(KeyboardSession.idleMinutesKey) private var sessionMinutes = KeyboardSession.defaultIdleMinutes
    @AppStorage(KeyboardSession.noiseSuppressionKey) private var noiseSuppression = true
    @AppStorage(KeyboardSession.liveTranscriptionKey) private var liveTranscription = true
    @State private var style = KeyStyle.saved
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                header
            }
            .listRowBackground(Color.clear)

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
                Text("جلسه")
            } footer: {
                Text("جلسه بعد از این مدت بی‌استفاده بسته می‌شود. جلسه‌ی باز باتری مصرف می‌کند.")
            }

            Section {
                Toggle(isOn: $liveTranscription) {
                    SettingLabel("نمایش متن هنگام صحبت", symbol: "text.bubble.fill", color: .blue)
                }
                Toggle(isOn: $noiseSuppression) {
                    SettingLabel("حذف نویز", symbol: "waveform", color: .green)
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
                Text("گفتار")
            } footer: {
                Text(noiseSuppression
                     ? "برای «فقط صدای من»، جلسه را شروع کنید و در منوی باز شده Voice Isolation را انتخاب کنید."
                     : "نمایش متن هنگام صحبت باتری بیشتری مصرف می‌کند.")
            }

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
                if style.text != nil {
                    opacitySlider(\.text!)
                }
                Button("بازگشت به پیش‌فرض") { style = .standard }
            } header: {
                Text("ظاهر دکمه‌ها")
            } footer: {
                Text("تغییرها دفعه‌ی بعد که کیبورد باز شود اعمال می‌شوند.")
            }
            .onChange(of: style) { _, new in new.save() }

            Section {
                SetupStep(number: "۱", text: "Settings › General › Keyboard › Keyboards › Add New Keyboard")
                SetupStep(number: "۲", text: "«دیکته‌ی فارسی» را انتخاب و Allow Full Access را روشن کنید.")
                SetupStep(number: "۳", text: "در هر اپی با 🌐 به این کیبورد بروید و میکروفون را بزنید.")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    SettingLabel("باز کردن تنظیمات آیفون", symbol: "gearshape.fill", color: .gray)
                }
            } header: {
                Text("راه‌اندازی")
            }

            Section {
                LabeledContent("مدل", value: model.modelName.isEmpty ? "—" : model.modelName)
                LabeledContent("وضعیت مدل", value: model.status)
            } header: {
                Text("درباره")
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        // Rewrites the shared pasteboard copy of the key style, which a reinstall or reboot can clear.
        .onAppear { style.save() }
        .onOpenURL { url in
            if url.host == "session" {
                keyboard.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.appDidBecomeActive()
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

            Text("دیکته‌ی فارسی")
                .font(.title2.bold())
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                keyboard.isActive ? keyboard.stop() : keyboard.start()
            } label: {
                Text(keyboard.isActive ? "پایان جلسه" : "شروع جلسه")
                    .font(.headline)
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

    private var statusText: String {
        if model.isBusy && model.modelName.isEmpty || model.status.hasPrefix("در حال بارگذاری") {
            return "در حال بارگذاری مدل…"
        }
        if keyboard.isActive {
            return "کیبورد آماده است. به اپ قبلی برگردید و با میکروفون کیبورد دیکته کنید."
        }
        return keyboard.message.isEmpty ? "برای دیکته با کیبورد، جلسه را شروع کنید." : keyboard.message
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
            style.text = KeyStyle.RGBA(r: Double(r), g: Double(g), b: Double(b), a: style.text?.a ?? 1)
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
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
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
                    .font(.title3)
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
