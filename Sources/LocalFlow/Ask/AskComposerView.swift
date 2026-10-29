import SwiftUI

/// The Ask window: blue dot and waveform while talking, an editable box while typing, and
/// a send button. ⌘ turns it green for the agent (⌘I adds Instant Edits). Same size,
/// colors and spot as the live dictation window.
struct AskComposerView: View {
    static let size = NSSize(width: 460, height: 210)

    @ObservedObject var model: ComposerModel
    var onSend: () -> Void = {}
    var onOpenChats: () -> Void = {}
    var onOpenConnectors: () -> Void = {}
    var onClose: () -> Void = {}

    private var tint: Color { ComposerTint.color(agentMode: model.agentMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ComposerTextArea(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ComposerFooter(model: model, onSend: onSend)
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(ComposerTint.edge(agentMode: model.agentMode),
                              lineWidth: ComposerTint.edgeWidth(agentMode: model.agentMode))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(model.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AnswerView.secondary)
            InstantBadge(model: model)
            Spacer()
            switch model.mode {
            case .voice: WaveformView(level: model.level)
            case .finishing: ProgressView().controlSize(.small)
            case .typing: EmptyView()
            }
            WindowIconButton(symbol: "puzzlepiece.extension", label: "Connectors",
                             help: "Connectors: give the agent more tools", action: onOpenConnectors)
            WindowIconButton(symbol: "clock.arrow.circlepath", label: "Chats", help: "All your chats",
                             action: onOpenChats)
            WindowIconButton(symbol: "xmark", label: "Close", help: "Close (Esc)", action: onClose)
        }
        .frame(height: 22)
    }
}
