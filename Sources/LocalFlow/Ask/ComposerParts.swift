import SwiftUI

/// The box's color: Ask's blue, or the agent's green in agent mode.
enum ComposerTint {
    static func color(agentMode: Bool) -> Color {
        agentMode ? AgentStyle.green : AnswerView.askBlue
    }

    /// The box's outline: a soft blue for Ask, a solid green for the agent, so the mode
    /// shows at a glance.
    static func edge(agentMode: Bool) -> Color {
        color(agentMode: agentMode).opacity(agentMode ? 0.95 : 0.35)
    }

    static func edgeWidth(agentMode: Bool) -> CGFloat {
        agentMode ? 2 : 1
    }
}

/// Where the words go, in both windows that have a box: an editable box while typing;
/// while talking, the words as they're heard, newest line pinned to the bottom and older
/// lines fading out the top.
struct ComposerTextArea: View {
    @ObservedObject var model: ComposerModel
    @FocusState private var boxFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room above the first line where overflowing words fade out while talking.
    private static let fadeHeight: CGFloat = 16

    private var placeholder: String {
        model.agentMode ? "Tell the agent what to do…" : "Ask about your screen, or press ⌘ for the agent…"
    }

    var body: some View {
        Group {
            if model.mode == .typing {
                typingBox
            } else {
                spokenText
            }
        }
        .onAppear { boxFocused = model.mode == .typing }
        .onChange(of: model.mode) { _, mode in boxFocused = mode == .typing }
    }

    private var typingBox: some View {
        ZStack(alignment: .topLeading) {
            if model.text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 17))
                    .foregroundStyle(AnswerView.secondary)
                    .allowsHitTesting(false)
            }
            TextEditor(text: limitedText)
                .font(.system(size: 17))
                .foregroundStyle(AnswerView.primary)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($boxFocused)
                .padding(.horizontal, -5) // the text view's own line padding
                .accessibilityLabel(model.agentMode ? "Task for the agent" : "Question")
        }
    }

    private var spokenText: some View {
        Color.clear
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.text.isEmpty ? "Start talking…" : model.text)
                        .font(.system(size: 17))
                        .lineSpacing(3)
                        .foregroundStyle(model.text.isEmpty ? AnswerView.secondary : AnswerView.primary)
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
            .padding(.top, -Self.fadeHeight)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.text)
    }

    /// Typing past the limit stops at the limit; a bigger paste is cut there.
    private var limitedText: Binding<String> {
        Binding(
            get: { model.text },
            set: { model.text = String($0.prefix(AskLimits.maxQuestionLength)) }
        )
    }
}

/// What the keys do, the Agent switch (⌘) and the send button (Return), in the box's color.
struct ComposerFooter: View {
    @ObservedObject var model: ComposerModel
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let notice = model.notice, model.mode == .typing {
                Text(notice).foregroundStyle(Color.orange)
            } else {
                Text(model.hint).foregroundStyle(AnswerView.secondary.opacity(0.8))
            }
            Spacer(minLength: 0)
            agentSwitch
            sendButton
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    private var agentSwitch: some View {
        Button { model.toggleAgentMode() } label: {
            Text("Agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.agentMode ? Color.white : AnswerView.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(model.agentMode ? AgentStyle.green : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agent mode")
        .accessibilityValue(model.agentMode ? "on" : "off")
        .accessibilityHint("When on, sending hands this to the agent, which can use your Mac")
        .help("Agent mode (⌘): sending hands it to the agent, which can use your Mac")
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(model.canSend ? ComposerTint.color(agentMode: model.agentMode)
                                                        : Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .accessibilityLabel(model.agentMode ? "Send to the agent" : "Send question")
        .help("Send (Return)")
    }
}

/// Shown in agent mode while Instant Edits is on; a click (or ⌘I) turns it off.
struct InstantBadge: View {
    @ObservedObject var model: ComposerModel

    var body: some View {
        if model.sendsInstant {
            Button { model.toggleInstant() } label: {
                Label("Instant", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentStyle.yellow)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(AgentStyle.yellow.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(AgentStyle.yellow.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Instant Edits on")
            .accessibilityHint("Turns Instant Edits off")
            .help("Instant Edits: small UI changes, made straight away (⌘I to turn off)")
        }
    }
}
