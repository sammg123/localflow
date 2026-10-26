import SwiftUI

enum AnswerPhase: Equatable {
    /// Question sent; the screenshot is being taken.
    case looking
    /// The model has the question and screenshot; no words yet (longer when it's cold).
    case thinking
    /// Tokens are arriving.
    case answering
    case done
    case failed(String)
}

@MainActor
final class AnswerModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var phase: AnswerPhase = .looking
    /// Natural height of the answer body, measured inside the scroll view.
    @Published var bodyHeight: CGFloat = 0
    /// When the question was sent, for the "Thinking · 5s" counter.
    private(set) var sentAt = Date()

    var isWorking: Bool { phase == .looking || phase == .thinking || phase == .answering }

    func reset() {
        question = ""
        answer = ""
        phase = .looking
        bodyHeight = 0
        sentAt = Date()
    }
}

/// What the bubble says before the first word arrives.
enum WorkingLabel {
    /// A cold model can take 10+ seconds; counting shows it hasn't stalled.
    static let countAfter: TimeInterval = 3

    static func text(for phase: AnswerPhase, elapsed: TimeInterval) -> String {
        let base = phase == .looking ? "Looking at your screen" : "Thinking"
        guard elapsed >= countAfter else { return base }
        return "\(base) · \(Int(elapsed))s"
    }
}

/// Three blue dots that ripple while Ask is working. Still under Reduce Motion.
struct ThinkingDots: View {
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.7) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = reduceMotion ? 0.5 : (sin(time * 2 * .pi / 1.1 - Double(index) * 0.9) + 1) / 2
                    Circle()
                        .fill(AnswerView.askBlue)
                        .frame(width: size, height: size)
                        .scaleEffect(0.7 + 0.3 * wave)
                        .opacity(0.35 + 0.65 * wave)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Ask's answer bubble. Same black card as the live window, with a blue edge so it
/// reads as Ask rather than dictation.
struct AnswerView: View {
    @ObservedObject var model: AnswerModel
    var closeHint: String
    /// False in render tests: ImageRenderer can't draw a ScrollView.
    var scrolls = true
    var onCopy: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    static let primary = Color(red: 0.96, green: 0.96, blue: 0.97)   // #f5f5f7
    static let secondary = Color(red: 0.63, green: 0.63, blue: 0.65) // #a1a1a6
    static let askBlue = Color(red: 0.04, green: 0.52, blue: 1.0)    // #0a84ff

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if scrolls {
                ScrollView {
                    content
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.bodyHeight = $0 }
                }
                .frame(height: min(model.bodyHeight, AnswerPanel.maxBodyHeight))
            } else {
                content
            }
            Text(closeHint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.secondary.opacity(0.8))
        }
        .padding(18)
        .frame(width: AnswerPanel.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Self.askBlue.opacity(0.35))
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.phase)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Self.askBlue)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(model.question.isEmpty ? "Ask" : model.question)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.phase == .done {
                iconButton(copied ? "checkmark" : "doc.on.doc", label: "Copy answer") {
                    onCopy()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
            }
            iconButton("minus", label: "Minimize", help: "Minimize (⇧Esc)", action: onMinimize)
            iconButton("xmark", label: "Close", action: onClose)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .looking, .thinking:
            HStack(spacing: 12) {
                ThinkingDots()
                TimelineView(.periodic(from: model.sentAt, by: 1)) { timeline in
                    Text(WorkingLabel.text(for: model.phase, elapsed: timeline.date.timeIntervalSince(model.sentAt)))
                        .font(.system(size: 15))
                        .foregroundStyle(Self.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Working on your answer")
        case .answering, .done:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(AnswerFormatter.segments(model.answer).enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Self.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: AnswerFormatter.Segment) -> some View {
        switch segment {
        case .prose(let text):
            Text(Self.inlineMarkdown(text))
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Self.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Self.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
        }
    }

    private func iconButton(_ symbol: String, label: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Self.primary.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(help ?? label)
    }

    /// **bold**, *italic* and `code` from the model; anything else shows as typed.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
