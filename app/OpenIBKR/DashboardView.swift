import AppKit
import SwiftUI

enum DashboardLayout {
    static let pnlHeight: CGFloat = 52
    static let maximumWatchlistHeight: CGFloat = 284
    static let moduleSpacing: CGFloat = 12
    static let shadowPadding: CGFloat = 12
    static let watchlistAccessoryWidth: CGFloat = 24
    static let pnlDragButtonExclusionWidth: CGFloat = 34
    static let cardCornerRadius: CGFloat = 10
    static let collapsedPnLWidth: CGFloat = 117
    static let expandedModuleWidth: CGFloat = 243
    static let emptyWatchlistHeight: CGFloat = 96

    static var initialContentSize: CGSize {
        CGSize(
            width: expandedModuleWidth + shadowPadding * 2,
            height: pnlHeight + moduleSpacing + emptyWatchlistHeight + shadowPadding * 2
        )
    }

    static func moduleWidth(expanded: Bool) -> CGFloat {
        expanded ? expandedModuleWidth : collapsedPnLWidth
    }

    static func quoteListHeight(count: Int, isAddingSymbol: Bool) -> CGFloat {
        let quoteCount = max(0, count)
        let quoteHeight = CGFloat(quoteCount) * 48
        let quoteSpacing = CGFloat(max(0, quoteCount - 1)) * 7
        let inputHeight: CGFloat = isAddingSymbol ? 51 : 0
        return min(
            maximumWatchlistHeight,
            max(44, 20 + quoteHeight + quoteSpacing + inputHeight)
        )
    }

    static func pnlHoverFrame(expanded: Bool) -> CGRect {
        CGRect(x: 0, y: 0, width: moduleWidth(expanded: expanded), height: pnlHeight)
    }

    static func quoteHoverFrame(index: Int, expanded: Bool) -> CGRect {
        let firstRowY = pnlHeight + moduleSpacing + 10
        return CGRect(
            x: 0,
            y: firstRowY + CGFloat(index) * 55,
            width: moduleWidth(expanded: expanded),
            height: 48
        )
    }

    static func stableHoverWidth(watchlistExpanded: Bool, hasAccessory: Bool) -> CGFloat {
        expandedModuleWidth
            + (watchlistExpanded && hasAccessory ? watchlistAccessoryWidth : 0)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appearsActive) private var appearsActive
    @State private var isPnLExpanded: Bool
    @State private var isPointerInside = false
    @State private var interfaceHoverGeneration = 0
    @State private var pnlHoverGeneration = 0
    @State private var quoteHoverGeneration = 0
    @State private var hoverSessionGeneration = 0
    @State private var hoverSessionTargetActive = false
    @State private var usesStableHoverWidth = false
    @State private var interfaceHoverTarget = false
    @State private var pnlHoverTarget = false
    @State private var quoteHoverTarget: Int?
    @State private var isWatchlistExpanded: Bool
    @State private var isAddingSymbol: Bool
    @State private var revealedQuoteCount: Int
    @State private var revealGeneration = 0
    @State private var activeQuoteID: Int?
    @FocusState private var isSymbolFieldFocused: Bool
    private let interfaceActiveOverride: Bool?
    private let onVisibleSizeChanged: ((CGSize) -> Void)?

    init(
        model: AppModel,
        initiallyExpanded: Bool = false,
        interfaceActiveOverride: Bool? = nil,
        watchlistInitiallyExpanded: Bool = true,
        onVisibleSizeChanged: ((CGSize) -> Void)? = nil
    ) {
        self.model = model
        self.interfaceActiveOverride = interfaceActiveOverride
        self.onVisibleSizeChanged = onVisibleSizeChanged
        _isPnLExpanded = State(initialValue: initiallyExpanded)
        _isWatchlistExpanded = State(initialValue: watchlistInitiallyExpanded)
        _isAddingSymbol = State(initialValue: false)
        _revealedQuoteCount = State(initialValue: watchlistInitiallyExpanded ? .max : 0)
        _activeQuoteID = State(initialValue: nil)
    }

