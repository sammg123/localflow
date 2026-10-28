import AppKit
import SwiftUI

/// The hands-free window, where the pill appears: words show up while you talk, a tap
/// pauses into an editable box, and Return pastes into the app you were in.
@MainActor
final class DictationComposerPanel: ComposerPanel {
    init() {
        super.init(size: DictationComposerView.size)
        setContent(DictationComposerView(model: model,
                                         onPaste: { [weak self] in self?.onSend?() },
                                         onCopy: { [weak self] in self?.copyText() },
                                         onClose: { [weak self] in self?.onCancel?() }))
    }

    /// The words as they are right now, live ones included, onto the clipboard.
    private func copyText() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct DictationComposerView: View {
    static let size = NSSize(width: 460, height: 240)

    @ObservedObject var model: ComposerModel
    var onPaste: () -> Void = {}
    var onCopy: () -> Void = {}
    var onClose: () -> Void = {}
    @FocusState private var boxFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let primary = Color(red: 0.96, green: 0.96, blue: 0.97)   // #f5f5f7
    private let secondary = Color(red: 0.63, green: 0.63, blue: 0.65) // #a1a1a6
    private static let spacing: CGFloat = 10
    /// Room above the first line where overflowing words fade out while talking.
    private static let fadeHeight: CGFloat = 16

    private var title: String {
        switch model.mode {
        case .voice: return "Listening"
        case .finishing: return "Writing it down…"
        case .typing: return "Paused"
        }
    }

    private var hint: String {
        switch model.mode {
        case .voice: return "\(model.keyName) to pause   ·   Return to paste   ·   Esc to cancel"
        case .finishing: return "Return to paste   ·   Esc to cancel"
        case .typing: return "\(model.keyName) to talk   ·   Return to paste   ·   Esc to cancel"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            header
            textArea.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .onAppear { boxFocused = model.mode == .typing }
        .onChange(of: model.mode) { _, mode in boxFocused = mode == .typing }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.mode == .voice ? Color.red : secondary)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondary)
            Spacer()
            switch model.mode {
            case .voice: WaveformView(level: model.level)
            case .finishing: ProgressView().controlSize(.small)
            case .typing: EmptyView()
            }
            if !model.text.isEmpty {
                CopyIconButton(action: onCopy)
            }
            WindowIconButton(symbol: "xmark", label: "Close", help: "Close (Esc)", action: onClose)
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private var textArea: some View {
        if model.mode == .typing {
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("Type, or tap \(model.keyName) to keep talking…")
                        .font(.system(size: 17))
                        .foregroundStyle(secondary)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .font(.system(size: 17))
                    .foregroundStyle(primary)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($boxFocused)
                    .padding(.horizontal, -5) // the text view's own line padding
                    .accessibilityLabel("Dictation")
            }
        } else {
            spokenText
        }
    }

    /// Talking: the newest line stays pinned to the bottom, older lines fade out the top.
    private var spokenText: some View {
        Color.clear
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.text.isEmpty ? "Start talking…" : model.text)
                        .font(.system(size: 17))
                        .lineSpacing(4)
                        .foregroundStyle(model.text.isEmpty ? secondary : primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, Self.fadeHeight)
            }
            .clipped()
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeHeight)
                    Color.black
                }
            )
            // Fade into the gap under the header, never behind it, so the spoken words
            // start about where the edit box's do.
            .padding(.top, -Self.spacing)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.text)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let notice = model.notice, model.mode == .typing {
                Text(notice)
                    .foregroundStyle(Color.orange)
            } else {
                Text(hint)
                    .foregroundStyle(secondary.opacity(0.8))
            }
            Spacer(minLength: 0)
            Button(action: onPaste) {
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(model.canSend ? Color.black : primary.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(model.canSend ? primary : Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .accessibilityLabel("Paste")
            .help("Paste (Return)")
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }
}
