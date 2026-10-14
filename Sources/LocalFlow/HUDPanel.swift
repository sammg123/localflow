import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum HUDState: Equatable {
        case hidden
        case recording(caption: String) // "Listening" / "Listening (hands-free)" / "Command — …"
        case processing(String)         // "Transcribing…" / "Polishing…" / "Applying…"
        case notice(String)             // brief error/info flash
    }

    @Published var state: HUDState = .hidden
    @Published var level: Float = 0
}

/// The Wispr-style pill at the bottom-center of the screen.
/// A non-activating panel: it must NEVER steal focus from the app being dictated into.
@MainActor
final class HUDPanel {
    private let panel: NSPanel
    private let model = HUDModel()
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // .screenSaver (1000) floats above native-fullscreen apps; .statusBar (25) gets
        // occluded by them, so the pill would only show on the desktop Space.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func showRecording(caption: String) {
        hideTask?.cancel()
        model.state = .recording(caption: caption)
        position()
        panel.orderFrontRegardless()
    }

    func showProcessing(_ label: String) {
        hideTask?.cancel()
        model.state = .processing(label)
        position()
        panel.orderFrontRegardless()
    }

    func flash(_ message: String, seconds: Double = 2.2) {
        hideTask?.cancel()
        model.state = .notice(message)
        position()
        panel.orderFrontRegardless()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        model.state = .hidden
        panel.orderOut(nil)
    }

    func updateLevel(_ level: Float) {
        // Smooth the meter a little so bars don't flicker.
        model.level = model.level * 0.6 + level * 0.4
    }

    private func position() {
        // The screen the user is working on: the one with the mouse pointer.
        // (NSScreen.main follows OUR key window, which a menu-bar app rarely has.)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 28
        )
        panel.setFrameOrigin(origin)
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .hidden:
                EmptyView()
            case .recording(let caption):
                Circle().fill(caption.hasPrefix("Command") ? Color.purple : Color.red)
                    .frame(width: 8, height: 8)
                WaveformView(level: model.level)
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            case .processing(let label):
                ProgressView().controlSize(.small).tint(.white)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            case .notice(let message):
                Image(systemName: "info.circle")
                    .foregroundStyle(.white.opacity(0.9))
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color.black.opacity(0.82))
        )
        .frame(maxWidth: 400, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.state)
    }
}

struct WaveformView: View {
    var level: Float
    private let barCount = 7

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: barHeight(index: i))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barHeight(index: Int) -> CGFloat {
        // Center bars respond most; a resting floor keeps the pill alive in silence.
        let centerWeight = 1.0 - abs(Double(index) - Double(barCount - 1) / 2) / Double(barCount)
        let h = 4 + CGFloat(Double(level) * 16 * centerWeight)
        return max(3, min(20, h))
    }
}
