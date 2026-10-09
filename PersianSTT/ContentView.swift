import SwiftUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var model = Transcriber.shared
    @ObservedObject private var keyboard = KeyboardSession.shared
    @State private var showImporter = false
    @State private var showKeyStyle = false
    @AppStorage(KeyboardSession.idleMinutesKey) private var sessionMinutes = KeyboardSession.defaultIdleMinutes
    @AppStorage(KeyboardSession.noiseSuppressionKey) private var noiseSuppression = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    Text(model.text.isEmpty ? "متن اینجا نمایش داده می‌شود." : model.text)
                        .font(.title3)
                        .foregroundStyle(model.text.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

                HStack {
                    if model.isBusy && !model.isRecording {
                        ProgressView()
                    }
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Label(model.isRecording ? "توقف و تبدیل" : "ضبط صدا",
                          systemImage: model.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? Color.red : Color.accentColor)
                .disabled(model.isBusy && !model.isRecording)

                HStack {
                    Button("انتخاب فایل صوتی") { showImporter = true }
                        .disabled(model.isBusy || model.isRecording)
                    Spacer()
                    Button("کپی متن") { UIPasteboard.general.string = model.text }
                        .disabled(model.text.isEmpty)
                }

                VStack(spacing: 6) {
                    Button(keyboard.isActive ? "پایان جلسه‌ی کیبورد" : "شروع جلسه‌ی کیبورد") {
                        keyboard.isActive ? keyboard.stop() : keyboard.start()
                    }
                    .buttonStyle(.bordered)
                    Picker("مدت جلسه", selection: $sessionMinutes) {
                        Text("۱۰ دقیقه").tag(10)
                        Text("۳۰ دقیقه").tag(30)
                        Text("۱ ساعت").tag(60)
                        Text("بدون محدودیت").tag(0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sessionMinutes) { _, _ in keyboard.idleMinutesChanged() }
                    Text("جلسه بعد از این مدت بی‌استفاده بسته می‌شود. جلسه‌ی باز باتری مصرف می‌کند.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Toggle("حذف نویز", isOn: $noiseSuppression)
                        .onChange(of: noiseSuppression) { _, _ in keyboard.noiseSuppressionChanged() }
                    if noiseSuppression && keyboard.isActive {
                        // Voice Isolation keeps only the nearest voice; iOS offers it only while voice processing is on.
                        Button("فقط صدای من (Voice Isolation)") {
                            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                        }
                        .font(.caption)
                    }
                    if !keyboard.message.isEmpty {
                        Text(keyboard.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("ظاهر کیبورد") { showKeyStyle = true }
                    .font(.footnote)

                if !model.modelName.isEmpty {
                    Text("مدل: \(model.modelName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .navigationTitle("گفتار به متن")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                model.importFile(result)
            }
            .sheet(isPresented: $showKeyStyle) { KeyStyleView() }
            // Rewrites the shared pasteboard copy, which a reinstall or reboot can clear.
            .onAppear { KeyStyle.saved.save() }
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
        .environment(\.layoutDirection, .rightToLeft)
    }
}

/// Colour and opacity of the keyboard's key background and outline. The keyboard reads the
/// style from a named pasteboard each time it appears.
struct KeyStyleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var style = KeyStyle.saved

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Text("ب")
                            .font(.title2)
                            .frame(width: 44, height: 50)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(style.fill.color)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(style.stroke.color), lineWidth: 1))
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                Section("پس‌زمینه‌ی دکمه") {
                    ColorPicker("رنگ", selection: colorBinding(\.fill), supportsOpacity: false)
                    opacitySlider(\.fill)
                }
                Section("دور دکمه") {
                    ColorPicker("رنگ", selection: colorBinding(\.stroke), supportsOpacity: false)
                    opacitySlider(\.stroke)
                }
                Button("بازگشت به پیش‌فرض") { style = .standard }
            }
            .navigationTitle("ظاهر کیبورد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تمام") { dismiss() } }
            }
            .onChange(of: style) { _, new in new.save() }
        }
        .environment(\.layoutDirection, .rightToLeft)
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

    private func opacitySlider(_ path: WritableKeyPath<KeyStyle, KeyStyle.RGBA>) -> some View {
        HStack {
            Text("شفافیت")
            Slider(value: Binding { style[keyPath: path].a } set: { style[keyPath: path].a = $0 }, in: 0...1)
            Text("\(Int(style[keyPath: path].a * 100))٪")
                .monospacedDigit()
                .frame(width: 44)
        }
    }
}
