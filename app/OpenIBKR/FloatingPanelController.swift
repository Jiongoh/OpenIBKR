import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSWindowController {
    private static let frameName = "OpenIBKR.FloatingPanel"

    init(model: AppModel) {
        let initialContentSize = DashboardLayout.initialContentSize
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: initialContentSize.width,
                height: initialContentSize.height
            ),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            panel.standardWindowButton(buttonType)?.isHidden = true
        }
        super.init(window: panel)

        let hostingView = NSHostingView(
            rootView: DashboardView(
                model: model,
                onVisibleSizeChanged: { [weak self] size in
                    self?.setVisibleContentSize(size)
                }
            )
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.setFrameAutosaveName(Self.frameName)
        if !panel.setFrameUsingName(Self.frameName) {
            panel.center()
        }
        setVisibleContentSize(initialContentSize)
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

    private func setVisibleContentSize(_ contentSize: CGSize) {
        guard let panel = window else { return }
        let targetFrameSize = panel.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: contentSize.width,
                height: contentSize.height
            )
        ).size

        let targetFrame = Self.frameKeepingTopLeft(
            panel.frame,
            targetSize: targetFrameSize
        )

        // NSWindow frame animation interpolates the entire hosted layer even
        // when the top edge is mathematically fixed. That makes the P&L card
        // appear to slide before the watchlist opens. Resize the transparent
        // panel immediately and leave all visible motion to SwiftUI's
        // watchlist/row transitions.
        panel.setFrame(targetFrame, display: true, animate: false)
    }

    static func frameKeepingTopLeft(_ frame: NSRect, targetSize: NSSize) -> NSRect {
        NSRect(
            x: frame.minX,
            y: frame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    private func moveToVisibleScreenIfNeeded() {
        guard let window else { return }
        let targetScreen = window.screen
            ?? NSScreen.screens.max(by: {
                $0.visibleFrame.intersection(window.frame).area
                    < $1.visibleFrame.intersection(window.frame).area
            })
            ?? NSScreen.main
        guard let targetScreen else { return }
        let constrainedFrame = window.constrainFrameRect(window.frame, to: targetScreen)
        if constrainedFrame != window.frame {
            window.setFrame(constrainedFrame, display: false)
        }
    }
}

private extension NSRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