    var body: some View {
        modules
            .frame(width: currentModulesWidth, height: currentModulesHeight, alignment: .topLeading)
            // Treat the visible module bounds, including the inter-card gap,
            // as one continuous hover region. Without this shape SwiftUI only
            // hit-tests the rendered cards, so crossing the transparent gap
            // repeatedly toggles the inactive appearance.
            .contentShape(Rectangle())
            .overlay {
                PointerTrackingView { location in
                    if let location {
                        updateHoverTargets(at: location)
                    } else {
                        endHoverSession()
                    }
                }
            }
            .padding(DashboardLayout.shadowPadding)
            .frame(
                width: currentContentSize.width,
                height: currentContentSize.height,
                alignment: .topLeading
            )
            .onAppear {
                reportVisibleSize(currentContentSize)
            }
            .onChange(of: currentContentSize) { _, size in
                reportVisibleSize(size)
            }
            .onChange(of: model.snapshot.quotes.count) { previousCount, currentCount in
                guard currentCount > previousCount else { return }
                withAnimation(.easeInOut(duration: 0.20)) {
                    isAddingSymbol = false
                    if revealedQuoteCount != .max {
                        revealedQuoteCount = currentCount
                    }
                }
            }
            .onChange(of: isSymbolFieldFocused) { wasFocused, isFocused in
                guard wasFocused, !isFocused, isAddingSymbol else { return }
                dismissAddSymbolInput()
            }
    }

    private var isInterfaceActive: Bool {
        interfaceActiveOverride ?? (appearsActive || isPointerInside)
    }

    private var currentWatchlistHeight: CGFloat {
        if !model.contractCandidates.isEmpty {
            return min(
                DashboardLayout.maximumWatchlistHeight,
                34 + CGFloat(model.contractCandidates.count) * 44
                    + (model.symbolErrorMessage == nil ? 0 : 30)
            )
        }
        if model.snapshot.quotes.isEmpty, !isAddingSymbol {
            return DashboardLayout.emptyWatchlistHeight
        }
        return DashboardLayout.quoteListHeight(
            count: model.snapshot.quotes.count,
            isAddingSymbol: isAddingSymbol
        )
    }

    private var watchlistNeedsExpandedWidth: Bool {
        !model.contractCandidates.isEmpty
            || model.snapshot.quotes.isEmpty
            || isAddingSymbol
            || activeQuoteID != nil
    }

    private var watchlistHasAccessory: Bool {
        !model.snapshot.quotes.isEmpty && !isAddingSymbol && model.contractCandidates.isEmpty
    }

    private var currentWatchlistWidth: CGFloat {
        DashboardLayout.moduleWidth(expanded: watchlistNeedsExpandedWidth)
            + (watchlistHasAccessory ? DashboardLayout.watchlistAccessoryWidth : 0)
    }

    private var currentModulesWidth: CGFloat {
        let pnlWidth = DashboardLayout.moduleWidth(expanded: isPnLExpanded)
        let visibleWidth = isWatchlistExpanded
            ? max(pnlWidth, currentWatchlistWidth)
            : pnlWidth
        guard usesStableHoverWidth else { return visibleWidth }

        // Keep one interaction envelope for the entire hover session. A P&L
        // card expands to 243pt while an expanded quote also needs its 24pt
        // accessory rail. Letting NSPanel alternate between those widths made
        // the whole hosted layer re-layout whenever the pointer crossed from
        // one module to the other.
        let stableWidth = DashboardLayout.stableHoverWidth(
            watchlistExpanded: isWatchlistExpanded,
            hasAccessory: watchlistHasAccessory
        )
        return max(visibleWidth, stableWidth)
    }

    private var currentModulesHeight: CGFloat {
        DashboardLayout.pnlHeight
            + (isWatchlistExpanded
                ? DashboardLayout.moduleSpacing + currentWatchlistHeight
                : 0)
    }

    private var currentContentSize: CGSize {
        CGSize(
            width: currentModulesWidth + DashboardLayout.shadowPadding * 2,
            height: currentModulesHeight + DashboardLayout.shadowPadding * 2
        )
    }

    private func reportVisibleSize(_ size: CGSize) {
        Task { @MainActor in
            await Task.yield()
            onVisibleSizeChanged?(size)
        }
    }

    private func setInterfaceHovered(_ hovering: Bool) {
        guard hovering != interfaceHoverTarget else { return }
        interfaceHoverTarget = hovering
        interfaceHoverGeneration += 1
        let generation = interfaceHoverGeneration
        if hovering {
            withAnimation(.easeInOut(duration: 0.22)) {
                isPointerInside = true
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard generation == interfaceHoverGeneration else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                isPointerInside = false
            }
        }
    }

