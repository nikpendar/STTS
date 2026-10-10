import SwiftUI
import UIKit

/// A focused text field, so CI can check that the installed keyboard extension opens.
/// Enabled with the launch argument `-keyboardTest 1`. With `-testAudio <path>` the dictation
/// keyboard is shown inside the app instead (switching keyboards in the simulator is
/// unreliable), typing into a label, and a keyboard session starts that plays the file
/// instead of the microphone.
struct KeyboardTestView: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    @StateObject private var document = TestDocument()
    private let testAudio = UserDefaults.standard.string(forKey: "testAudio")

    var body: some View {
        VStack {
            if testAudio != nil {
                Text(document.text.isEmpty ? "آزمون دیکته" : document.text)
                    .accessibilityIdentifier("testField")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding()
                HostedKeyboard(document: document)
            } else {
                TextField("آزمون کیبورد", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .padding()
                Spacer()
            }
        }
        .onAppear {
            focused = true
            if testAudio != nil { KeyboardSession.shared.start() }
        }
    }
}

/// A minimal text document the hosted keyboard types into.
final class TestDocument: NSObject, ObservableObject, UITextDocumentProxy {
    @Published var text = ""

    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { nil }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { UUID() }
    var hasText: Bool { !text.isEmpty }

    func insertText(_ text: String) { self.text += text }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}

private struct HostedKeyboard: UIViewControllerRepresentable {
    let document: TestDocument

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        let keyboard = KeyboardViewController()
        keyboard.testProxy = document
        // Corrections are reported after the user stops editing; the test does not wait long.
        keyboard.reportDelay = 5
        container.addChild(keyboard)
        container.view.addSubview(keyboard.view)
        keyboard.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keyboard.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            keyboard.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            keyboard.view.bottomAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        keyboard.didMove(toParent: container)
        keyboard.view.backgroundColor = .systemGray5
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
