import SwiftUI

enum DashboardLayout {
    static let defaultWidth: CGFloat = 388
    static let minimumWidth: CGFloat = 388
    static let maximumWidth: CGFloat = 928
    static let pnlHeight: CGFloat = 52
    static let watchlistHeight: CGFloat = 284
    static let moduleSpacing: CGFloat = 12
    static let collapsedContentHeight: CGFloat = shadowPadding * 2 + pnlHeight
    static let contentHeight: CGFloat = collapsedContentHeight + moduleSpacing + watchlistHeight
    static let shadowPadding: CGFloat = 24
    static let watchlistAccessoryWidth: CGFloat = 24
    static let cardCornerRadius: CGFloat = 10
    static let collapsedPnLWidth: CGFloat = 117
    static let expandedPnLWidthRatio: CGFloat = 2 / 3

    static func moduleWidth(totalWidth: CGFloat, expanded: Bool) -> CGFloat {
        let availableWidth = max(0, totalWidth - watchlistAccessoryWidth)
        return expanded
            ? availableWidth * expandedPnLWidthRatio
            : min(collapsedPnLWidth, availableWidth)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appearsActive) private var appearsActive
    @State private var isPnLExpanded: Bool
    @State private var isPointerInside = false
    @State private var isWatchlistExpanded: Bool
    @State private var isAddingSymbol: Bool
    @State private var revealedQuoteCount: Int
    @State private var revealGeneration = 0
    @State private var activeQuoteID: Int?
    @FocusState private var isSymbolFieldFocused: Bool
    private let interfaceActiveOverride: Bool?
    private let onWatchlistExpansionChanged: ((Bool) -> Void)?

    init(
        model: AppModel,
        initiallyExpanded: Bool = false,
        interfaceActiveOverride: Bool? = nil,
        watchlistInitiallyExpanded: Bool = true,
        onWatchlistExpansionChanged: ((Bool) -> Void)? = nil
    ) {
        self.model = model
        self.interfaceActiveOverride = interfaceActiveOverride
        self.onWatchlistExpansionChanged = onWatchlistExpansionChanged
        _isPnLExpanded = State(initialValue: initiallyExpanded)
        _isWatchlistExpanded = State(initialValue: watchlistInitiallyExpanded)
        _isAddingSymbol = State(initialValue: false)
        _revealedQuoteCount = State(initialValue: watchlistInitiallyExpanded ? .max : 0)
        _activeQuoteID = State(initialValue: nil)
    }

