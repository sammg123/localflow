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
    var onOpenChats: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let primary = Color(red: 0.96, green: 0.96, blue: 0.97)   // #f5f5f7
    static let secondary = Color(red: 0.63, green: 0.63, blue: 0.65) // #a1a1a6
    static let askBlue = Color(red: 0.04, green: 0.52, blue: 1.0)    // #0a84ff

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
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
            iconButton("clock.arrow.circlepath", label: "Chats", help: "All your chats", action: onOpenChats)
            if model.phase == .done {
                CopyIconButton(label: "Copy answer", action: onCopy)
            }
            iconButton("minus", label: "Minimize", help: "Minimize (Esc)", action: onMinimize)
            iconButton("xmark", label: "Close", help: "Close (⇧Esc)", action: onClose)
        }
    }

    /// Only the answer scrolls. Nothing waits on the scroll view's measured height: the
    /// working row and a failure sit outside it, and the answer shows unscrolled until
    /// it's been measured. (A height left at zero once hid the dots.)
    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .answering, .done:
            if scrolls, model.bodyHeight > 0 {
                ScrollView { measuredAnswer }
                    .frame(height: min(model.bodyHeight, AnswerPanel.maxBodyHeight))
            } else if scrolls {
                measuredAnswer
            } else {
                answerText
            }
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

    private var measuredAnswer: some View {
        answerText.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.bodyHeight = $0 }
    }

    private var answerText: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(AnswerFormatter.segments(model.answer).enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
        // Drag over words to copy them; the panel takes the keyboard for Cmd+C then.
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        WindowIconButton(symbol: symbol, label: label, help: help, action: action)
    }

    /// **bold**, *italic* and `code` from the model; anything else shows as typed.
    /// Links show as plain words: text on the screen can steer a model into writing a
    /// link whose address carries data away, so nothing in an answer is clickable.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let linked = attributed.runs.filter { $0.link != nil }.map(\.range)
        for range in linked { attributed[range].link = nil }
        return attributed
    }
}
