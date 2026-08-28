import AppKit
import SwiftUI

enum DashboardLayout {
    static let shadowPadding: CGFloat = 0
    static let collapsedIslandSize = CGSize(width: 520, height: 20)
    static let expandedIslandSize = CGSize(width: 520, height: 148)
    static let drawerLipDepth: CGFloat = 14
    static let expandedTopShoulderDepth: CGFloat = 2
    static let islandAnimation = Animation.spring(
        response: 0.42,
        dampingFraction: 0.86,
        blendDuration: 0.08
    )

    // Kept as pure geometry helpers for the existing layout tests and for
    // callers that still reference the former dashboard module metrics.
    static let pnlHeight: CGFloat = 52
    static let maximumWatchlistHeight: CGFloat = 284
    static let moduleSpacing: CGFloat = 12
    static let watchlistAccessoryWidth: CGFloat = 24
    static let watchlistIndicatorLimit = 5
    static let pnlDragButtonExclusionWidth: CGFloat = 34
    static let collapsedPnLWidth: CGFloat = 117
    static let expandedModuleWidth: CGFloat = 243
    static let emptyWatchlistHeight: CGFloat = 96

    static var initialContentSize: CGSize {
        contentSize(expanded: false)
    }

    static func contentSize(expanded: Bool) -> CGSize {
        let islandSize = expanded ? expandedIslandSize : collapsedIslandSize
        return CGSize(
            width: islandSize.width + shadowPadding * 2,
            height: islandSize.height + shadowPadding
        )
    }

    static func pointerTrackingRect(windowFrame: CGRect, expanded: Bool) -> CGRect {
        let islandSize = expanded ? expandedIslandSize : collapsedIslandSize
        let visibleHeight = expanded ? islandSize.height : drawerLipDepth
        return CGRect(
            x: windowFrame.midX - islandSize.width / 2,
            y: windowFrame.maxY - visibleHeight,
            width: islandSize.width,
            height: visibleHeight
        )
    }

    static func pointerIsInside(_ point: CGPoint, trackingRect: CGRect) -> Bool {
        // CGRect.contains excludes maxX/maxY. The drawer touches the physical
        // top of the screen, so its top edge must remain an active boundary.
        point.x >= trackingRect.minX
            && point.x <= trackingRect.maxX
            && point.y >= trackingRect.minY
            && point.y <= trackingRect.maxY
    }

    static func moduleWidth(expanded: Bool) -> CGFloat {
        expanded ? expandedModuleWidth : collapsedPnLWidth
    }

    static func quoteListHeight(count: Int, isAddingSymbol: Bool) -> CGFloat {
        let quoteHeight = quoteRowsContentHeight(count: count)
        let inputHeight: CGFloat = isAddingSymbol ? 51 : 0
        return min(maximumWatchlistHeight, max(44, 20 + quoteHeight + inputHeight))
    }

    static func quoteRowsContentHeight(count: Int) -> CGFloat {
        let quoteCount = max(0, count)
        return CGFloat(quoteCount) * 48 + CGFloat(max(0, quoteCount - 1)) * 7
    }

    static func quoteCountForLayout(current: Int, reserved: Int) -> Int {
        max(0, max(current, reserved))
    }

    static func watchlistHeight(quoteCount: Int, reservesAddSymbolSpace: Bool) -> CGFloat {
        if quoteCount == 0, !reservesAddSymbolSpace { return emptyWatchlistHeight }
        let quoteHeight = quoteListHeight(
            count: quoteCount,
            isAddingSymbol: reservesAddSymbolSpace
        )
        return quoteCount == 0 ? max(emptyWatchlistHeight, quoteHeight) : quoteHeight
    }

    static func quoteViewportHeight(
        quoteCount: Int,
        reservesAddSymbolSpace: Bool
    ) -> CGFloat {
        let totalHeight = watchlistHeight(
            quoteCount: quoteCount,
            reservesAddSymbolSpace: reservesAddSymbolSpace
        )
        let inputAllocation: CGFloat = reservesAddSymbolSpace ? 51 : 0
        return max(0, totalHeight - 20 - inputAllocation)
    }

    static func pnlHoverFrame(expanded: Bool) -> CGRect {
        CGRect(x: 0, y: 0, width: moduleWidth(expanded: expanded), height: pnlHeight)
    }

    static func quoteHoverFrame(
        index: Int,
        expanded: Bool,
        includesAccessory: Bool = false
    ) -> CGRect {
        let firstRowY = pnlHeight + moduleSpacing + 10
        return CGRect(
            x: 0,
            y: firstRowY + CGFloat(index) * 55,
            width: moduleWidth(expanded: expanded)
                + (includesAccessory ? watchlistAccessoryWidth : 0),
            height: 48
        )
    }

    static func stableHoverWidth(watchlistExpanded: Bool, hasAccessory: Bool) -> CGFloat {
        expandedModuleWidth
            + (watchlistExpanded && hasAccessory ? watchlistAccessoryWidth : 0)
    }
}

enum IslandWatchlistSelection {
    static func wrappedIndex(current: Int, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return (current + offset % count + count) % count
    }

    static func visibleIndicatorRange(
        selected: Int,
        count: Int,
        limit: Int = DashboardLayout.watchlistIndicatorLimit
    ) -> Range<Int> {
        guard count > 0, limit > 0 else { return 0..<0 }
        let visibleCount = min(count, limit)
        let maximumStart = count - visibleCount
        let centeredStart = selected - visibleCount / 2
        let start = min(max(0, centeredStart), maximumStart)
        return start..<(start + visibleCount)
    }
}

struct IslandScrollSample {
    let deltaY: CGFloat
    let phase: NSEvent.Phase
    let momentumPhase: NSEvent.Phase
    let timestamp: TimeInterval
}

struct PointerTrackingSample {
    let screenLocation: CGPoint
    let isInside: Bool
}

struct IslandScrollGestureGate {
    private(set) var accumulator: CGFloat = 0
    private var lastEventTimestamp = -Double.infinity
    private var lastStepTimestamp = -Double.infinity

    let threshold: CGFloat
    let discreteGestureGap: TimeInterval
    let repeatInterval: TimeInterval

    init(
        threshold: CGFloat = 14,
        discreteGestureGap: TimeInterval = 0.24,
        repeatInterval: TimeInterval = 0.09
    ) {
        self.threshold = threshold
        self.discreteGestureGap = discreteGestureGap
        self.repeatInterval = repeatInterval
    }

