import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSWindowController, NSWindowDelegate {
    private static let frameName = "OpenIBKR.FloatingPanel"
    private var lockedFrameHeight: CGFloat

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
        lockedFrameHeight = panel.frameRect(
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
            height: DashboardLayout.collapsedContentHeight
        )
        panel.contentMaxSize = NSSize(
            width: DashboardLayout.maximumWidth,
            height: DashboardLayout.contentHeight
        )
        let collapsedFrameHeight = panel.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: DashboardLayout.defaultWidth,
                height: DashboardLayout.collapsedContentHeight
            )
        ).height
        panel.minSize = NSSize(width: DashboardLayout.minimumWidth, height: collapsedFrameHeight)
        panel.maxSize = NSSize(width: DashboardLayout.maximumWidth, height: lockedFrameHeight)
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            panel.standardWindowButton(buttonType)?.isHidden = true
        }
        super.init(window: panel)
        panel.delegate = self

        let hostingView = NSHostingView(
            rootView: DashboardView(
                model: model,
                onWatchlistExpansionChanged: { [weak self] expanded in
                    self?.setWatchlistExpanded(expanded)
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
            height: lockedFrameHeight
        )
    }

    private func setWatchlistExpanded(_ expanded: Bool) {
        guard let panel = window else { return }
        let contentHeight = expanded
            ? DashboardLayout.contentHeight
            : DashboardLayout.collapsedContentHeight
        let targetFrameHeight = panel.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: panel.contentView?.frame.width ?? DashboardLayout.defaultWidth,
                height: contentHeight
            )
        ).height

        lockedFrameHeight = targetFrameHeight
        let targetFrame = Self.frameKeepingTopLeft(
            panel.frame,
            targetHeight: targetFrameHeight
        )

        // NSWindow frame animation interpolates the entire hosted layer even
        // when the top edge is mathematically fixed. That makes the P&L card
        // appear to slide before the watchlist opens. Resize the transparent
        // panel immediately and leave all visible motion to SwiftUI's
        // watchlist/row transitions.
        panel.setFrame(targetFrame, display: true, animate: false)
    }

    static func frameKeepingTopLeft(_ frame: NSRect, targetHeight: CGFloat) -> NSRect {
        NSRect(
            x: frame.minX,
            y: frame.maxY - targetHeight,
            width: frame.width,
            height: targetHeight
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
