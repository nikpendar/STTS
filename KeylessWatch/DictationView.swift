import SwiftUI

/// One screen: the microphone button, then the text with «ارسال» (the share sheet: Messages,
/// Mail, ...) and «دوباره». Recent texts are listed below.
struct DictationView: View {
    @EnvironmentObject private var dictation: WatchDictation

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                switch dictation.phase {
                case .idle:
                    micButton
                    Text("بزنید و صحبت کنید")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .recording:
                    micButton
                    Text("در حال گوش دادن…")
                        .font(.footnote)
                case .working:
                    ProgressView()
                        .frame(height: 80)
                    Text("آیفون در حال تبدیل به متن…")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                case .done(let text):
                    result(text)
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    HStack {
                        if dictation.canRetry {
                            Button("دوباره بفرست") { dictation.retry() }
                        }
                        Button("ضبط تازه") { dictation.toggle() }
                    }
                    .font(.footnote)
                }
                if !dictation.history.isEmpty, dictation.phase == .idle {
                    history
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("کیلس")
    }

    private var micButton: some View {
        let recording = dictation.phase == .recording
        return Button {
            dictation.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(recording ? Color.red : Color.accentColor)
                Circle()
                    .stroke(Color.white.opacity(0.6), lineWidth: 3)
                    .scaleEffect(recording ? 1 + dictation.level * 0.25 : 1)
                    .animation(.easeOut(duration: 0.1), value: dictation.level)
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 84, height: 84)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "پایان ضبط" : "شروع ضبط")
        // Double Tap (Series 9 and later, Ultra 2) presses the main button.
        .modifier(PrimaryGesture())
    }

    private func result(_ text: String) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            ShareLink(item: text) {
                Label("ارسال", systemImage: "paperplane.fill")
            }
            .modifier(PrimaryGesture())
            Button {
                dictation.toggle()
            } label: {
                Label("دوباره", systemImage: "mic.fill")
            }
            Button("بستن") { dictation.reset() }
                .font(.footnote)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("متن‌های اخیر")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(dictation.history, id: \.self) { text in
                ShareLink(item: text) {
                    Text(text)
                        .font(.footnote)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.top, 8)
    }
}

/// Double Tap presses this control: the microphone, or «ارسال» once the text is shown.
private struct PrimaryGesture: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}