    mutating func consume(_ sample: IslandScrollSample) -> Int? {
        if !sample.momentumPhase.isEmpty {
            if sample.momentumPhase.contains(.ended)
                || sample.momentumPhase.contains(.cancelled)
            {
                reset()
            }
            lastEventTimestamp = sample.timestamp
            return nil
        }

        if sample.phase.contains(.began)
            || (sample.phase.isEmpty
                && sample.timestamp - lastEventTimestamp > discreteGestureGap)
        {
            reset()
        }

        lastEventTimestamp = sample.timestamp
        let endsGesture = sample.phase.contains(.ended) || sample.phase.contains(.cancelled)
        defer {
            if endsGesture { reset() }
        }

        accumulator += sample.deltaY
        guard abs(accumulator) >= threshold else { return nil }
        guard sample.timestamp - lastStepTimestamp >= repeatInterval else { return nil }

        let direction = accumulator < 0 ? 1 : -1
        accumulator = 0
        lastStepTimestamp = sample.timestamp
        return direction
    }

    mutating func reset() {
        accumulator = 0
        lastStepTimestamp = -Double.infinity
    }
}

private struct DrawerRevealShape: Shape {
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0, expansion))
        let visibleHeight = DashboardLayout.drawerLipDepth
            + (rect.height - DashboardLayout.drawerLipDepth) * progress
        let cornerRadius = min(28 * progress, visibleHeight / 2)
        let bodyInset = min(
            DashboardLayout.expandedTopShoulderDepth * progress,
            visibleHeight / 2
        )
        let rightSideX = rect.maxX - bodyInset
        let leftSideX = rect.minX + bodyInset
        let rightEdgeBottom = CGPoint(
            x: rightSideX,
            y: rect.minY + (visibleHeight - cornerRadius) * progress
        )
        let rightBottom = CGPoint(
            x: rect.midX
                + (rightSideX - cornerRadius - rect.midX) * progress,
            y: rect.minY + visibleHeight
        )
        let leftBottom = CGPoint(
            x: rect.midX
                + (leftSideX + cornerRadius - rect.midX) * progress,
            y: rightBottom.y
        )
        let leftEdgeBottom = CGPoint(
            x: leftSideX,
            y: rightEdgeBottom.y
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rightSideX, y: rect.minY + bodyInset),
            control1: CGPoint(
                x: rect.maxX,
                y: rect.minY + bodyInset * 0.35
            ),
            control2: CGPoint(
                x: rightSideX,
                y: rect.minY + bodyInset * 0.65
            )
        )
        path.addLine(to: rightEdgeBottom)
        path.addCurve(
            to: rightBottom,
            control1: CGPoint(
                x: rightSideX - rect.width * 0.16 * (1 - progress),
                y: rect.minY + visibleHeight * progress
            ),
            control2: CGPoint(
                x: rect.midX + rect.width * 0.24
                    + (rightSideX - cornerRadius - rect.midX - rect.width * 0.24)
                        * progress,
                y: rect.minY + visibleHeight
            )
        )
        path.addLine(to: leftBottom)
        path.addCurve(
            to: leftEdgeBottom,
            control1: CGPoint(
                x: rect.midX - rect.width * 0.24
                    + (leftSideX + cornerRadius - rect.midX + rect.width * 0.24)
                        * progress,
                y: rect.minY + visibleHeight
            ),
            control2: CGPoint(
                x: leftSideX + rect.width * 0.16 * (1 - progress),
                y: rect.minY + visibleHeight * progress
            )
        )
        path.addLine(
            to: CGPoint(x: leftSideX, y: rect.minY + bodyInset)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(
                x: leftSideX,
                y: rect.minY + bodyInset * 0.65
            ),
            control2: CGPoint(
                x: rect.minX,
                y: rect.minY + bodyInset * 0.35
            )
        )
        path.closeSubpath()
        return path
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    private let initiallyExpanded: Bool
    private let interfaceActiveOverride: Bool?
    private let onVisibleSizeChanged: ((CGSize) -> Void)?
    private let onExpandedStateChanged: ((Bool) -> Void)?

    init(
        model: AppModel,
        initiallyExpanded: Bool = false,
        interfaceActiveOverride: Bool? = nil,
        watchlistInitiallyExpanded: Bool = true,
        onVisibleSizeChanged: ((CGSize) -> Void)? = nil,
        onExpandedStateChanged: ((Bool) -> Void)? = nil
    ) {
        self.model = model
        self.initiallyExpanded = initiallyExpanded
        self.interfaceActiveOverride = interfaceActiveOverride
        self.onVisibleSizeChanged = onVisibleSizeChanged
        self.onExpandedStateChanged = onExpandedStateChanged
        _ = watchlistInitiallyExpanded
    }

    var body: some View {
        DynamicIslandView(
            model: model,
            initiallyExpanded: initiallyExpanded,
            interfaceActiveOverride: interfaceActiveOverride,
            onVisibleSizeChanged: onVisibleSizeChanged,
            onExpandedStateChanged: onExpandedStateChanged
        )
    }
}

private struct DynamicIslandView: View {
    @ObservedObject var model: AppModel

    @State private var isExpanded: Bool
    @State private var selectedQuoteID: Int?
    @State private var hoverGeneration = 0
    @State private var isPointerInside = false
    @State private var lastPointerLocation: CGPoint?
    @State private var suppressReactivationUntilPointerMoves = false
    @State private var scrollGate = IslandScrollGestureGate()
    @State private var positionPopoverScrollGate = IslandScrollGestureGate()
    @State private var isAddingSymbol = false
    @State private var positionPopoverQuoteID: Int?
    @State private var isPositionSlotListPresented = false
    @FocusState private var isSymbolFieldFocused: Bool

    private let interfaceActiveOverride: Bool?
    private let onVisibleSizeChanged: ((CGSize) -> Void)?
    private let onExpandedStateChanged: ((Bool) -> Void)?

    init(
        model: AppModel,
        initiallyExpanded: Bool = false,
        interfaceActiveOverride: Bool? = nil,
        onVisibleSizeChanged: ((CGSize) -> Void)? = nil,
        onExpandedStateChanged: ((Bool) -> Void)? = nil
    ) {
        self.model = model
        self.interfaceActiveOverride = interfaceActiveOverride
        self.onVisibleSizeChanged = onVisibleSizeChanged
        self.onExpandedStateChanged = onExpandedStateChanged
        _isExpanded = State(initialValue: initiallyExpanded)
        _selectedQuoteID = State(initialValue: model.snapshot.quotes.first?.id)
    }

