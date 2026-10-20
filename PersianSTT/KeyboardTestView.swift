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
            } else if UserDefaults.standard.bool(forKey: "keyboardAccessory") {
                AccessoryTextView()
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

/// The keyboard's view controller hosted under the test field, typing into `document`.
private struct HostedKeyboard: UIViewControllerRepresentable {
    let document: TestDocument

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        let keyboard = KeyboardViewController()
        keyboard.testProxy = document
        // Corrections are reported after the user stops editing; the test does not wait long.
        keyboard.reportDelay = 40
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

/// A text view with a toolbar over the keyboard, as in Notes (`-keyboardAccessory 1`): the
/// height iOS gives the keyboard under an accessory view.
private struct AccessoryTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .systemFont(ofSize: 18)
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items = [UIBarButtonItem(image: UIImage(systemName: "textformat"), style: .plain, target: nil, action: nil),
                     .flexibleSpace(),
                     UIBarButtonItem(image: UIImage(systemName: "checklist"), style: .plain, target: nil, action: nil)]
        view.inputAccessoryView = bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}
