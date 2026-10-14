import AppKit
import SwiftUI

@MainActor
final class LiveModel: ObservableObject {
    @Published var text = ""
    @Published var level: Float = 0
}

/// The hands-free window: a black panel where the words appear while you talk.
/// Like the pill it is a non-activating, click-through panel, so it can never take
/// focus away from the field the transcript will be pasted into.
@MainActor
final class LivePanel {
    static let size = NSSize(width: 460, height: 240)

    private let panel: NSPanel
    private let model = LiveModel()

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver // above native-fullscreen apps, same as the pill
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: LiveView(model: model))
    }

    func show() {
        model.text = ""
        model.level = 0
        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
    }

    func update(text: String) {
        model.text = text
    }

    func updateLevel(_ level: Float) {
        guard panel.isVisible else { return }
        model.level = model.level * 0.6 + level * 0.4
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func position() {
        // The screen with the mouse pointer: where the user is working.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - Self.size.width / 2,
                              y: frame.minY + 28,
                              width: Self.size.width,
                              height: Self.size.height),
                       display: false)
    }
}

struct LiveView: View {
    @ObservedObject var model: LiveModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let primary = Color(red: 0.96, green: 0.96, blue: 0.97)   // #f5f5f7
    private let secondary = Color(red: 0.63, green: 0.63, blue: 0.65) // #a1a1a6
    /// Room above the first line where overflowing text fades out.
    private static let fadeHeight: CGFloat = 20

    private var transcript: some View {
        Text(model.text.isEmpty ? "Start talking…" : model.text)
            .font(.system(size: 17))
            .lineSpacing(4)
            .foregroundStyle(model.text.isEmpty ? secondary : primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Listening")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondary)
                Spacer()
                WaveformView(level: model.level)
            }

            // Short text reads from the top. Once it overflows, the newest line stays
            // pinned to the bottom and older lines slide up and fade out at the top.
            // (The Spacer fills the box while text is short, keeping it at the top; long
            // text outgrows the box and the bottom-aligned overlay lets it spill upward.)
            Color.clear
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        transcript
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
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.text)

            Text("Fn to paste   ·   Esc to cancel")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondary.opacity(0.8))
                .padding(.top, 6)
        }
        .padding(20)
        .frame(width: LivePanel.size.width, height: LivePanel.size.height)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
    }
}
