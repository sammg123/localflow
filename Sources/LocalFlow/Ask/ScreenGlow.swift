import AppKit
import SwiftUI

/// The outline's color: Ask's blue, or the agent's green.
enum GlowTint: Equatable {
    case ask
    case agent

    var color: Color { self == .agent ? AgentStyle.green : AnswerView.askBlue }
}

/// The outline around the screen: blue while Ask is listening and looking, green while
/// the box is in agent mode or the agent is using the Mac. Click-through and above
/// everything, on the one display.
@MainActor
final class ScreenGlow {
    private let panel: NSPanel
    private let hosting: NSHostingView<GlowView>
    private let pulses = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var tint: GlowTint {
        didSet {
            guard tint != oldValue else { return }
            hosting.rootView = GlowView(color: tint.color, pulses: pulses)
        }
    }

    init(tint: GlowTint = .ask) {
        self.tint = tint
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
        hosting = NSHostingView(rootView: GlowView(color: tint.color, pulses: pulses))
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