    var body: some View {
        ZStack(alignment: .top) {
            island
                .padding(.horizontal, DashboardLayout.shadowPadding)
                .padding(.bottom, DashboardLayout.shadowPadding)
                .frame(
                    width: currentContentSize.width,
                    height: currentContentSize.height,
                    alignment: .top
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            // Track the whole transparent panel, rather than the animated
            // island layer. The visual state is passed separately because
            // the panel can keep its expanded frame until collapse finishes.
            PointerTrackingView(isExpanded: isExpanded) { sample in
                handlePointerSample(sample)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .onAppear {
                reconcileSelectedQuote()
                onExpandedStateChanged?(isExpanded)
                reportVisibleSize(currentContentSize)
            }
            .onChange(of: currentContentSize) { _, size in
                reportVisibleSize(size)
            }
            .onChange(of: isExpanded) { _, expanded in
                onExpandedStateChanged?(expanded)
            }
            .onChange(of: quoteIDs) { previousIDs, currentIDs in
                reconcileSelectedQuote()
                if let positionPopoverQuoteID,
                   !currentIDs.contains(positionPopoverQuoteID)
                {
                    self.positionPopoverQuoteID = nil
                }
                guard currentIDs.count > previousIDs.count else { return }
                if let addedID = currentIDs.first(where: { !previousIDs.contains($0) }) {
                    selectedQuoteID = addedID
                }
                dismissAddSymbolInput(cancelEntry: false)
            }
            .onChange(of: isAddingSymbol) { _, adding in
                guard adding else { return }
                Task { @MainActor in
                    await Task.yield()
                    isSymbolFieldFocused = true
                }
            }
    }

    private var currentContentSize: CGSize {
        DashboardLayout.contentSize(expanded: isExpanded)
    }

    private var currentVisibleHeight: CGFloat {
        isExpanded
            ? DashboardLayout.expandedIslandSize.height
            : DashboardLayout.collapsedIslandSize.height
    }

    private func reportVisibleSize(_ size: CGSize) {
        Task { @MainActor in
            await Task.yield()
            onVisibleSizeChanged?(size)
        }
    }

    private var quoteIDs: [Int] {
        model.snapshot.quotes.map(\.id)
    }

    private var selectedQuote: QuoteSnapshot? {
        guard let selectedQuoteID else { return model.snapshot.quotes.first }
        return model.snapshot.quotes.first(where: { $0.id == selectedQuoteID })
            ?? model.snapshot.quotes.first
    }

    private var isInterfaceActive: Bool {
        interfaceActiveOverride ?? isExpanded
    }

    private var island: some View {
        let revealShape = DrawerRevealShape(expansion: isExpanded ? 1 : 0)

        return ZStack(alignment: .top) {
            // Draw the shell as the reveal geometry itself. Previously a full
            // black rectangle relied on clipShape to hide its corners; if
            // WindowServer discarded that cached mask while the panel was
            // compact, the raw rectangle could remain visible until the next
            // hover animation invalidated it.
            revealShape
                .fill(Color.black)

            expandedIsland
                .mask(revealShape.fill(Color.white))
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
        }
        // Keep the complete drawer and its content laid out at all times.
        // Only this single animated clip changes, revealing the live surface
        // from top to bottom without cross-fading or scaling separate layers.
        .frame(
            width: DashboardLayout.expandedIslandSize.width,
            height: DashboardLayout.expandedIslandSize.height,
            alignment: .top
        )
        .contentShape(revealShape)
        .frame(
            width: DashboardLayout.expandedIslandSize.width,
            height: currentVisibleHeight,
            alignment: .top
        )
        .clipped()
        .onTapGesture {
            guard !isExpanded else { return }
            setHovering(true)
        }
        .animation(DashboardLayout.islandAnimation, value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: selectedQuoteID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "OpenIBKR Dynamic Island" : "Expand OpenIBKR controls")
        .overlay {
            PositionPopupHost(
                isPresented: positionPopoverQuote != nil,
                content: AnyView(
                    Group {
                        if let quote = positionPopoverQuote {
                            positionPopover(for: quote)
                        }
                    }
                ),
                onDismiss: dismissPositionPopover
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }

    private var expandedIsland: some View {
        HStack(spacing: 0) {
            dailyPnL
                .frame(width: 190, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1, height: 82)
                .padding(.horizontal, 18)

            watchlist
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dailyPnL: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TODAY'S P&L")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.48))

            Text(
                dailyPnLAmountText(
                    model.snapshot.pnl.daily,
                    currency: model.snapshot.account.currency
                )
            )
            .font(.system(size: 25, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .allowsTightening(true)
            .foregroundStyle(pnlDirectionColor(model.snapshot.pnl.daily))

            Text(dailyPnLPercentText(model.snapshot.dailyPnLPercent))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(pnlDirectionColor(model.snapshot.pnl.daily))
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var watchlist: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("WATCHLIST")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(Color.white.opacity(0.48))

                Spacer(minLength: 8)

                Button {
                    showAddSymbolInput()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.58))
                .accessibilityLabel("Add U.S. Stock Symbol")
            }

            if !model.contractCandidates.isEmpty {
                contractCandidates
            } else if isAddingSymbol {
                addSymbol
            } else if let selectedQuote {
                ticker(selectedQuote)
                    .id(selectedQuote.id)
            } else {
                emptyWatchlist
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            if !quoteIDs.isEmpty, !isAddingSymbol, model.contractCandidates.isEmpty {
                watchlistPositionIndicator
            }
        }
        .overlay {
            ScrollWheelCaptureView { sample in
                handleScroll(sample)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    private var watchlistPositionIndicator: some View {
        let selectedIndex = selectedQuoteID.flatMap { quoteIDs.firstIndex(of: $0) } ?? 0
        let visibleRange = IslandWatchlistSelection.visibleIndicatorRange(
            selected: selectedIndex,
            count: quoteIDs.count
        )

        return HStack(spacing: 4) {
            ForEach(Array(visibleRange), id: \.self) { index in
                let isSelected = index == selectedIndex
                Button {
                    selectQuote(at: index)
                } label: {
                    Circle()
                        .fill(
                            isSelected
                                ? Color(red: 0.48, green: 0.74, blue: 1.0)
                                : Color.white.opacity(0.22)
                        )
                        .frame(width: 5, height: 5)
                        .scaleEffect(isSelected ? 1.32 : 1)
                        .shadow(
                            color: isSelected
                                ? Color(red: 0.48, green: 0.74, blue: 1.0).opacity(0.32)
                                : .clear,
                            radius: 2
                        )
                        .frame(width: 11, height: 11)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Show \(model.snapshot.quotes[index].instrument.symbol), "
                        + "watchlist item \(index + 1) of \(quoteIDs.count)"
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .transition(.scale(scale: 0.55).combined(with: .opacity))
            }
        }
        .animation(
            .spring(response: 0.28, dampingFraction: 0.78, blendDuration: 0.05),
            value: selectedQuoteID
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Watchlist position")
    }

    private func ticker(_ quote: QuoteSnapshot) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(quoteDailyChangeColor(quote))
                        .frame(width: 6, height: 6)

                    Text(quote.instrument.symbol)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)

                    Button {
                        model.remove(conId: quote.instrument.conId)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.34))
                    .accessibilityLabel("Remove \(quote.instrument.symbol)")
                }

                Text(quotePriceText(quote))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        quote.stale ? Color.white.opacity(0.45) : Color.white.opacity(0.80)
                    )

                Text(changeText(quote))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(quoteDailyChangeColor(quote))
            }
            .frame(width: 112, alignment: .leading)

            QuoteSparkline(
                points: model.quoteTrends[quote.id] ?? [],
                color: quoteDailyChangeColor(quote)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .opacity((model.quoteTrends[quote.id] ?? []).count >= 2 ? 1 : 0)
            // The complete ticker row owns the click gesture. Keeping the
            // drawing view out of hit testing makes its full curve area part
            // of the same reliable popup target as the text and prices.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            showPositionPopover(for: quote.id)
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)),
                removal: .opacity.combined(with: .offset(y: -6))
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quoteAccessibilityLabel(quote))
    }

    private var emptyWatchlist: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))
            Text("No Watchlist")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var addSymbol: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $model.symbolInput,
                prompt: Text("Ticker, e.g. AAPL")
                    .foregroundStyle(Color.white.opacity(0.34))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.86))
            .focused($isSymbolFieldFocused)
            .onSubmit {
                guard !model.isSearchingSymbol else { return }
                model.addSymbol()
            }

            if model.isSearchingSymbol {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
            }

            Button("Add") {
                model.addSymbol()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.72))
            .disabled(
                model.isSearchingSymbol
                    || model.symbolInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))

            OutsideClickMonitor {
                dismissAddSymbolInput()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            if let error = model.symbolErrorMessage {
                Text(error)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .offset(y: 28)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 5)))
    }

    private var contractCandidates: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SELECT CONTRACT")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.48))

                Spacer()

                Button("Cancel") {
                    model.cancelCandidateSelection()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))
            }

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.contractCandidates) { instrument in
                        Button {
                            model.selectCandidate(instrument)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(instrument.localSymbol ?? instrument.symbol)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.86))
                                    Text(instrument.primaryExchange ?? instrument.exchange)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.white.opacity(0.42))
                                }
                                Spacer()
                                Text("#\(instrument.conId)")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.36))
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 34)
                            .background(
                                Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isSearchingSymbol)
                    }
                }
            }
            .frame(maxHeight: 70)
            .scrollIndicators(.hidden)
        }
        .transition(.opacity.combined(with: .offset(y: 5)))
    }

    private func handlePointerSample(_ sample: PointerTrackingSample) {
        let hasMoved: Bool
        if let lastPointerLocation {
            let deltaX = sample.screenLocation.x - lastPointerLocation.x
            let deltaY = sample.screenLocation.y - lastPointerLocation.y
            hasMoved = deltaX * deltaX + deltaY * deltaY > 1
        } else {
            hasMoved = true
        }
        lastPointerLocation = sample.screenLocation

        if sample.isInside {
            if suppressReactivationUntilPointerMoves {
                guard hasMoved else { return }
                suppressReactivationUntilPointerMoves = false
            }
            guard !isPointerInside else { return }
            isPointerInside = true
            setHovering(true)
            return
        }

        if suppressReactivationUntilPointerMoves, hasMoved {
            suppressReactivationUntilPointerMoves = false
        }
        guard isPointerInside else { return }
        isPointerInside = false
        setHovering(false)
    }

    private func setHovering(_ hovering: Bool) {
        hoverGeneration += 1
        let generation = hoverGeneration

        if hovering {
            guard !isExpanded else { return }
            // Grow the transparent AppKit host before SwiftUI starts revealing
            // the drawer. Without this preflight notification, the first
            // expansion frame can be laid out in the compact-height window and
            // briefly appear detached from the top edge.
            onExpandedStateChanged?(true)
            withAnimation(DashboardLayout.islandAnimation) {
                isExpanded = true
            }
            return
        }

        Task { @MainActor in
            // A short grace period prevents the pointer crossing the changing
            // edge of the panel from immediately cancelling the expansion.
            try? await Task.sleep(for: .milliseconds(100))
            guard generation == hoverGeneration else { return }
            guard positionPopoverQuoteID == nil else { return }
            suppressReactivationUntilPointerMoves = true
            withAnimation(DashboardLayout.islandAnimation) {
                isExpanded = false
            }
            if isAddingSymbol {
                dismissAddSymbolInput()
            }
        }
    }

    private func handleScroll(_ sample: IslandScrollSample) {
        guard isExpanded, !isAddingSymbol, model.contractCandidates.isEmpty else { return }
        guard !model.snapshot.quotes.isEmpty else { return }
        guard let direction = scrollGate.consume(sample) else { return }
        stepSelectedQuote(by: direction)
    }

    private func handlePositionPopoverScroll(_ sample: IslandScrollSample) {
        guard positionPopoverQuoteID != nil, !isPositionSlotListPresented else { return }
        guard !model.snapshot.quotes.isEmpty else { return }
        guard let direction = positionPopoverScrollGate.consume(sample) else { return }
        stepSelectedQuote(by: direction)
    }

    private func stepSelectedQuote(by offset: Int) {
        guard !model.snapshot.quotes.isEmpty else {
            selectedQuoteID = nil
            return
        }

        let ids = quoteIDs
        let currentIndex = selectedQuoteID.flatMap { ids.firstIndex(of: $0) } ?? 0
        guard
            let nextIndex = IslandWatchlistSelection.wrappedIndex(
                current: currentIndex,
                offset: offset,
                count: ids.count
            )
        else { return }
        selectQuote(at: nextIndex)
    }

    private func selectQuote(at index: Int) {
        guard quoteIDs.indices.contains(index) else { return }
        let nextID = quoteIDs[index]
        guard nextID != selectedQuoteID else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78, blendDuration: 0.05)) {
            selectedQuoteID = nextID
            if positionPopoverQuoteID != nil {
                positionPopoverQuoteID = nextID
                isPositionSlotListPresented = false
            }
        }
    }

    private func showPositionPopover(for quoteID: Int) {
        hoverGeneration += 1
        positionPopoverScrollGate.reset()
        isPositionSlotListPresented = false
        positionPopoverQuoteID = positionPopoverQuoteID == quoteID ? nil : quoteID
        if positionPopoverQuoteID == nil, !isPointerInside {
            setHovering(false)
        }
    }

    private var positionPopoverQuote: QuoteSnapshot? {
        guard let positionPopoverQuoteID else { return nil }
        return model.snapshot.quotes.first(where: { $0.id == positionPopoverQuoteID })
    }

    private func dismissPositionPopover() {
        guard positionPopoverQuoteID != nil else { return }
        positionPopoverScrollGate.reset()
        isPositionSlotListPresented = false
        positionPopoverQuoteID = nil
        if !isPointerInside {
            setHovering(false)
        }
    }

    @ViewBuilder
    private func positionPopover(for quote: QuoteSnapshot) -> some View {
        let position = model.snapshot.position(for: quote.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(positionStatusColor(position))
                    .frame(width: 7, height: 7)

                Text(quote.instrument.symbol)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.94))

                Spacer()

                Text(positionStatusText(position))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.42))
            }

            PositionPriceChart(
                points: model.quoteTrends[quote.id] ?? [],
                averageCost: position?.averageCost.value,
                previousClose: quote.validClose?.value,
                costSlots: position?.resolvedCostSlots ?? [],
                currency: quote.instrument.currency,
                averageCostText: money(
                    position?.averageCost,
                    currency: quote.instrument.currency
                ),
                previousCloseText: money(
                    quote.validClose,
                    currency: quote.instrument.currency
                ),
                trendColor: quoteDailyChangeColor(quote),
                showsSlotList: $isPositionSlotListPresented
            )
            .frame(height: 142)
            .padding(.top, 16)

            if let position {
                HStack(spacing: 18) {
                    positionMetric(
                        title: "POSITION",
                        value: quantityText(position.quantity.value, quote: quote)
                    )
                    positionMetric(
                        title: "MARKET VALUE",
                        value: money(position.marketValue, currency: quote.instrument.currency),
                        alignment: .trailing
                    )
                }
                .padding(.top, 16)

                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 1)
                    .padding(.vertical, 14)

                HStack(spacing: 18) {
                    positionMetric(
                        title: "AVG COST",
                        value: money(position.averageCost, currency: quote.instrument.currency)
                    )
                    positionMetric(
                        title: "UNREALIZED",
                        value: signedMoney(
                            position.unrealizedPnl,
                            currency: quote.instrument.currency
                        ),
                        detail: signedPercent(position.returnPercent),
                        color: positionDirectionColor(position.unrealizedPnl),
                        alignment: .trailing
                    )
                }

                HStack {
                    Text("TODAY")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(Color.white.opacity(0.38))
                    Spacer()
                    Text(signedMoney(position.dailyPnl, currency: quote.instrument.currency))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(positionDirectionColor(position.dailyPnl))
                }
                .padding(.top, 16)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "briefcase")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.34))
                    Text("No position in this account")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 25)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(positionStatusColor(position))
                    .frame(width: 5, height: 5)
                Text(position?.stale == false ? "IBKR · LIVE" : "IBKR · WAITING")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .tracking(0.65)
                    .foregroundStyle(Color.white.opacity(0.32))
            }
            .padding(.top, position == nil ? 0 : 16)
        }
        .padding(18)
        .frame(width: 348)
        .background(
            Color(red: 0.055, green: 0.055, blue: 0.062),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            ScrollWheelCaptureView { sample in
                handlePositionPopoverScroll(sample)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Position details for \(quote.instrument.symbol)")
    }

    private func positionMetric(
        title: String,
        value: String,
        detail: String? = nil,
        color: Color = Color.white.opacity(0.86),
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .tracking(0.65)
                .foregroundStyle(Color.white.opacity(0.36))
            HStack(spacing: 5) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color.opacity(0.82))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    private func positionStatusText(_ position: PositionSnapshot?) -> String {
        guard let position else { return "NO POSITION" }
        return position.stale ? "STALE" : "POSITION"
    }

    private func positionStatusColor(_ position: PositionSnapshot?) -> Color {
        guard let position else { return Color.white.opacity(0.22) }
        return position.stale ? Color.orange.opacity(0.72) : Color.green.opacity(0.86)
    }

    private func quantityText(_ quantity: Decimal, quote: QuoteSnapshot) -> String {
        let places = quote.instrument.secType == "STK" ? 4 : 2
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = places
        return formatter.string(from: NSDecimalNumber(decimal: quantity)) ?? "—"
    }

    private func signedMoney(_ value: DecimalString?, currency: String?) -> String {
        guard let value else { return "—" }
        let magnitude = value.value < 0 ? -value.value : value.value
        let formatted = money(DecimalString(magnitude), currency: currency)
        if value.value > 0 { return "+\(formatted)" }
        if value.value < 0 { return "-\(formatted)" }
        return formatted
    }

    private func signedPercent(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(decimal(value, places: 2))%"
    }

    private func positionDirectionColor(_ value: DecimalString?) -> Color {
        guard let value else { return Color.white.opacity(0.58) }
        if value.value > 0 { return .green }
        if value.value < 0 { return .red }
        return Color.white.opacity(0.72)
    }

    private func reconcileSelectedQuote() {
        let ids = quoteIDs
        guard !ids.isEmpty else {
            selectedQuoteID = nil
            return
        }
        if let selectedQuoteID, ids.contains(selectedQuoteID) { return }
        selectedQuoteID = ids[0]
    }

    private func showAddSymbolInput() {
        model.beginSymbolEntry()
        withAnimation(.easeInOut(duration: 0.18)) {
            isAddingSymbol = true
        }
    }

    private func dismissAddSymbolInput(cancelEntry: Bool = true) {
        guard isAddingSymbol || isSymbolFieldFocused else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isAddingSymbol = false
            isSymbolFieldFocused = false
        }
        if cancelEntry { model.cancelSymbolEntry() }
    }

    private func dailyPnLAmountText(_ value: DecimalString?, currency: String?) -> String {
        guard let value else { return "—" }
        let magnitude = value.value < 0 ? -value.value : value.value
        let unsignedAmount = money(DecimalString(magnitude), currency: currency)
        if value.value > 0 { return "+\(unsignedAmount)" }
        if value.value < 0 { return "-\(unsignedAmount)" }
        return unsignedAmount
    }

    private func dailyPnLPercentText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(decimal(value, places: 2))%"
    }

    private func money(_ value: DecimalString?, currency: String?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        let currencyCode = currency ?? "USD"
        formatter.currencyCode = currencyCode
        if currencyCode == "USD" { formatter.currencySymbol = "$" }
        return formatter.string(from: NSDecimalNumber(decimal: value.value)) ?? "—"
    }

    private func quotePriceText(_ quote: QuoteSnapshot) -> String {
        guard let value = quote.displayPrice else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        let currencyCode = quote.instrument.currency.isEmpty ? "USD" : quote.instrument.currency
        formatter.currencyCode = currencyCode
        if currencyCode == "USD" { formatter.currencySymbol = "$" }
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSDecimalNumber(decimal: value.value)) ?? "—"
    }

    private func changeText(_ quote: QuoteSnapshot) -> String {
        guard let (change, percent) = quote.priceChange else { return "—" }
        let sign = change > 0 ? "+" : ""
        return "\(sign)\(decimal(change, places: 2))  \(sign)\(decimal(percent, places: 2))%"
    }

    private func decimal(_ value: Decimal, places: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }

    private func pnlDirectionColor(_ value: DecimalString?) -> Color {
        guard isInterfaceActive, let value else { return Color.white.opacity(0.84) }
        if value.value > 0 { return .green }
        if value.value < 0 { return .red }
        return Color.white.opacity(0.72)
    }

    private func quoteDailyChangeColor(_ quote: QuoteSnapshot) -> Color {
        guard let change = quote.priceChange?.absolute else {
            return Color.white.opacity(0.38)
        }
        if change > 0 { return .green }
        if change < 0 { return .red }
        return Color.white.opacity(0.48)
    }

    private func quoteAccessibilityLabel(_ quote: QuoteSnapshot) -> String {
        let stale = quote.stale ? ", data is stale" : ""
        return
            "\(quote.instrument.symbol), price \(quotePriceText(quote)), \(changeText(quote))\(stale)"
    }
}

