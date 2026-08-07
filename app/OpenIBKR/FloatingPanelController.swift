import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSWindowController, NSWindowDelegate {
    private static let frameName = "OpenIBKR.FloatingPanel"
    private let fixedFrameHeight: CGFloat

    init(model: AppModel) {
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DashboardLayout.defaultWidth,
                height: DashboardLayout.contentHeight
            ),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        fixedFrameHeight = panel.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: DashboardLayout.defaultWidth,
                height: DashboardLayout.contentHeight
            )
        ).height
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(
            width: DashboardLayout.minimumWidth,
            height: DashboardLayout.contentHeight
        )
        panel.contentMaxSize = NSSize(
            width: DashboardLayout.maximumWidth,
            height: DashboardLayout.contentHeight
        )
        panel.minSize = NSSize(width: DashboardLayout.minimumWidth, height: fixedFrameHeight)
        panel.maxSize = NSSize(width: DashboardLayout.maximumWidth, height: fixedFrameHeight)
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            panel.standardWindowButton(buttonType)?.isHidden = true
        }
        let hostingView = NSHostingView(rootView: DashboardView(model: model))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.setFrameAutosaveName(Self.frameName)
        if !panel.setFrameUsingName(Self.frameName) {
            panel.center()
        }
        let restoredContentWidth = panel.contentRect(forFrameRect: panel.frame).width
        panel.setContentSize(
            NSSize(
                width: min(
                    max(restoredContentWidth, DashboardLayout.minimumWidth),
                    DashboardLayout.maximumWidth
                ),
                height: DashboardLayout.contentHeight
            )
        )
        super.init(window: panel)
        panel.delegate = self
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

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: min(
                max(frameSize.width, DashboardLayout.minimumWidth),
                DashboardLayout.maximumWidth
            ),
            height: fixedFrameHeight
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
