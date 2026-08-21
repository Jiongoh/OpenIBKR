import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSWindowController {
    private static let collapseResizeDelay: Duration = .milliseconds(460)
    private var isExpanded = false
    private var pendingCollapsedResize: Task<Void, Never>?

    init(model: AppModel) {
        let initialContentSize = DashboardLayout.initialContentSize
        let panel = FloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: initialContentSize.width,
                height: initialContentSize.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        // The compact island is anchored in the macOS control-bar area. A
        // floating-level window remains underneath the menu/status bar, so
        // the panel becomes effectively invisible when its top edge overlaps
        // that area.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)

        let hostingView = NSHostingView(
            rootView: DashboardView(
                model: model,
                onVisibleSizeChanged: { [weak self] size in
                    self?.setVisibleContentSize(size)
                },
                onExpandedStateChanged: { [weak self] expanded in
                    self?.setExpandedState(expanded)
                }
            )
        )
        let contentView = NSView(
            frame: NSRect(
                origin: .zero,
                size: NSSize(
                    width: initialContentSize.width,
                    height: initialContentSize.height
                )
            )
        )
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        // Keep an ordinary AppKit container between the borderless panel and
        // NSHostingView. This gives SwiftUI a concrete, stable proposal on
        // the first display pass instead of relying on NSPanel's titlebar
        // content layout machinery (which is absent for a borderless panel).
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        panel.contentView = contentView
        hostingView.needsLayout = true
        setVisibleContentSize(initialContentSize)
        snapCollapsedToTopCenter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show() {
        if !isExpanded {
            snapCollapsedToTopCenter()
        }
        window?.orderFrontRegardless()
        window?.contentView?.needsLayout = true
        window?.contentView?.needsDisplay = true
        window?.displayIfNeeded()
    }

    func toggleVisibility() {
        guard let window else { return }
        window.isVisible ? window.orderOut(nil) : show()
    }

    private func setVisibleContentSize(_ contentSize: CGSize) {
        guard let panel = window else { return }
        pendingCollapsedResize?.cancel()

        let targetFrameSize = panel.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: contentSize.width,
                height: contentSize.height
            )
        ).size

        // SwiftUI animates the folding surface for roughly 420 ms. Keep the outer
        // panel at its expanded size until that animation has finished; if
        // the panel is shrunk immediately, AppKit clips the still-expanded
        // hosted layer into a visible rectangle with square corners.
        if !isExpanded,
           (panel.frame.width > targetFrameSize.width + 0.5
                || panel.frame.height > targetFrameSize.height + 0.5)
        {
            pendingCollapsedResize = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.collapseResizeDelay)
                guard !Task.isCancelled, let self, !self.isExpanded else { return }
                self.applyVisibleContentSize(targetFrameSize: targetFrameSize)
                self.pendingCollapsedResize = nil
            }
            return
        }

        applyVisibleContentSize(targetFrameSize: targetFrameSize)
    }

    private func applyVisibleContentSize(targetFrameSize: NSSize) {
        guard let panel = window else { return }
        let targetFrame: NSRect
        if isExpanded {
            targetFrame = Self.frameKeepingTopCenter(
                panel.frame,
                targetSize: targetFrameSize
            )
        } else {
            targetFrame = frameKeepingTopCenterOfVisibleScreen(
                panel: panel,
                targetSize: targetFrameSize
            )
        }

        // Keep the top-center axis fixed while SwiftUI animates the surface
        // from the compact island's center. This preserves the downward
        // expansion and keeps the full expanded content visible.
        panel.setFrame(targetFrame, display: true, animate: false)
    }

    private func setExpandedState(_ expanded: Bool) {
        pendingCollapsedResize?.cancel()
        isExpanded = expanded
        window?.isMovableByWindowBackground = expanded

        guard expanded, let panel = window else { return }
        let expandedContentSize = DashboardLayout.contentSize(expanded: true)
        let expandedFrameSize = panel.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: expandedContentSize
            )
        ).size
        applyVisibleContentSize(targetFrameSize: expandedFrameSize)
    }

    private func snapCollapsedToTopCenter() {
        guard let panel = window else { return }
        let targetFrameSize = panel.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: DashboardLayout.initialContentSize.width,
                height: DashboardLayout.initialContentSize.height
            )
        ).size
        let targetFrame = frameKeepingTopCenterOfVisibleScreen(
            panel: panel,
            targetSize: targetFrameSize
        )
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true, animate: false)
        }
    }

    private func frameKeepingTopCenterOfVisibleScreen(
        panel: NSWindow,
        targetSize: NSSize
    ) -> NSRect {
        let targetScreen = visibleScreen(for: panel)
        // Keep the complete transparent panel on-screen. Older builds placed
        // the shadow padding above `screenFrame.maxY`; a stale/autosaved frame
        // could then leave only the bottom few points of the panel visible,
        // making the compact island appear transparent even though it was
        // rendered and remained hoverable.
        let screenFrame = targetScreen?.frame ?? panel.screen?.frame ?? panel.frame
        return Self.frameAtTopCenter(
            of: screenFrame,
            targetSize: targetSize
        )
    }

    static func frameAtTopCenter(of screenFrame: NSRect, targetSize: NSSize) -> NSRect {
        NSRect(
            x: screenFrame.midX - targetSize.width / 2,
            y: screenFrame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    static func frameKeepingTopCenter(_ frame: NSRect, targetSize: NSSize) -> NSRect {
        NSRect(
            x: frame.midX - targetSize.width / 2,
            y: frame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    // Compatibility helper for the existing panel geometry tests. Runtime
    // resizing uses the centered variant above so the island stays centered.
    static func frameKeepingTopLeft(_ frame: NSRect, targetSize: NSSize) -> NSRect {
        NSRect(
            x: frame.minX,
            y: frame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    private func visibleScreen(for window: NSWindow) -> NSScreen? {
        window.screen
            ?? NSScreen.main
            ?? NSScreen.screens.max(by: {
                $0.visibleFrame.intersection(window.frame).area
                    < $1.visibleFrame.intersection(window.frame).area
            })
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension NSRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