private struct QuoteSparkline: View {
    let points: [QuoteTrendPoint]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard points.count >= 2 else { return }
                let values = points.map { NSDecimalNumber(decimal: $0.price.value).doubleValue }
                guard let minimum = values.min(), let maximum = values.max() else { return }
                let range = maximum - minimum
                let width = proxy.size.width
                let height = proxy.size.height

                for (index, value) in values.enumerated() {
                    let x = width * CGFloat(index) / CGFloat(values.count - 1)
                    let normalized = range == 0 ? 0.5 : (value - minimum) / range
                    let y = height - height * CGFloat(normalized)
                    let point = CGPoint(x: x, y: y)
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )
        }
        .padding(.vertical, 2)
    }
}

struct PositionSlotSelection {
    static func wrappedIndex(current: Int, offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return ((current + offset) % count + count) % count
    }

    static func nearestIndex(
        values: [Double],
        minimum: Double,
        maximum: Double,
        height: CGFloat,
        pointerY: CGFloat
    ) -> Int? {
        guard !values.isEmpty, height > 0 else { return nil }
        let range = maximum - minimum
        guard range > 0 else { return 0 }
        return values.enumerated().min { lhs, rhs in
            let lhsY = height * (1 - CGFloat((lhs.element - minimum) / range))
            let rhsY = height * (1 - CGFloat((rhs.element - minimum) / range))
            return abs(lhsY - pointerY) < abs(rhsY - pointerY)
        }?.offset
    }
}

