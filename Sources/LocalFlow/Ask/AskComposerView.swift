import SwiftUI

/// The Ask window: blue dot and waveform while talking, an editable box while typing,
/// a send button to ask, and Do it to hand the words to the agent. Same size, colors and spot as the live dictation window.
struct AskComposerView: View {
    static let size = NSSize(width: 460, height: 210)

    @ObservedObject var model: ComposerModel
    var onSend: () -> Void = {}
    var onDoIt: () -> Void = {}
    var onOpenChats: () -> Void = {}
    var onClose: () -> Void = {}
    @FocusState private var boxFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let primary = Color(red: 0.96, green: 0.96, blue: 0.97)   // #f5f5f7
    private let secondary = Color(red: 0.63, green: 0.63, blue: 0.65) // #a1a1a6
    private static let placeholder = "Ask about your screen, or say what to do…"
    /// Room above the first line where overflowing words fade out while talking.
    private static let fadeHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .strokeBorder(AnswerView.askBlue.opacity(0.35))
        )
        .onAppear { boxFocused = model.mode == .typing }
        .onChange(of: model.mode) { _, mode in boxFocused = mode == .typing }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(AnswerView.askBlue).frame(width: 8, height: 8)
            Text(model.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondary)
            Spacer()
            switch model.mode {
            case .voice: WaveformView(level: model.level)
            case .finishing: ProgressView().controlSize(.small)
            case .typing: EmptyView()
            }
            WindowIconButton(symbol: "clock.arrow.circlepath", label: "Chats", help: "All your chats",
                             action: onOpenChats)
            WindowIconButton(symbol: "xmark", label: "Close", help: "Close (Esc)", action: onClose)
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private var textArea: some View {
        if model.mode == .typing {
            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text(Self.placeholder)
                        .font(.system(size: 17))
                        .foregroundStyle(secondary)
                        .allowsHitTesting(false)
                }
                TextEditor(text: limitedText)
                    .font(.system(size: 17))
                    .foregroundStyle(primary)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($boxFocused)
                    .padding(.horizontal, -5) // the text view's own line padding
                    .accessibilityLabel("Question")
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
                        .lineSpacing(3)
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
            .padding(.top, -Self.fadeHeight)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.text)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let notice = model.notice, model.mode == .typing {
                Text(notice)
                    .foregroundStyle(Color.orange)
            } else {
                Text(model.hint)
                    .foregroundStyle(secondary.opacity(0.8))
            }
            Spacer(minLength: 0)
            Button(action: onDoIt) {
                Text("Do it")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(model.canSend ? AgentStyle.green : Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .accessibilityLabel("Do it")
            .accessibilityHint("Hands this to the agent, which can use your Mac to do it")
            .help("Hand it to the agent (⌘Return)")
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(model.canSend ? AnswerView.askBlue : Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .accessibilityLabel("Send question")
            .help("Send (Return)")
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    /// Typing past the limit stops at the limit; a bigger paste is cut there.
    private var limitedText: Binding<String> {
        Binding(
            get: { model.text },
            set: { model.text = String($0.prefix(AskLimits.maxQuestionLength)) }
        )
    }
}
