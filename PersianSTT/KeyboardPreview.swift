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
            KeyboardPreviewField(state: state)
                .frame(height: 44)
            Spacer()
        }
        .padding()
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct KeyboardPreviewField: UIViewRepresentable {
    let state: String

    func makeUIView(context: Context) -> PreviewTextField {
        let field = PreviewTextField()
        field.keyboard.previewState = state
        field.placeholder = "متن دیکته‌شده اینجا نوشته می‌شود"
        field.textAlignment = .right
        field.borderStyle = .roundedRect
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ uiView: PreviewTextField, context: Context) {}
}

final class PreviewTextField: UITextField {
    let keyboard = KeyboardViewController()

    override var inputViewController: UIInputViewController? { keyboard }
}
