// BrightBar's own brightness indicator, shown on F1/F2 in place of the macOS
// one: a small non-activating panel at the top right of the target screen.

import AppKit
import SwiftUI

@MainActor
final class BrightnessHUD {
    private final class State: ObservableObject {
        @Published var name = ""
        @Published var label = ""
        /// Bar fill, 0...1.
        @Published var fraction: Double = 0
        @Published var badge: String?
    }

    private let state = State()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(name: String, label: String, fraction: Double, badge: String?, on screen: NSScreen?) {
        state.name = name
        state.label = label
        state.fraction = min(max(fraction, 0), 1)
        state.badge = badge

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = screen ?? NSScreen.main {
            // Same spot as the macOS 26 indicator: under the menu bar, right side.
            let f = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.maxX - size.width - 12, y: f.maxY - size.height - 8))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(state: state))
        return panel
    }

    private struct HUDView: View {
        @ObservedObject var state: State

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(state.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if let badge = state.badge {
                        Text(badge).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(state.label).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.caption)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.15))
                            Capsule().fill(Color.primary)
                                .frame(width: max(6, geo.size.width * state.fraction))
                        }
                    }
                    .frame(height: 6)
                    Image(systemName: "sun.max").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 300, height: 64)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: state.fraction)
        }
    }
}
