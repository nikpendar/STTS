import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var model = Transcriber.shared
    @ObservedObject private var keyboard = KeyboardSession.shared
    @State private var showImporter = false
    @AppStorage(KeyboardSession.idleMinutesKey) private var sessionMinutes = KeyboardSession.defaultIdleMinutes
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
                    if !keyboard.message.isEmpty {
                        Text(keyboard.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if keyboard.isActive {
                        Text(keyboard.keyboardLaunchedAt.map {
                            "کیبورد اجرا شد: \($0.formatted(date: .omitted, time: .standard))"
                        } ?? "کیبورد در این جلسه هنوز اجرا نشده است.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

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
