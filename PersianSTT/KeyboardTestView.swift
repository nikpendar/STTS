import SwiftUI

/// A focused text field, so CI can check that the installed keyboard extension opens.
/// Enabled with the launch argument `-keyboardTest 1`.
struct KeyboardTestView: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack {
            TextField("آزمون کیبورد", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .padding()
            Spacer()
        }
        .onAppear { focused = true }
    }
}
