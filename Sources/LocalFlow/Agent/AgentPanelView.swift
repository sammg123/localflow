import SwiftUI

/// How the user answered an approval card.
enum AgentAnswer: Equatable {
    case deny
    case allowOnce
    /// Allow this kind of action for the rest of the task.
    case allowForTask
}

/// The agent's window: the task, what it's doing step by step, a card for anything risky,
/// and its reply. Same black card as Ask, with a green edge (amber while it waits).
struct AgentPanelView: View {
    static let width: CGFloat = 400
    static let shownSteps = 5
    static let maxReplyHeight: CGFloat = 220

    @ObservedObject var model: AgentModel
    /// What to do for more; set by the controller ("Right ⌥, then ⌘Return…").
    var followUpHint = ""
    /// False in render tests: ImageRenderer can't draw a ScrollView.
    var scrolls = true
    var onAnswer: (AgentApproval, AgentAnswer) -> Void = { _, _ in }
    /// The pointer went down on an Allow button (true) or the press ended (false); Allow checks for it.
    var onPressed: (AgentApproval, AgentAnswer, Bool) -> Void = { _, _, _ in }
    /// A card came up; its Allow buttons wait a moment before taking a click.
    var onShown: (AgentApproval) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onCopy: () -> Void = {}
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(model.task)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AgentStyle.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            steps
            if let approval = model.approvals.first {
                ApprovalCard(approval: approval, waiting: model.approvals.count - 1, onAnswer: onAnswer,
                             onPressed: onPressed)
                    .id(approval.id)
                    .onAppear { onShown(approval) }
            }
            reply
            footer
        }
        .padding(18)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(edgeColor.opacity(0.4))
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.steps)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.approvals)
    }

    private var edgeColor: Color {
        switch model.status {
        case .needsApproval: return AgentStyle.amber
        case .failed: return AgentStyle.red
        default: return AgentStyle.green
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            statusLine
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentStyle.secondary)
            Spacer()
            if !model.status.isWorking, !model.reply.isEmpty {
                CopyIconButton(label: "Copy reply", action: onCopy)
            }
            WindowIconButton(symbol: "xmark", label: "Close",
                             help: model.status.isWorking ? "Stop and close" : "Close", action: onClose)
        }
        .frame(height: 22)
        .accessibilityElement(children: .contain)
    }

    private var dotColor: Color {
        switch model.status {
        case .starting, .working, .done: return AgentStyle.green
        case .needsApproval: return AgentStyle.amber
        case .stopped: return AgentStyle.secondary
        case .failed: return AgentStyle.red
        }
    }

    /// "Agent · Working · 12s", counting while it works.
    @ViewBuilder
    private var statusLine: some View {
        if model.status.isWorking {
            TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                Text("Agent  ·  \(model.status.title)  ·  \(Int(context.date.timeIntervalSince(model.startedAt)))s")
                    .monospacedDigit()
            }
        } else {
            Text("Agent  ·  \(model.status.title)")
        }
    }

    @ViewBuilder
    private var steps: some View {
        let shown = model.visibleSteps(limit: Self.shownSteps)
        if !shown.steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if shown.earlier > 0 {
                    Text(shown.earlier == 1 ? "1 earlier step" : "\(shown.earlier) earlier steps")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AgentStyle.secondary.opacity(0.7))
                }
                ForEach(shown.steps) { step in
                    StepRow(step: step)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Steps")
        }
    }

    @ViewBuilder
    private var reply: some View {
        if case .failed(let message) = model.status {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(AgentStyle.primary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.status.isWorking {
            if let last = model.reply.split(separator: "\n").last {
                Text(String(last))
                    .font(.system(size: 12))
                    .foregroundStyle(AgentStyle.secondary)
                    .lineLimit(2)
            }
        } else if !model.reply.isEmpty {
            if scrolls {
                ScrollView {
                    replyText.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.maxReplyHeight)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                replyText
            }
        }
    }

    private var replyText: some View {
        Text(model.reply)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(AgentStyle.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.status.isWorking ? "Using your Mac. Risky steps wait for your OK." : followUpHint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentStyle.secondary.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.status.isWorking {
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop the agent")
                .help("Stop the agent")
            }
        }
    }
}

private struct StepRow: View {
    let step: AgentStep

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 14, height: 14)
            Text(step.title)
                .font(.system(size: 12))
                .foregroundStyle(step.state == .running ? AgentStyle.primary : AgentStyle.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateName)
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .running:
            Circle().fill(AgentStyle.green).frame(width: 6, height: 6)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AgentStyle.green)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AgentStyle.red)
        case .denied:
            Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(AgentStyle.amber)
        }
    }

    private var stateName: String {
        switch step.state {
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        case .denied: return "not allowed"
        }
    }
}

/// "Allow this?" with the action in plain words and code type for commands.
private struct ApprovalCard: View {
    let approval: AgentApproval
    let waiting: Int
    let onAnswer: (AgentApproval, AgentAnswer) -> Void
    let onPressed: (AgentApproval, AgentAnswer, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Allow this?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AgentStyle.amber)
            Text(Self.styled(approval.summary))
                .foregroundStyle(AgentStyle.primary)
                .lineLimit(5)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                pill("Deny", fill: Color.white.opacity(0.12)) { onAnswer(approval, .deny) }
                    .buttonStyle(.plain)
                Spacer(minLength: 0)
                if approval.canAllowForTask {
                    Button("Allow for this task") { onAnswer(approval, .allowForTask) }
                        .buttonStyle(PressTracking { onPressed(approval, .allowForTask, $0) })
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AgentStyle.secondary)
                        .help("Allow this kind of step until the task is done")
                }
                pill("Allow", fill: AgentStyle.green) { onAnswer(approval, .allowOnce) }
                    .buttonStyle(PressTracking { onPressed(approval, .allowOnce, $0) })
            }
            if waiting > 0 {
                Text(waiting == 1 ? "1 more waiting" : "\(waiting) more waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AgentStyle.secondary.opacity(0.8))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AgentStyle.amber.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Allow this?")
    }

    private func pill(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(fill))
        }
    }

    /// Looks like `.plain`, and says when the pointer goes down on the button and when
    /// that press ends: an accessibility press never does either, so Allow can tell a real
    /// click from one.
    private struct PressTracking: ButtonStyle {
        let onPress: (Bool) -> Void

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .contentShape(Rectangle())
                .onChange(of: configuration.isPressed) { _, isPressed in onPress(isPressed) }
        }
    }

    /// Plain text with backticked parts in code type; never parsed as markdown.
    static func styled(_ summary: String) -> AttributedString {
        CodeSpans.split(summary).reduce(into: AttributedString()) { result, span in
            var part = AttributedString(span.text)
            part.font = span.isCode ? .system(size: 12.5, design: .monospaced) : .system(size: 13)
            result += part
        }
    }
}
