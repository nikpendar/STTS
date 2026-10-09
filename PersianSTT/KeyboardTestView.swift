import SwiftUI
import UIKit

/// A focused text field, so CI can check that the installed keyboard extension opens.
/// Enabled with the launch argument `-keyboardTest 1`. With `-testAudio <path>` the field uses
/// the dictation keyboard directly as its input view (switching keyboards in the simulator is
/// unreliable) and a keyboard session starts that plays the file instead of the microphone.
struct KeyboardTestView: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    private let testAudio = UserDefaults.standard.string(forKey: "testAudio")

    var body: some View {
        VStack {
            if testAudio != nil {
                HostedKeyboardField()
                    .frame(height: 44)
                    .padding()
            } else {
                TextField("آزمون کیبورد", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .padding()
            }
            Spacer()
        }
        .onAppear {
            focused = true
            if testAudio != nil { KeyboardSession.shared.start() }
        }
    }
}

private final class KeyboardTextField: UITextField {
    private let keyboard = KeyboardViewController()
    override var inputViewController: UIInputViewController? { keyboard }
}

private struct HostedKeyboardField: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextField {
        let field = KeyboardTextField()
        field.borderStyle = .roundedRect
        field.placeholder = "آزمون دیکته"
        field.accessibilityIdentifier = "testField"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {}
}
