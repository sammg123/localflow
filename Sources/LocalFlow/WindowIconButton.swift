import SwiftUI

/// The small round buttons in the top-right corner of LocalFlow's floating windows.
struct WindowIconButton: View {
    let symbol: String
    let label: String
    var help: String?
    let action: () -> Void

    private let primary = Color(red: 0.96, green: 0.96, blue: 0.97) // #f5f5f7

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(primary.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

/// A copy button that shows a checkmark for a moment after it's pressed.
struct CopyIconButton: View {
    var label = "Copy"
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        WindowIconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: label) {
            action()
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}
