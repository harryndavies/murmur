import Cocoa
import SwiftUI

/// What the floating pill at the bottom of the screen is showing.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case listening
        case processing
        case done(String)
        case error(String)
        case hint(String)
    }

    static let barCount = 26

    @Published var phase: Phase = .listening
    @Published var locked = false
    @Published var text = ""
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
    @Published var visible = false

    private var smoothed: CGFloat = 0

    func push(level: Float) {
        let target = CGFloat(level)
        // Fast attack, slower release, so the bars feel responsive but not jittery.
        smoothed += (target - smoothed) * (target > smoothed ? 0.6 : 0.25)
        levels.removeFirst()
        levels.append(smoothed)
    }

    func reset() {
        phase = .listening
        locked = false
        text = ""
        smoothed = 0
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideTimer: Timer?
    private static let size = NSSize(width: 720, height: 96)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
    }

    func show(_ phase: OverlayModel.Phase) {
        hideTimer?.invalidate()
        hideTimer = nil
        model.phase = phase
        if !model.visible {
            position()
            panel.orderFrontRegardless()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.visible = true }
        }
    }

    /// Shows a phase briefly, then fades out.
    func flash(_ phase: OverlayModel.Phase, for seconds: TimeInterval) {
        show(phase)
        hide(after: seconds)
    }

    func hide(after delay: TimeInterval = 0) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
    }

    private func fadeOut() {
        withAnimation(.easeIn(duration: 0.18)) { model.visible = false }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.visible else { return }
                self.panel.orderOut(nil)
                self.model.reset()
            }
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 10))
    }
}

// MARK: - Views

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
                .opacity(model.visible ? 1 : 0)
                .scaleEffect(model.visible ? 1 : 0.85, anchor: .bottom)
                .offset(y: model.visible ? 0 : 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 14)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(
            Capsule().fill(Color.black.opacity(0.88))
        )
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.phase)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.locked)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            if model.locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Waveform(levels: model.levels)
            transcriptText
            if model.locked {
                Text("fn to finish · esc to cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize()
            }

        case .processing:
            ThinkingDots()
            Text(model.text.isEmpty ? "Thinking…" : "Polishing…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))

        case .done(let message):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
            label(message)

        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.yellow)
            label(message)

        case .hint(let message):
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            label(message)
        }
    }

    @ViewBuilder
    private var transcriptText: some View {
        if model.text.isEmpty {
            Text("Listening…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        } else {
            Text(model.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 440, alignment: .leading)
                .fixedSize(horizontal: model.text.count < 50, vertical: false)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: text.count < 60, vertical: false)
    }
}

private struct Waveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.35 + 0.65 * Double(i) / Double(levels.count)))
                    .frame(width: 2.5, height: 3 + levels[i] * 22)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.05), value: levels)
    }
}

private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 6 - Double(i) * 0.9)))
                }
            }
        }
    }
}
