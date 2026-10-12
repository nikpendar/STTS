import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var recognizer = Recognizer()

    var body: some View {
        VStack(spacing: 16) {
            Text("آزمون شنوا")
                .font(.title2.bold())

            Picker("مدل", selection: $recognizer.model) {
                ForEach(ShenavaModel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("سخت‌افزار", selection: $recognizer.compute) {
                ForEach(ComputeChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(recognizer.isRecording)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(recognizer.text.isEmpty ? " " : recognizer.text)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding()
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .onChange(of: recognizer.text) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }

            VStack(spacing: 4) {
                Text(recognizer.status)
                if recognizer.isRecording {
                    Text(String(format: "هر گام %.0f ms (میانگین %.0f) برای %d ms صدا · عقب‌ماندگی %.1f ثانیه",
                                recognizer.stepMs, recognizer.averageStepMs,
                                recognizer.audioMsPerStep, recognizer.lagSeconds))
                        .foregroundStyle(recognizer.lagSeconds > 1 ? .red : .secondary)
                }
            }
            .font(.footnote)
            .multilineTextAlignment(.center)

            HStack {
                Button {
                    UIPasteboard.general.string = recognizer.text
                } label: {
                    Image(systemName: "doc.on.doc").font(.title2)
                }
                .disabled(recognizer.text.isEmpty)
                .frame(maxWidth: .infinity)

                Button(action: recognizer.toggle) {
                    ZStack {
                        Circle()
                            .fill(recognizer.isRecording ? Color.red : Color.accentColor)
                            .frame(width: 84, height: 84)
                        if recognizer.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: recognizer.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .disabled(recognizer.isLoading)

                Button(action: recognizer.clear) {
                    Image(systemName: "trash").font(.title2)
                }
                .disabled(recognizer.text.isEmpty || recognizer.isRecording)
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }
}