    private func setPnLHovered(_ hovering: Bool) {
        guard hovering != pnlHoverTarget else { return }
        pnlHoverTarget = hovering
        pnlHoverGeneration += 1
        let generation = pnlHoverGeneration
        if hovering {
            withAnimation(.spring(duration: 0.42, bounce: 0.12)) {
                isPnLExpanded = true
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard generation == pnlHoverGeneration else { return }
            withAnimation(.spring(duration: 0.38, bounce: 0.08)) {
                isPnLExpanded = false
            }
        }
    }

    private func setQuoteHovered(_ quoteID: Int?) {
        guard quoteID != quoteHoverTarget else { return }
        quoteHoverTarget = quoteID
        quoteHoverGeneration += 1
        let generation = quoteHoverGeneration
        if let quoteID {
            withAnimation(.spring(duration: 0.38, bounce: 0.10)) {
                activeQuoteID = quoteID
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard generation == quoteHoverGeneration, quoteHoverTarget == nil else { return }
            withAnimation(.spring(duration: 0.34, bounce: 0.06)) {
                activeQuoteID = nil
            }
        }
    }

    private func updateHoverTargets(at location: CGPoint) {
        let startedHoverSession = !hoverSessionTargetActive
        if !hoverSessionTargetActive {
            hoverSessionTargetActive = true
            hoverSessionGeneration += 1
            // Give NSPanel one layout pass to establish the full interaction
            // envelope before a card begins animating into that space. The
            // size callback is intentionally deferred by one main-actor turn,
            // so starting both at once briefly rendered the first P&L
            // expansion inside the old collapsed window.
            withTransaction(Transaction(animation: nil)) {
                usesStableHoverWidth = true
            }
        }
        setInterfaceHovered(true)
        guard !startedHoverSession else { return }
        setPnLHovered(
            DashboardLayout.pnlHoverFrame(expanded: isPnLExpanded).contains(location)
        )
        setQuoteHovered(quoteID(at: location))
    }

    private func endHoverSession() {
        guard hoverSessionTargetActive else { return }
        hoverSessionTargetActive = false
        hoverSessionGeneration += 1
        let generation = hoverSessionGeneration

        interfaceHoverTarget = false
        pnlHoverTarget = false
        quoteHoverTarget = nil
        interfaceHoverGeneration += 1
        pnlHoverGeneration += 1
        quoteHoverGeneration += 1

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            guard generation == hoverSessionGeneration else { return }
            // Commit the complete inactive state in one transaction. Running
            // three independent exit animations made the hosting view report
            // several near-simultaneous sizes to NSPanel, which showed up as
            // a small secondary shake after the pointer had already left.
            withAnimation(.smooth(duration: 0.30)) {
                isPointerInside = false
                isPnLExpanded = false
                activeQuoteID = nil
            }

            // Hold the NSPanel envelope until the visible cards have fully
            // settled, then perform one non-animated window shrink.
            try? await Task.sleep(for: .milliseconds(320))
            guard generation == hoverSessionGeneration else { return }
            withTransaction(Transaction(animation: nil)) {
                usesStableHoverWidth = false
            }
        }
    }

    private func quoteID(at location: CGPoint) -> Int? {
        guard isWatchlistExpanded,
              model.contractCandidates.isEmpty,
              !model.snapshot.quotes.isEmpty
        else { return nil }

        return model.snapshot.quotes.enumerated().first(where: { index, quote in
            guard revealedQuoteCount == .max || index < revealedQuoteCount else { return false }
            return DashboardLayout.quoteHoverFrame(
                index: index,
                expanded: activeQuoteID == quote.id
            ).contains(location)
        })?.element.id
    }

    private var primaryInterfaceColor: Color {
        isInterfaceActive ? .primary : .white.opacity(0.63)
    }

    private var secondaryInterfaceColor: Color {
        isInterfaceActive ? .secondary : .white.opacity(0.50)
    }

    private var tertiaryInterfaceColor: Color {
        isInterfaceActive ? Color.secondary.opacity(0.72) : Color.white.opacity(0.39)
    }

    private func modulePrimaryColor(active: Bool) -> Color {
        active ? primaryInterfaceColor : Color.white.opacity(0.82)
    }

    private func moduleSecondaryColor(active: Bool) -> Color {
        active ? secondaryInterfaceColor : Color.white.opacity(0.56)
    }

    private var modules: some View {
        VStack(alignment: .leading, spacing: DashboardLayout.moduleSpacing) {
            pnlModule
                .frame(
                    width: DashboardLayout.moduleWidth(expanded: isPnLExpanded),
                    height: DashboardLayout.pnlHeight
                )
                .openIBKRGlassCard(active: isPnLExpanded)
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: DashboardLayout.cardCornerRadius,
                        style: .continuous
                    )
                )
                .overlay(alignment: .leading) {
                    WindowDragArea()
                        .frame(
                            width: DashboardLayout.moduleWidth(expanded: isPnLExpanded)
                                - DashboardLayout.pnlDragButtonExclusionWidth,
                            height: DashboardLayout.pnlHeight
                        )
                }

            if isWatchlistExpanded {
                watchlistModule
                    .frame(width: currentWatchlistWidth, height: currentWatchlistHeight)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isInterfaceActive)
    }