private struct PositionPriceChart: View {
    struct Reference: Identifiable {
        let id: String
        let title: String
        let value: Double
        let text: String
        let detail: String?
        let color: Color
        let dash: [CGFloat]

        var isSlot: Bool { id.hasPrefix("slot:") }
    }

    let points: [QuoteTrendPoint]
    let averageCost: Decimal?
    let previousClose: Decimal?
    let costSlots: [PositionCostSlot]
    let currency: String
    let averageCostText: String
    let previousCloseText: String
    let trendColor: Color
    @Binding var showsSlotList: Bool

    @State private var selectedSlotID: String?

    private var trendValues: [Double] {
        points.map { NSDecimalNumber(decimal: $0.price.value).doubleValue }
    }

    private func slotPriceText(_ price: DecimalString) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        let currencyCode = currency.isEmpty ? "USD" : currency
        formatter.currencyCode = currencyCode
        if currencyCode == "USD" { formatter.currencySymbol = "$" }
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSDecimalNumber(decimal: price.value)) ?? "—"
    }

    private func slotQuantityText(_ quantity: DecimalString) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSDecimalNumber(decimal: quantity.value)) ?? "—"
    }

    private var references: [Reference] {
        var result: [Reference] = []
        if let previousClose {
            result.append(
                Reference(
                    id: "previous",
                    title: "CLOSE",
                    value: NSDecimalNumber(decimal: previousClose).doubleValue,
                    text: previousCloseText,
                    detail: nil,
                    color: Color.white.opacity(0.38),
                    dash: [2, 4]
                )
            )
        }
        if let averageCost {
            result.append(
                Reference(
                    id: "average",
                    title: "AVG",
                    value: NSDecimalNumber(decimal: averageCost).doubleValue,
                    text: averageCostText,
                    detail: nil,
                    color: Color.orange.opacity(0.82),
                    dash: [6, 4]
                )
            )
        }
        for (index, slot) in costSlots.enumerated() {
            result.append(
                Reference(
                    id: "slot:\(slot.id)",
                    title: "SLOT \(index + 1)",
                    value: NSDecimalNumber(decimal: slot.price.value).doubleValue,
                    text: slotPriceText(slot.price),
                    detail: "×\(slotQuantityText(slot.quantity))",
                    color: Color(red: 0.49, green: 0.84, blue: 1.0),
                    dash: []
                )
            )
        }
        return result
    }

    private var fixedReferences: [Reference] {
        references.filter { !$0.isSlot }
    }

    private var slotReferences: [Reference] {
        references.filter(\.isSlot)
    }

    private var selectedSlot: Reference? {
        selectedSlotID.flatMap { id in slotReferences.first { $0.id == id } }
    }

    private var selectedSlotIndex: Int? {
        selectedSlotID.flatMap { id in slotReferences.firstIndex { $0.id == id } }
    }

    private func legend(for reference: Reference) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(reference.color)
                .frame(width: 10, height: 1)
            Text("\(reference.title) \(reference.text)")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.52))
                .lineLimit(1)
        }
    }

    private func selectNearestSlot(
        pointerY: CGFloat,
        minimum: Double,
        maximum: Double,
        height: CGFloat
    ) {
        guard !showsSlotList else { return }
        guard let index = PositionSlotSelection.nearestIndex(
            values: slotReferences.map(\.value),
            minimum: minimum,
            maximum: maximum,
            height: height,
            pointerY: pointerY
        ) else { return }
        selectedSlotID = slotReferences[index].id
    }

    private var slotList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())],
                spacing: 6
            ) {
                ForEach(slotReferences) { slot in
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            selectedSlotID = slot.id
                            showsSlotList = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(
                                    selectedSlotID == slot.id
                                        ? slot.color
                                        : Color.white.opacity(0.18)
                                )
                                .frame(width: 5, height: 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(slot.title)
                                    .foregroundStyle(Color.white.opacity(0.48))
                                Text(slot.text)
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.82))
                            }
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            Spacer(minLength: 2)
                            if let detail = slot.detail {
                                Text(detail)
                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white.opacity(0.32))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Color.white.opacity(selectedSlotID == slot.id ? 0.09 : 0.035),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { isInside in
                        if isInside { selectedSlotID = slot.id }
                    }
                }
            }
            .padding(8)
        }
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach(fixedReferences) { reference in
                    legend(for: reference)
                }

                Spacer(minLength: 4)

                if !slotReferences.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showsSlotList.toggle()
                            if showsSlotList, selectedSlotID == nil {
                                selectedSlotID = slotReferences.first?.id
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(red: 0.49, green: 0.84, blue: 1.0).opacity(0.82))
                                .frame(width: 5, height: 5)
                            Text(
                                selectedSlotIndex.map { "SLOT \($0 + 1)/\(slotReferences.count)" }
                                    ?? "SLOTS ×\(slotReferences.count)"
                            )
                            Image(systemName: showsSlotList ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.055), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show all position slots")
                }
            }

            GeometryReader { proxy in
                let allValues = trendValues + references.map(\.value)
                let rawMinimum = allValues.min() ?? 0
                let rawMaximum = allValues.max() ?? 1
                let rawRange = rawMaximum - rawMinimum
                let padding = max(abs(rawMaximum) * 0.006, rawRange * 0.10, 0.01)
                let minimum = rawMinimum - padding
                let maximum = rawMaximum + padding
                let range = maximum - minimum

                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.035))

                    ForEach(1..<4, id: \.self) { index in
                        Path { path in
                            let y = proxy.size.height * CGFloat(index) / 4
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                        .stroke(Color.white.opacity(0.045), lineWidth: 1)
                    }

                    ForEach(references) { reference in
                        let isSelectedSlot = reference.id == selectedSlotID
                        Path { path in
                            let normalized = (reference.value - minimum) / range
                            let y = proxy.size.height * (1 - CGFloat(normalized))
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                        .stroke(
                            reference.color.opacity(
                                reference.isSlot
                                    ? (isSelectedSlot ? 0.98 : (selectedSlotID == nil ? 0.34 : 0.15))
                                    : 0.58
                            ),
                            style: StrokeStyle(
                                lineWidth: reference.isSlot ? (isSelectedSlot ? 1.8 : 0.9) : 1,
                                lineCap: .round,
                                dash: reference.dash
                            )
                        )
                    }

                    Path { path in
                        guard trendValues.count >= 2 else { return }
                        for (index, value) in trendValues.enumerated() {
                            let x = proxy.size.width * CGFloat(index)
                                / CGFloat(trendValues.count - 1)
                            let normalized = (value - minimum) / range
                            let y = proxy.size.height * (1 - CGFloat(normalized))
                            let point = CGPoint(x: x, y: y)
                            index == 0 ? path.move(to: point) : path.addLine(to: point)
                        }
                    }
                    .stroke(
                        trendColor,
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                    )

                    if trendValues.count < 2 {
                        Text("Collecting price history")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.28))
                    }

                    if let selectedSlot {
                        let normalized = (selectedSlot.value - minimum) / range
                        let labelY = min(
                            max(proxy.size.height * (1 - CGFloat(normalized)), 13),
                            proxy.size.height - 13
                        )
                        Text("\(selectedSlot.title)  \(selectedSlot.text)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.90))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.82), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(selectedSlot.color.opacity(0.35), lineWidth: 1)
                            }
                            .position(x: max(62, proxy.size.width - 64), y: labelY)
                            .allowsHitTesting(false)
                    }

                    if showsSlotList {
                        slotList
                            .padding(4)
                    }
                }
                .clipped()
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        selectNearestSlot(
                            pointerY: location.y,
                            minimum: minimum,
                            maximum: maximum,
                            height: proxy.size.height
                        )
                    case .ended:
                        if !showsSlotList { selectedSlotID = nil }
                    }
                }
            }
        }
        .onChange(of: slotReferences.map(\.id)) { _, ids in
            if let selectedSlotID, !ids.contains(selectedSlotID) {
                self.selectedSlotID = nil
            }
            if ids.isEmpty { showsSlotList = false }
        }
    }
}

