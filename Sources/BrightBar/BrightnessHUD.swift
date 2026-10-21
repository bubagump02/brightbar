// BrightBar's own brightness indicator, shown on F1/F2 (and the keyboard
// illumination keys) in place of the macOS one: a small non-activating panel
// under BrightBar's menu bar icon on the target screen.

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
        @Published var symbols = ("sun.min", "sun.max")
    }

    private let state = State()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(name: String, label: String, fraction: Double, badge: String?,
              symbols: (String, String) = ("sun.min", "sun.max"), on screen: NSScreen?) {
        state.name = name
        state.label = label
        state.fraction = min(max(fraction, 0), 1)
        state.badge = badge
        state.symbols = symbols

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = screen ?? NSScreen.main {
            // Under the menu bar, centered on BrightBar's icon; at the right
            // side like the macOS 26 indicator if the icon can't be found.
            let f = screen.visibleFrame
            let size = panel.frame.size
            var x = f.maxX - size.width - 12
            if let offset = Self.iconOffsetFromRight() {
                x = min(max(screen.frame.maxX - offset - size.width / 2, f.minX + 8), f.maxX - size.width - 8)
            }
            panel.setFrameOrigin(NSPoint(x: x, y: f.maxY - size.height - 8))
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

    /// Distance from the icon's center to the right edge of its screen. Every
    /// screen's menu bar puts the status items at the same distance from its
    /// right edge, so this also places the HUD on another screen.
    private static func iconOffsetFromRight() -> CGFloat? {
        // MenuBarExtra hides its NSStatusItem; its button lives in this window.
        guard let icon = NSApp.windows.first(where: { $0.className == "NSStatusBarWindow" && $0.isVisible })?.frame,
              let iconScreen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) })
        else { return nil }
        return iconScreen.frame.maxX - icon.midX
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
                    Image(systemName: state.symbols.0).font(.caption)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.15))
                            Capsule().fill(Color.primary)
                                .frame(width: max(6, geo.size.width * state.fraction))
                        }
                    }
                    .frame(height: 6)
                    Image(systemName: state.symbols.1).font(.caption)
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
