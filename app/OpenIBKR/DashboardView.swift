import AppKit
import SwiftUI

enum DashboardLayout {
    static let shadowPadding: CGFloat = 14
    static let collapsedIslandSize = CGSize(width: 520, height: 20)
    static let expandedIslandSize = CGSize(width: 520, height: 148)
    static let drawerLipDepth: CGFloat = 14
    static let expandedTopShoulderDepth: CGFloat = 5
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
    private(set) var hasSteppedInGesture = false
    private var lastEventTimestamp = -Double.infinity

    let threshold: CGFloat
    let discreteGestureGap: TimeInterval

    init(threshold: CGFloat = 22, discreteGestureGap: TimeInterval = 0.24) {
        self.threshold = threshold
        self.discreteGestureGap = discreteGestureGap
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

        guard !hasSteppedInGesture else { return nil }
        accumulator += sample.deltaY
        guard abs(accumulator) >= threshold else { return nil }

        hasSteppedInGesture = true
        let direction = accumulator < 0 ? 1 : -1
        accumulator = 0
        return direction
    }

    mutating func reset() {
        accumulator = 0
        hasSteppedInGesture = false
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
    @State private var isAddingSymbol = false
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
        ZStack(alignment: .top) {
            Color.black

            expandedIsland
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
        .clipShape(DrawerRevealShape(expansion: isExpanded ? 1 : 0))
        .contentShape(DrawerRevealShape(expansion: isExpanded ? 1 : 0))
        .frame(
            width: DashboardLayout.expandedIslandSize.width,
            height: currentVisibleHeight,
            alignment: .top
        )
        .clipped()
        .shadow(
            color: .black.opacity(isExpanded ? 0.35 : 0.13),
            radius: isExpanded ? 14 : 7,
            y: isExpanded ? 5 : 2
        )
        .onTapGesture {
            guard !isExpanded else { return }
            setHovering(true)
        }
        .animation(DashboardLayout.islandAnimation, value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: selectedQuoteID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "OpenIBKR Dynamic Island" : "Expand OpenIBKR controls")
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
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            ScrollWheelCaptureView { sample in
                handleScroll(sample)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
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
        let nextID = ids[nextIndex]

        guard nextID != selectedQuoteID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedQuoteID = nextID
        }
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