    var body: some View {
        modules
            .padding(.leading, DashboardLayout.shadowPadding)
            .padding(.vertical, DashboardLayout.shadowPadding)
            .frame(
                minWidth: DashboardLayout.minimumWidth,
                maxWidth: .infinity,
                minHeight: currentContentHeight,
                maxHeight: currentContentHeight,
                alignment: .topLeading
            )
            .contentShape(Rectangle())
            .background(Color.clear)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.22)) {
                    isPointerInside = hovering
                }
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

    private var currentContentHeight: CGFloat {
        isWatchlistExpanded
            ? DashboardLayout.contentHeight
            : DashboardLayout.collapsedContentHeight
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
            GeometryReader { geometry in
                pnlModule
                    .frame(
                        width: DashboardLayout.moduleWidth(
                            totalWidth: geometry.size.width,
                            expanded: isPnLExpanded
                        ),
                        height: geometry.size.height
                    )
                    .openIBKRGlassCard(active: isPnLExpanded)
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: DashboardLayout.cardCornerRadius,
                            style: .continuous
                        )
                    )
                    .onHover { hovering in
                        withAnimation(.spring(duration: 0.42, bounce: 0.12)) {
                            isPnLExpanded = hovering
                        }
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: DashboardLayout.pnlHeight)

            if isWatchlistExpanded {
                watchlistModule
                    .frame(maxWidth: .infinity)
                    .frame(height: DashboardLayout.watchlistHeight)
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
                HStack(alignment: .center, spacing: 12) {
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
                LazyVStack(spacing: 7) {
                    ForEach(Array(model.snapshot.quotes.enumerated()), id: \.element.id) { index, quote in
                        GeometryReader { geometry in
                            let expanded = activeQuoteID == quote.id
                            let quoteWidth = DashboardLayout.moduleWidth(
                                totalWidth: geometry.size.width,
                                expanded: expanded
                            )

                            HStack(spacing: 6) {
                                quoteRow(quote, expanded: expanded)
                                    .frame(width: quoteWidth)
                                    .contentShape(rowShape)
                                    .onHover { hovering in
                                        withAnimation(.spring(duration: 0.38, bounce: 0.10)) {
                                            activeQuoteID = hovering ? quote.id : nil
                                        }
                                    }

                                Group {
                                    if index == model.snapshot.quotes.count - 1, !isAddingSymbol {
                                        addSymbolButton
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: 18, height: 24)

                                Spacer(minLength: 0)
                            }
                        }
                        .frame(height: 48)
                        .opacity(index < revealedQuoteCount ? 1 : 0)
                        .offset(x: index < revealedQuoteCount ? 0 : -22)
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
                .frame(maxWidth: .infinity)
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
            onWatchlistExpansionChanged?(true)
            withTransaction(Transaction(animation: nil)) {
                isWatchlistExpanded = true
            }

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(55))
                for index in model.snapshot.quotes.indices {
                    guard generation == revealGeneration, isWatchlistExpanded else { return }
                    withAnimation(.smooth(duration: 0.28)) {
                        revealedQuoteCount = index + 1
                    }
                    try? await Task.sleep(for: .milliseconds(65))
                }
            }
        } else {
            activeQuoteID = nil

            Task { @MainActor in
                for index in model.snapshot.quotes.indices.reversed() {
                    guard generation == revealGeneration, isWatchlistExpanded else { return }
                    withAnimation(.smooth(duration: 0.24)) {
                        revealedQuoteCount = index
                    }
                    try? await Task.sleep(for: .milliseconds(55))
                }

                guard generation == revealGeneration, isWatchlistExpanded else { return }
                try? await Task.sleep(for: .milliseconds(190))
                guard generation == revealGeneration, isWatchlistExpanded else { return }

                withTransaction(Transaction(animation: nil)) {
                    isWatchlistExpanded = false
                }
                onWatchlistExpansionChanged?(false)
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
                .font(.caption2)
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
        if #available(macOS 26.0, *) {
            background {
                shape
                    .fill(.clear)
                    .glassEffect(.regular, in: shape)
                    .saturation(active ? 1 : 0)
                    .opacity(active ? 1 : 0.50)
                    .overlay {
                        shape
                            .fill(Color.black.opacity(active ? 0 : 0.32))
                            .overlay {
                                shape.stroke(
                                    Color.white.opacity(active ? 0 : 0.18),
                                    lineWidth: 0.6
                                )
                            }
                    }
                    .shadow(
                        color: .black.opacity(active ? 0.09 : 0.03),
                        radius: 10,
                        y: 3
                    )
            }
        } else {
            background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.stroke(.white.opacity(0.14), lineWidth: 0.8)
                    }
                    .saturation(active ? 1 : 0)
                    .opacity(active ? 1 : 0.50)
                    .overlay {
                        shape
                            .fill(Color.black.opacity(active ? 0 : 0.32))
                            .overlay {
                                shape.stroke(
                                    Color.white.opacity(active ? 0 : 0.18),
                                    lineWidth: 0.6
                                )
                            }
                    }
                    .shadow(
                        color: .black.opacity(active ? 0.09 : 0.03),
                        radius: 10,
                        y: 3
                    )
                }
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
            width: DashboardLayout.defaultWidth,
            height: watchlistExpanded
                ? DashboardLayout.contentHeight
                : DashboardLayout.collapsedContentHeight
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