    private var pnlModule: some View {
        HStack(alignment: .center, spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Daily P&L")
                    .font(.caption2)
                    .foregroundStyle(moduleSecondaryColor(active: isPnLExpanded))
                HStack(spacing: 2) {
                    Text(
                        dailyPnLAmountText(
                            model.snapshot.pnl.daily,
                            currency: model.snapshot.account.currency
                        )
                    )
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.60)
                        .foregroundStyle(
                            modulePnLValueColor(
                                model.snapshot.pnl.daily,
                                active: isPnLExpanded
                            )
                        )

                    if let arrow = dailyPnLArrow(model.snapshot.pnl.daily) {
                        Text(arrow)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(pnlDirectionColor(model.snapshot.pnl.daily))
                    }
                }
                Text(dailyPnLPercentText(model.snapshot.dailyPnLPercent))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(
                        isPnLExpanded
                            ? pnlDirectionColor(model.snapshot.pnl.daily)
                            : moduleSecondaryColor(active: false)
                    )
            }
            .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)

            if isPnLExpanded {
                HStack(alignment: .center, spacing: 8) {
                    pnlMetric("Unrealized", model.snapshot.pnl.unrealized)
                    pnlMetric("Realized", model.snapshot.pnl.realized)
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.94, anchor: .leading)),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
                    )
                )
            }

            Button {
                setWatchlistExpanded(!isWatchlistExpanded)
            } label: {
                Image(systemName: isWatchlistExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(moduleSecondaryColor(active: isPnLExpanded))
            .accessibilityLabel(isWatchlistExpanded ? "Collapse Watchlist" : "Expand Watchlist")
        }
        .padding(.horizontal, 10)
        .clipped()
    }

    private var watchlistModule: some View {
        Group {
            if !model.contractCandidates.isEmpty {
                contractCandidates
            } else if model.snapshot.quotes.isEmpty, !isAddingSymbol {
                emptyWatchlist
            } else {
                quoteRows
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var quoteRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.snapshot.quotes.enumerated()), id: \.element.id) { index, quote in
                            let expanded = activeQuoteID == quote.id
                            let quoteWidth = DashboardLayout.moduleWidth(expanded: expanded)
                            let revealed = index < revealedQuoteCount

                            HStack(spacing: 6) {
                                quoteRow(quote, expanded: expanded)
                                    .frame(width: quoteWidth)
                                    .contentShape(rowShape)

                                Group {
                                    if index == model.snapshot.quotes.count - 1, !isAddingSymbol {
                                        addSymbolButton
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: 18, height: 24)
                        }
                        .frame(height: 48)
                        .opacity(revealed ? 1 : 0)
                        .offset(x: revealed ? 0 : -22)
                        // Mask the final composited row so macOS glass,
                        // stroke, shadow, and content retract together. The
                        // material layer otherwise outlives the text opacity
                        // and leaves a white rounded-rectangle afterimage.
                        .mask(alignment: .leading) {
                            Rectangle()
                                .scaleEffect(
                                    x: revealed ? 1 : 0,
                                    y: 1,
                                    anchor: .leading
                                )
                        }
                        .animation(.smooth(duration: 0.26), value: revealedQuoteCount)
                    }

                    if isAddingSymbol {
                        addSymbol
                            .frame(minHeight: 44)
                            .background(rowBackground, in: rowShape)
                            .padding(.trailing, DashboardLayout.watchlistAccessoryWidth)
                            .id("add-symbol-input")
                            .transition(
                                .move(edge: .leading)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.97, anchor: .leading))
                            )
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onChange(of: isAddingSymbol) { _, isAdding in
                guard isAdding else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo("add-symbol-input", anchor: .bottom)
                }
                Task { @MainActor in
                    await Task.yield()
                    isSymbolFieldFocused = true
                }
            }
            .onChange(of: model.symbolErrorMessage) { _, error in
                guard error != nil, isAddingSymbol else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo("add-symbol-input", anchor: .bottom)
                }
            }
        }
    }

    private func quoteRow(_ quote: QuoteSnapshot, expanded: Bool) -> some View {
        HStack(spacing: expanded ? 10 : 5) {
            Circle()
                .fill(quoteStatusColor(quote))
                .frame(width: expanded ? 8 : 6, height: expanded ? 8 : 6)

            Text(quote.instrument.symbol)
                .font(
                    expanded
                        ? .system(.body, design: .rounded, weight: .semibold)
                        : .system(size: 12, weight: .semibold, design: .rounded)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .layoutPriority(1)
                .foregroundStyle(modulePrimaryColor(active: expanded))

            Spacer(minLength: expanded ? 8 : 3)

            VStack(alignment: .trailing, spacing: 2) {
                Text(price(quote.displayPrice))
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
                    .foregroundStyle(
                        quote.stale
                            ? moduleSecondaryColor(active: expanded)
                            : modulePrimaryColor(active: expanded)
                    )

                if expanded {
                    Text(changeText(quote))
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(changeColor(quote))
                        .transition(
                            .move(edge: .trailing)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.94, anchor: .trailing))
                        )
                }
            }

            if expanded {
                Button { model.remove(conId: quote.instrument.conId) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tertiaryInterfaceColor)
                .accessibilityLabel("Remove \(quote.instrument.symbol)")
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, expanded ? 12 : 8)
        .frame(minHeight: 48)
        .openIBKRGlassCard(active: expanded)
        .contentShape(rowShape)
        .animation(.easeInOut(duration: 0.20), value: expanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quoteAccessibilityLabel(quote))
    }

    private var addSymbolButton: some View {
        Button {
            showAddSymbolInput()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 18)
                .background(secondaryInterfaceColor.opacity(0.18), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(secondaryInterfaceColor)
        .accessibilityLabel("Add U.S. Stock Symbol")
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    private var rowBackground: Color {
        rowBackground(active: isInterfaceActive)
    }

    private func rowBackground(active: Bool) -> Color {
        active ? Color.white.opacity(0.10) : Color.black.opacity(0.32)
    }

    private var emptyWatchlist: some View {
        VStack(spacing: 8) {
            Button {
                showAddSymbolInput()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(secondaryInterfaceColor.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(secondaryInterfaceColor)
            .accessibilityLabel("Add U.S. Stock Symbol")

            Text("Add symbols to view prices here")
                .font(.caption)
                .foregroundStyle(secondaryInterfaceColor)
        }
    }

    private var addSymbol: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Add a U.S. stock symbol, e.g. AAPL", text: $model.symbolInput)
                    .textFieldStyle(.plain)
                    .foregroundStyle(primaryInterfaceColor)
                    .focused($isSymbolFieldFocused)
                    .onSubmit {
                        guard !model.isSearchingSymbol else { return }
                        model.addSymbol()
                    }

                if model.isSearchingSymbol {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("Looking Up Stock Symbol")
                }

                Button("Add") { model.addSymbol() }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .foregroundStyle(secondaryInterfaceColor)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(
                        model.isSearchingSymbol
                            || model.symbolInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityHint("Add the stock symbol to the watchlist")
            }

            if let error = model.symbolErrorMessage {
                Text(error)
                    .font(.caption2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isInterfaceActive ? Color.red : secondaryInterfaceColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityLabel("Failed to add: \(error)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .animation(.easeInOut(duration: 0.20), value: model.symbolErrorMessage)
    }

    private func showAddSymbolInput() {
        model.beginSymbolEntry()
        withAnimation(.spring(duration: 0.30, bounce: 0.08)) {
            isAddingSymbol = true
        }
    }

    private func dismissAddSymbolInput() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isAddingSymbol = false
            isSymbolFieldFocused = false
            model.cancelSymbolEntry()
        }
    }

    private func setWatchlistExpanded(_ expanded: Bool) {
        revealGeneration += 1
        let generation = revealGeneration

        if expanded {
            revealedQuoteCount = 0
            withTransaction(Transaction(animation: nil)) {
                isWatchlistExpanded = true
            }

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(55))
                for index in model.snapshot.quotes.indices {
                    guard generation == revealGeneration, isWatchlistExpanded else { return }
                    revealedQuoteCount = index + 1
                    try? await Task.sleep(for: .milliseconds(65))
                }
            }
        } else {
            quoteHoverGeneration += 1
            quoteHoverTarget = nil
            activeQuoteID = nil

            Task { @MainActor in
                for index in model.snapshot.quotes.indices.reversed() {
                    guard generation == revealGeneration, isWatchlistExpanded else { return }
                    revealedQuoteCount = index
                    try? await Task.sleep(for: .milliseconds(55))
                }

                guard generation == revealGeneration, isWatchlistExpanded else { return }
                // The final row still needs to finish its 260ms composite
                // mask retraction. The loop has already waited 55ms after
                // hiding it; this buffer ensures the container is only
                // removed after the mask has fully closed.
                try? await Task.sleep(for: .milliseconds(280))
                guard generation == revealGeneration, isWatchlistExpanded else { return }

                withTransaction(Transaction(animation: nil)) {
                    isWatchlistExpanded = false
                }
            }
        }
    }

    private var contractCandidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Select a Contract")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryInterfaceColor)
                Spacer()
                Button("Cancel") { model.cancelCandidateSelection() }
                    .buttonStyle(.plain)
                    .foregroundStyle(secondaryInterfaceColor)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)

            if model.isSearchingSymbol {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Adding Selected Contract")
            } else if let error = model.symbolErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(isInterfaceActive ? Color.red : secondaryInterfaceColor)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Failed to add: \(error)")
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.contractCandidates) { instrument in
                        Button {
                            model.selectCandidate(instrument)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(instrument.localSymbol ?? instrument.symbol)
                                        .fontWeight(.medium)
                                        .foregroundStyle(primaryInterfaceColor)
                                    Text(instrument.primaryExchange ?? instrument.exchange)
                                        .font(.caption2)
                                        .foregroundStyle(secondaryInterfaceColor)
                                }
                                Spacer()
                                Text("#\(instrument.conId)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(tertiaryInterfaceColor)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isSearchingSymbol)
                        .accessibilityLabel(
                            "Select \(instrument.localSymbol ?? instrument.symbol), \(instrument.primaryExchange ?? instrument.exchange)"
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func pnlMetric(_ title: String, _ value: DecimalString?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(secondaryInterfaceColor)
            Text(money(value, currency: model.snapshot.account.currency))
                .font(.system(.caption, design: .rounded, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(pnlColor(value))
        }
    }

    private func quoteStatusColor(_ quote: QuoteSnapshot) -> Color {
        guard
            model.snapshot.connection.state == .connected,
            let change = quote.priceChange?.absolute
        else { return Color.gray.opacity(0.78) }
        if change > 0 { return .green }
        if change < 0 { return .red }
        return Color.gray.opacity(0.78)
    }

    private func money(_ value: DecimalString?, currency: String?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        let currencyCode = currency ?? "USD"
        formatter.currencyCode = currencyCode
        if currencyCode == "USD" {
            formatter.currencySymbol = "$"
        }
        return formatter.string(from: NSDecimalNumber(decimal: value.value)) ?? "—"
    }

    private func dailyPnLAmountText(_ value: DecimalString?, currency: String?) -> String {
        guard let value else { return "—" }
        let magnitude = value.value < 0 ? -value.value : value.value
        let unsignedAmount = money(DecimalString(magnitude), currency: currency)
        let amount: String
        if value.value > 0 {
            amount = "+\(unsignedAmount)"
        } else if value.value < 0 {
            amount = "-\(unsignedAmount)"
        } else {
            amount = unsignedAmount
        }

        return amount
    }

    private func dailyPnLArrow(_ value: DecimalString?) -> String? {
        guard let value else { return nil }
        if value.value > 0 { return "↑" }
        if value.value < 0 { return "↓" }
        return nil
    }

    private func dailyPnLPercentText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(decimal(value, places: 2))%"
    }

    private func price(_ value: DecimalString?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
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

    private func changeColor(_ quote: QuoteSnapshot) -> Color {
        guard isInterfaceActive else { return secondaryInterfaceColor }
        guard let change = quote.priceChange?.absolute else { return secondaryInterfaceColor }
        if change > 0 { return .green }
        if change < 0 { return .red }
        return .secondary
    }

    private func quoteAccessibilityLabel(_ quote: QuoteSnapshot) -> String {
        let stale = quote.stale ? ", data is stale" : ""
        return "\(quote.instrument.symbol), price \(price(quote.displayPrice)), \(changeText(quote))\(stale)"
    }

    private func pnlColor(_ value: DecimalString?) -> Color {
        guard isInterfaceActive else { return primaryInterfaceColor }
        guard let value else { return primaryInterfaceColor }
        return value.value >= 0 ? .green : .red
    }

    private func modulePnLValueColor(_ value: DecimalString?, active: Bool) -> Color {
        guard active else { return Color.white.opacity(0.82) }
        return pnlDirectionColor(value)
    }

    private func pnlDirectionColor(_ value: DecimalString?) -> Color {
        guard let value else { return primaryInterfaceColor }
        if value.value > 0 { return .green }
        if value.value < 0 { return .red }
        return primaryInterfaceColor
    }
}

private extension View {
    @ViewBuilder
    func openIBKRGlassCard(
        active: Bool,
        cornerRadius: CGFloat = DashboardLayout.cardCornerRadius
    ) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )
        background {
            if active {
                shape.fill(.ultraThinMaterial)
            } else {
                // Keep the inactive glass appearance fully inside the card's
                // rounded bounds. Liquid Glass `.regular` and SwiftUI shadow
                // both draw ambient pixels outside that boundary.
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.stroke(.white.opacity(0.14), lineWidth: 0.8)
                    }
                    .saturation(0)
                    .opacity(0.50)
                    .overlay {
                        shape
                            .fill(Color.black.opacity(0.32))
                            .overlay {
                                shape.stroke(
                                    Color.white.opacity(0.18),
                                    lineWidth: 0.6
                                )
                            }
                    }
            }
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct PointerTrackingView: NSViewRepresentable {
    let onLocationChanged: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onLocationChanged = onLocationChanged
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onLocationChanged = onLocationChanged
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopTracking()
    }

    final class TrackingView: NSView {
        var onLocationChanged: ((CGPoint?) -> Void)?
        private var timer: Timer?
        private var wasInside = false

        override var isFlipped: Bool { true }

        // This view observes the pointer but never participates in hit
        // testing, so buttons, dragging, and click-through behavior remain
        // owned by the visible SwiftUI controls beneath it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? stopTracking() : startTracking()
        }

        func stopTracking() {
            timer?.invalidate()
            timer = nil
            if wasInside {
                wasInside = false
                onLocationChanged?(nil)
            }
        }

        private func startTracking() {
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
                if wasInside {
                    wasInside = false
                    onLocationChanged?(nil)
                }
                return
            }

            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let location = convert(windowPoint, from: nil)
            if bounds.contains(location) {
                wasInside = true
                onLocationChanged?(CGPoint(x: location.x, y: location.y))
            } else if wasInside {
                wasInside = false
                onLocationChanged?(nil)
            }
        }

        deinit {
            timer?.invalidate()
        }
    }
}

#if DEBUG
private struct DashboardPreviewScene: View {
    @StateObject private var model = AppModel.dashboardPreview
    let initiallyExpanded: Bool
    let interfaceActive: Bool
    let watchlistExpanded: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.18, blue: 0.28),
                    Color(red: 0.34, green: 0.43, blue: 0.38),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.cyan.opacity(0.22))
                .frame(width: 230, height: 230)
                .blur(radius: 28)
                .offset(x: 150, y: -170)

            DashboardView(
                model: model,
                initiallyExpanded: initiallyExpanded,
                interfaceActiveOverride: interfaceActive,
                watchlistInitiallyExpanded: watchlistExpanded
            )
        }
        .frame(
            width: 320,
            height: watchlistExpanded ? 360 : 100
        )
        .clipped()
    }
}

#Preview("Inactive · Watchlist Collapsed") {
    DashboardPreviewScene(
        initiallyExpanded: false,
        interfaceActive: false,
        watchlistExpanded: false
    )
}

#Preview("Hover Active · Watchlist Expanded") {
    DashboardPreviewScene(
        initiallyExpanded: true,
        interfaceActive: true,
        watchlistExpanded: true
    )
}

#endif
