import SwiftUI
import UIKit

/// Shows the dictation keyboard inside the app, for simulator screenshots.
/// Enabled with the launch argument `-keyboardPreview <state>`.
struct KeyboardPreview: View {
    let state: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("کیبورد دیکته‌ی فارسی")
                .font(.headline)
                .padding(.horizontal)
            Text("متن دیکته‌شده اینجا نوشته می‌شود")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
                .padding(.horizontal)
            Spacer()
            KeyboardHost(state: state)
                .frame(height: 262)
                .background(Color(.systemGray5))
        }
        .padding(.top)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct KeyboardHost: UIViewControllerRepresentable {
    let state: String

    func makeUIViewController(context: Context) -> KeyboardViewController {
        let keyboard = KeyboardViewController()
        keyboard.previewState = state
        return keyboard
    }

    func updateUIViewController(_ uiViewController: KeyboardViewController, context: Context) {}
}