private struct PositionPopupHost: NSViewRepresentable {
    let isPresented: Bool
    let content: AnyView
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            anchorView: nsView,
            isPresented: isPresented,
            content: content,
            onDismiss: onDismiss
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.hide()
    }

    @MainActor
    final class Coordinator {
        private static let gap: CGFloat = 10
        private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        private var panel: PositionDetailPanel?
        private weak var parentWindow: NSWindow?
        private var localMouseMonitor: Any?
        private var globalMouseMonitor: Any?
        private var keyMonitor: Any?
        private var onDismiss: (() -> Void)?
        private var pendingPresentation = false

        func update(
            anchorView: NSView,
            isPresented: Bool,
            content: AnyView,
            onDismiss: @escaping () -> Void
        ) {
            self.onDismiss = onDismiss
            guard isPresented else {
                pendingPresentation = false
                hide()
                return
            }

            hostingView.rootView = content
            guard let parentWindow = anchorView.window else {
                guard !pendingPresentation else { return }
                pendingPresentation = true
                DispatchQueue.main.async { [weak self, weak anchorView] in
                    guard let self, let anchorView else { return }
                    self.pendingPresentation = false
                    self.update(
                        anchorView: anchorView,
                        isPresented: true,
                        content: content,
                        onDismiss: onDismiss
                    )
                }
                return
            }
            pendingPresentation = false
            show(below: parentWindow)
        }

        func hide() {
            stopMonitoring()
            if let panel, let parentWindow {
                parentWindow.removeChildWindow(panel)
            }
            panel?.orderOut(nil)
            parentWindow = nil
        }

        private func show(below parentWindow: NSWindow) {
            let panel = panel ?? makePanel()
            hostingView.layoutSubtreeIfNeeded()
            var contentSize = hostingView.fittingSize
            if contentSize.width < 1 || contentSize.height < 1 {
                contentSize = NSSize(width: 348, height: 340)
            }
            hostingView.frame = NSRect(origin: .zero, size: contentSize)
            panel.setContentSize(contentSize)

            if self.parentWindow !== parentWindow {
                if let previousParent = self.parentWindow {
                    previousParent.removeChildWindow(panel)
                }
                parentWindow.addChildWindow(panel, ordered: .above)
                self.parentWindow = parentWindow
            }

            let screenFrame = parentWindow.screen?.frame ?? parentWindow.frame
            let preferredX = parentWindow.frame.midX - contentSize.width / 2
            let x = min(
                max(screenFrame.minX, preferredX),
                screenFrame.maxX - contentSize.width
            )
            let frame = NSRect(
                x: x,
                y: parentWindow.frame.minY - Self.gap - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            panel.setFrame(frame, display: true, animate: false)
            panel.orderFront(nil)
            startMonitoring(panel: panel, parentWindow: parentWindow)
        }

        private func makePanel() -> PositionDetailPanel {
            let panel = PositionDetailPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = hostingView
            self.panel = panel
            return panel
        }

        private func startMonitoring(panel: NSPanel, parentWindow: NSWindow) {
            guard localMouseMonitor == nil else { return }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self, weak panel, weak parentWindow] event in
                if event.window !== panel, event.window !== parentWindow {
                    self?.requestDismiss()
                }
                return event
            }
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.requestDismiss()
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                if event.keyCode == 53 {
                    self?.requestDismiss()
                    return nil
                }
                return event
            }
        }

        private func requestDismiss() {
            Task { @MainActor [weak self] in
                self?.onDismiss?()
            }
        }

        private func stopMonitoring() {
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
                self.localMouseMonitor = nil
            }
            if let globalMouseMonitor {
                NSEvent.removeMonitor(globalMouseMonitor)
                self.globalMouseMonitor = nil
            }
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        deinit {
            MainActor.assumeIsolated {
                stopMonitoring()
            }
        }
    }
}

