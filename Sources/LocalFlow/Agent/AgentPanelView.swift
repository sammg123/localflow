import SwiftUI

/// How the user answered an approval card.
enum AgentAnswer: Equatable {
    case deny
    case allowOnce
    /// Allow this kind of action for the rest of the task.
    case allowForTask
}

/// The agent's window: the task, what it's doing step by step, a card for anything risky,
/// and its reply. Same black card as Ask, with a green edge (amber while it waits). When
/// the user writes in it (Ask's box, opened here so there's only ever one window) the box
/// sits under the conversation and the edge takes the box's color: blue to ask, green for
/// the agent. Collapsed, it's a small capsule with the status. Dragged by its background,
/// it moves.
struct AgentPanelView: View {
    static let width: CGFloat = 400
    /// As wide as the Ask window, while it has the box.
    static let inputWidth: CGFloat = 460
    static let shownSteps = 5
    static let maxReplyHeight: CGFloat = 220
    static let inputHeight: CGFloat = 64
    /// The same size as the minimized answer.
    static let collapsedSize = NSSize(width: 300, height: 40)

    @ObservedObject var model: AgentModel
    /// The box, shown when `showsInput`.
    @ObservedObject var input: ComposerModel
    var showsInput = false
    /// Shrunk to a capsule with the status.
    var collapsed = false
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
    /// The box's send button.
    var onInputSend: () -> Void = {}
    var onOpenChats: () -> Void = {}
    var onOpenConnectors: () -> Void = {}
    /// Puts back the files an Instant edit changed.
    var onUndo: () -> Void = {}
    /// Picks the project's folder when an Instant run asked which project.
    var onChooseProject: () -> Void = {}
    var onCollapse: () -> Void = {}
    var onExpand: () -> Void = {}
    /// The window is being dragged. It follows the real pointer; only the first move's
    /// translation counts, for the points moved before the drag began.
    /// How far the pointer has come, and where in the window it went down.
    var onDragMoved: (CGSize, CGPoint) -> Void = { _, _ in }
    var onDragEnded: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Group {
            if collapsed {
                collapsedBar
            } else {
                card
            }
        }
        .gesture(dragToMove)
    }

    /// Past a few points the window moves with the pointer; buttons and the box keep their clicks.
    private var dragToMove: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in onDragMoved(value.translation, value.startLocation) }
            .onEnded { _ in onDragEnded() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(model.task)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AgentStyle.primary)
                .lineLimit(showsInput ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
            steps
            if let approval = model.approvals.first {
                ApprovalCard(approval: approval, waiting: model.approvals.count - 1, onAnswer: onAnswer,
                             onPressed: onPressed)
                    .id(approval.id)
                    .onAppear { onShown(approval) }
            }
            reply
            if showsInput {
                inputBox
            } else {
                footer
            }
        }
        .padding(18)
        .frame(width: showsInput ? Self.inputWidth : Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(edgeColor, lineWidth: showsInput ? ComposerTint.edgeWidth(agentMode: input.agentMode) : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.steps)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.approvals)
    }

    /// The status, still counting, with a way back to the whole window and a way to close.
    private var collapsedBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                statusMark
                statusLine
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AgentStyle.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(model.task)
            .accessibilityAction(.default, onExpand)
            WindowIconButton(symbol: "chevron.down", label: "Expand", help: "Show the whole window",
                             action: onExpand)
            WindowIconButton(symbol: "xmark", label: "Close",
                             help: model.status.isWorking ? "Stop and close" : "Close", action: onClose)
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(width: Self.collapsedSize.width, height: Self.collapsedSize.height)
        .background(Capsule().fill(Color.black.opacity(0.96)))
        .overlay(Capsule().strokeBorder(edgeColor))
        .contentShape(Capsule())
    }

    private var edgeColor: Color {
        if model.status == .needsApproval { return AgentStyle.amber.opacity(showsInput ? 0.55 : 0.4) }
        if showsInput { return ComposerTint.edge(agentMode: input.agentMode) }
        if case .failed = model.status { return AgentStyle.red.opacity(0.4) }
        return AgentStyle.green.opacity(0.4)
    }

    /// Ask's box, under the conversation.
    private var inputBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(ComposerTint.color(agentMode: input.agentMode)).frame(width: 6, height: 6)
                Text(input.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentStyle.secondary)
                InstantBadge(model: input)
                Spacer()
                switch input.mode {
                case .voice: WaveformView(level: input.level)
                case .finishing: ProgressView().controlSize(.small)
                case .typing: EmptyView()
                }
            }
            .frame(height: 20)
            ComposerTextArea(model: input)
                .frame(maxWidth: .infinity, minHeight: Self.inputHeight, maxHeight: Self.inputHeight,
                       alignment: .topLeading)
            ComposerFooter(model: input, onSend: onInputSend)
        }
        .padding(.top, 2)
    }

    /// The green (amber, red) dot, or Instant's bolt.
    @ViewBuilder
    private var statusMark: some View {
        if model.isInstant {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AgentStyle.yellow)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Instant Edits")
        } else {
            Circle().fill(dotColor).frame(width: 8, height: 8)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusMark
            statusLine
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentStyle.secondary)
            Spacer()
            if !model.status.isWorking, !model.reply.isEmpty {
                CopyIconButton(label: "Copy reply", action: onCopy)
            }
            if showsInput {
                if model.status.isWorking {
                    WindowIconButton(symbol: "stop.fill", label: "Stop the agent", help: "Stop the agent",
                                     action: onStop)
                }
                WindowIconButton(symbol: "puzzlepiece.extension", label: "Connectors",
                                 help: "Connectors: give the agent more tools", action: onOpenConnectors)
                WindowIconButton(symbol: "clock.arrow.circlepath", label: "Chats", help: "All your chats",
                                 action: onOpenChats)
            } else {
                WindowIconButton(symbol: "minus", label: "Collapse", help: "Collapse to a small bar",
                                 action: onCollapse)
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

    /// "Agent · Working · 12s" (or "Instant · …"), counting while it works.
    @ViewBuilder
    private var statusLine: some View {
        let name = model.isInstant ? "Instant" : "Agent"
        let title = model.isHeld ? "Waiting while you type" : model.status.title
        if model.status.isWorking {
            TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                Text("\(name)  ·  \(title)  ·  \(Int(context.date.timeIntervalSince(model.startedAt)))s")
                    .monospacedDigit()
            }
        } else {
            Text("\(name)  ·  \(model.status.title)")
        }
    }

    @ViewBuilder
    private var steps: some View {
        let shown = model.visibleSteps(limit: showsInput ? 3 : Self.shownSteps)
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
                .frame(maxHeight: showsInput ? Self.maxReplyHeight * 0.6 : Self.maxReplyHeight)
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

    private var workingHint: String {
        if model.isInstant { return "UI changes only  ·  Undo once it's done" }
        return settings.agentAlwaysAllow ? "Always allow is on  ·  ⌘ to add more"
                                         : "Risky steps wait for your OK  ·  ⌘ to add more"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.status.isWorking ? workingHint : followUpHint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AgentStyle.secondary.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.canChooseProject, !model.status.isWorking {
                footerButton("Choose Folder…", systemImage: "folder", action: onChooseProject)
                    .accessibilityLabel("Choose the project's folder")
                    .help("Pick the project's top folder, and LocalFlow remembers it")
            }
            if model.canUndo, !model.status.isWorking {
                footerButton("Undo", systemImage: "arrow.uturn.backward", action: onUndo)
                    .accessibilityLabel("Undo the Instant edit")
                    .help("Put the changed files back as they were")
            }
            if model.status.isWorking {
                footerButton("Stop", systemImage: "stop.fill", action: onStop)
                    .accessibilityLabel("Stop the agent")
                    .help("Stop the agent")
            }
        }
    }

    private func footerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
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
