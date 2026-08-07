import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSWindowController {
    private static let frameName = "OpenIBKR.FloatingPanel"

    init(model: AppModel) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 250)
        panel.contentView = NSHostingView(rootView: DashboardView(model: model))
        panel.setFrameAutosaveName(Self.frameName)
        if !panel.setFrameUsingName(Self.frameName) {
            panel.center()
        }
        super.init(window: panel)
        moveToVisibleScreenIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() {
        window?.orderFrontRegardless()
    }

    func toggleVisibility() {
        guard let window else { return }
        window.isVisible ? window.orderOut(nil) : show()
    }

    private func moveToVisibleScreenIfNeeded() {
        guard let window else { return }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.contains(where: { $0.intersects(window.frame) }) else { return }
        window.center()
    }
}