private final class PositionDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct OutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitoringView {
        let view = MonitoringView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: MonitoringView, context: Context) {
        nsView.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: MonitoringView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitoringView: NSView {
        var onOutsideClick: (() -> Void)?
        private var localMonitor: Any?
        private var globalMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stopMonitoring() : startMonitoring()
        }

        func stopMonitoring() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
        }

        private func startMonitoring() {
            guard localMonitor == nil, globalMonitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
                [weak self] event in
                self?.handleLocalMouseDown(event)
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
                [weak self] _ in
                self?.notifyOutsideClick()
            }
        }

        private func handleLocalMouseDown(_ event: NSEvent) {
            guard let window, event.window === window else {
                notifyOutsideClick()
                return
            }
            let localPoint = convert(event.locationInWindow, from: nil)
            guard !bounds.contains(localPoint) else { return }
            notifyOutsideClick()
        }

        private func notifyOutsideClick() {
            DispatchQueue.main.async { [weak self] in
                self?.onOutsideClick?()
            }
        }

        deinit { stopMonitoring() }
    }
}

private struct PointerTrackingView: NSViewRepresentable {
    let isExpanded: Bool
    let onLocationChanged: (PointerTrackingSample) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.isExpanded = isExpanded
        view.onLocationChanged = onLocationChanged
        view.startTracking()
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.isExpanded = isExpanded
        nsView.onLocationChanged = onLocationChanged
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopTracking()
    }

    final class TrackingView: NSView {
        var onLocationChanged: ((PointerTrackingSample) -> Void)?
        var isExpanded = false
        private var timer: Timer?
        private var wasInside = false
        private var lastSampleLocation: CGPoint?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stopTracking() : startTracking()
        }

        func stopTracking() {
            timer?.invalidate()
            timer = nil
            wasInside = false
            lastSampleLocation = nil
        }

        func startTracking() {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                self?.samplePointer()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            samplePointer()
        }

        private func samplePointer() {
            guard let window, window.isVisible else {
                wasInside = false
                lastSampleLocation = nil
                return
            }

            // AppKit's background-drag handling moves the panel while the
            // pointer is temporarily outside its old bounds. Do not turn a
            // drag into a hover-exit transition until the mouse is released.
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }

            // Track the visible black drawer, not the transparent shadow
            // padding around its host window. In compact mode only the 14 pt
            // curved lip is visible; counting the full 34 pt panel made the
            // drawer open before the pointer visually reached it.
            let trackingRectOnScreen = DashboardLayout.pointerTrackingRect(
                windowFrame: window.frame,
                expanded: isExpanded
            )
            let screenLocation = NSEvent.mouseLocation
            let isInside = DashboardLayout.pointerIsInside(
                screenLocation,
                trackingRect: trackingRectOnScreen
            )
            let hasMoved: Bool
            if let lastSampleLocation {
                let deltaX = screenLocation.x - lastSampleLocation.x
                let deltaY = screenLocation.y - lastSampleLocation.y
                hasMoved = deltaX * deltaX + deltaY * deltaY > 1
            } else {
                hasMoved = true
            }
            // Keep sampling while inside. Some pointer drivers update the
            // cursor location without delivering a mouse-moved event; the
            // state machine still filters duplicate inside samples and keeps
            // the post-collapse re-entry lock intact.
            guard isInside || isInside != wasInside || hasMoved else { return }

            wasInside = isInside
            lastSampleLocation = screenLocation
            onLocationChanged?(
                PointerTrackingSample(
                    screenLocation: screenLocation,
                    isInside: isInside
                )
            )
        }


        deinit { timer?.invalidate() }
    }
}

private struct ScrollWheelCaptureView: NSViewRepresentable {
    let onScroll: (IslandScrollSample) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: CaptureView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class CaptureView: NSView {
        var onScroll: ((IslandScrollSample) -> Void)?
        private var localMonitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stopMonitoring() : startMonitoring()
        }

        func stopMonitoring() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
        }

        private func startMonitoring() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let localPoint = convert(event.locationInWindow, from: nil)
            guard bounds.contains(localPoint) else { return }
            onScroll?(
                IslandScrollSample(
                    deltaY: event.scrollingDeltaY,
                    phase: event.phase,
                    momentumPhase: event.momentumPhase,
                    timestamp: event.timestamp
                )
            )
        }

        deinit { stopMonitoring() }
    }
}
