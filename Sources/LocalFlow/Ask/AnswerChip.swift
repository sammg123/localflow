import AppKit
import SwiftUI

/// The minimized answer: a small capsule in the bottom-right corner with the question
/// and whether the answer is still coming. Click it to bring the answer back.
struct AnswerChipView: View {
    static let size = NSSize(width: 300, height: 40)

    @ObservedObject var model: AnswerModel
    var onExpand: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    status.frame(width: 26)
                    Text(model.question.isEmpty ? "Ask" : model.question)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AnswerView.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AnswerView.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show answer")
            .accessibilityValue(statusLabel)
            .help("Show answer (⇧Esc)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AnswerView.primary.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close answer")
            .help("Close answer")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Capsule().fill(Color.black.opacity(0.96)))
        .overlay(Capsule().strokeBorder(AnswerView.askBlue.opacity(0.35)))
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .looking, .thinking, .answering:
            ThinkingDots(size: 5)
        case .done:
            Circle().fill(AnswerView.askBlue).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        }
    }

    private var statusLabel: String {
        switch model.phase {
        case .looking, .thinking, .answering: return "Still answering"
        case .done: return "Answer ready"
        case .failed: return "Couldn't answer"
        }
    }
}

/// Floats just above ordinary windows, so it stays reachable whatever app is in front.
@MainActor
final class AnswerChipPanel {
    private let panel: NSPanel
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init(model: AnswerModel, onExpand: @escaping () -> Void, onClose: @escaping () -> Void) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: AnswerChipView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstClickHostingView(
            rootView: AnswerChipView(model: model, onExpand: onExpand, onClose: onClose)
        )
    }

    func show(on screen: NSScreen?) {
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            let size = AnswerChipView.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20, y: visible.minY + 20))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
