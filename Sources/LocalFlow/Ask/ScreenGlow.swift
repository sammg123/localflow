import AppKit
import SwiftUI

/// The outline around the screen: blue while Ask is listening and looking, green while
/// the agent is using the Mac. Click-through and above everything, on the one display.
@MainActor
final class ScreenGlow {
    private let panel: NSPanel

    init(color: Color = AnswerView.askBlue) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hosting = NSHostingView(rootView: GlowView(color: color, pulses: !reduceMotion))
        hosting.sizingOptions = [] // always exactly the screen's frame
        panel.contentView = hosting
    }

    private var isShown = false

    func show(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
        isShown = true
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show() during the fade wins.
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}

struct GlowView: View {
    var color = AnswerView.askBlue
    var pulses: Bool
    @State private var bright = false

    /// Roughly the radius of a MacBook display's corners.
    private static let cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(0.55), lineWidth: 18)
                .blur(radius: 16)
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(color, lineWidth: 3)
        }
        .opacity(bright || !pulses ? 1 : 0.6)
        .allowsHitTesting(false)
        .onAppear {
            guard pulses else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                bright = true
            }
        }
    }
}
