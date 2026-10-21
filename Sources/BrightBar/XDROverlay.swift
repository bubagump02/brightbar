// Brightness above 100 % on XDR panels, the way Lunar's HDRWindow and similar
// tools do it: a click-through full-screen window whose Metal layer shows an
// extended-range color (> 1.0) with a multiply blend. macOS raises the
// backlight to render that EDR content and the multiply brightens the whole
// picture. Nothing in the system configuration changes; quitting removes it.

import AppKit
import MetalKit

@MainActor
final class XDROverlay {
    private var window: NSWindow?
    private var view: MTKView?
    private var renderer: Renderer?
    private(set) var multiplier: Double = 1

    /// Max EDR value the panel reaches at full SDR brightness (1600/500 nits
    /// on MacBook Pro XDR). The live value is only > 1 while EDR is active.
    static func headroom(of screen: NSScreen) -> Double {
        let live = screen.maximumExtendedDynamicRangeColorComponentValue
        if live > 1.01 { return live }
        return min(screen.maximumPotentialExtendedDynamicRangeColorComponentValue, 3.2)
    }

    static func isSupported(on screen: NSScreen?) -> Bool {
        (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1.5
    }

    /// 1.0 removes the overlay.
    func set(_ multiplier: Double, on screen: NSScreen) {
        self.multiplier = multiplier
        guard multiplier > 1.001 else {
            hide()
            return
        }
        let view = self.view ?? makeWindow(on: screen)
        if window?.frame != screen.frame { window?.setFrame(screen.frame, display: false) }
        view.clearColor = MTLClearColor(red: multiplier, green: multiplier, blue: multiplier, alpha: 1)
        view.needsDisplay = true
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        view = nil
        renderer = nil
        multiplier = 1
    }

    private func makeWindow(on screen: NSScreen) -> MTKView {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        // As BrightIntosh does: a 1x1 drawable stretched over a white layer,
        // with the "multiply" filter. A full-size drawable with
        // "multiplyBlendMode" turns the whole screen white once EDR engages
        // (~1 s after showing the overlay).
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1, height: 1)
        view.layer?.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        view.layer?.compositingFilter = "multiply"
        // Redraw only when the multiplier changes.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        if let device {
            let renderer = Renderer(device: device)
            view.delegate = renderer
            self.renderer = renderer
        }
        window.contentView = view
        self.window = window
        self.view = view
        return view
    }

    /// Clears the drawable to the view's clearColor; nothing else to draw.
    private final class Renderer: NSObject, MTKViewDelegate {
        private let queue: MTLCommandQueue?
        init(device: MTLDevice) { queue = device.makeCommandQueue() }
        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}
        func draw(in view: MTKView) {
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = queue?.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
