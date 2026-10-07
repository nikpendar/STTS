import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = Transcriber()
    @State private var showImporter = false

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
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
