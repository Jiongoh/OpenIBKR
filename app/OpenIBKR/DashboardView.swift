import SwiftUI

enum DashboardLayout {
    static let defaultWidth: CGFloat = 388
    static let minimumWidth: CGFloat = 388
    static let maximumWidth: CGFloat = 928
    static let contentHeight: CGFloat = 476
    static let shadowPadding: CGFloat = 24
    static let cardCornerRadius: CGFloat = 22
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        modules
            .padding(DashboardLayout.shadowPadding)
            .frame(
                minWidth: DashboardLayout.minimumWidth,
                maxWidth: .infinity,
                minHeight: DashboardLayout.contentHeight,
                maxHeight: DashboardLayout.contentHeight
            )
            .background(Color.clear)
    }

    private var modules: some View {
        VStack(spacing: 12) {
            pnlModule
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .openIBKRGlassCard(emphasized: appearsActive)

            watchlistModule
                .frame(maxWidth: .infinity)
                .frame(height: 284)
                .openIBKRGlassCard(emphasized: appearsActive)
        }
        .animation(.easeOut(duration: 0.18), value: appearsActive)
    }

    private var pnlModule: some View {
        VStack(alignment: .leading, spacing: 13) {
            moduleHeader

            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当日盈亏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(money(model.snapshot.pnl.daily, currency: model.snapshot.account.currency))
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .foregroundStyle(pnlColor(model.snapshot.pnl.daily))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                pnlMetric("未实现", model.snapshot.pnl.unrealized)
                pnlMetric("已实现", model.snapshot.pnl.realized)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var moduleHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
                .shadow(color: connectionColor.opacity(0.65), radius: 4)

            Text(model.snapshot.account.accountMasked ?? "OpenIBKR")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.snapshot.pnl.stale {
                Label("已过期", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(model.snapshot.connection.state.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var watchlistModule: some View {
        VStack(spacing: 0) {
            HStack {
                Text("自选标的")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.snapshot.quotes.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
                Spacer()
                Text("价格 / 涨跌")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)

            Divider().opacity(0.45)

            Group {
                if !model.contractCandidates.isEmpty {
                    contractCandidates
                } else if model.snapshot.quotes.isEmpty {
                    emptyWatchlist
                } else {
                    quoteRows
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.45)
            addSymbol
                .padding(.horizontal, 12)
                .frame(height: 48)
        }
    }

    private var quoteRows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.snapshot.quotes.enumerated()), id: \.element.id) { index, quote in
                    quoteRow(quote)
                    if index < model.snapshot.quotes.count - 1 {
                        Divider()
                            .padding(.leading, 40)
                            .opacity(0.35)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func quoteRow(_ quote: QuoteSnapshot) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(quote.stale ? Color.secondary : quoteStatusColor(quote))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(quote.instrument.symbol)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                Text(quote.marketDataKind.displayName)
                    .font(.caption2)
                    .foregroundStyle(quote.marketDataKind == .realTime ? .green : .secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(price(quote.displayPrice))
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(quote.stale ? .secondary : .primary)
                Text(changeText(quote))
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(changeColor(quote))
            }

            Button { model.remove(conId: quote.instrument.conId) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("删除 \(quote.instrument.symbol)")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 53)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quoteAccessibilityLabel(quote))
    }

    private var emptyWatchlist: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("添加标的后在这里查看价格")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var addSymbol: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary)
            TextField("添加美股代码，例如 AAPL", text: $model.symbolInput)
                .textFieldStyle(.plain)
                .onSubmit { model.addSymbol() }

            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
                    .accessibilityLabel(error)
            }

            Button("添加") { model.addSymbol() }
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.symbolInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint("将股票代码添加到自选列表")
        }
    }

    private var contractCandidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("请选择合约")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("取消") { model.cancelCandidateSelection() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)

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
                                    Text(instrument.primaryExchange ?? instrument.exchange)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("#\(instrument.conId)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "选择 \(instrument.localSymbol ?? instrument.symbol)，\(instrument.primaryExchange ?? instrument.exchange)"
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
                .foregroundStyle(.secondary)
            Text(money(value, currency: model.snapshot.account.currency))
                .font(.system(.caption, design: .rounded, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundStyle(pnlColor(value))
        }
    }

    private var connectionColor: Color {
        switch model.snapshot.connection.state {
        case .connected: .green
        case .connecting, .recovering: .orange
        case .disconnected, .stopped: .secondary
        }
    }

    private func quoteStatusColor(_ quote: QuoteSnapshot) -> Color {
        quote.marketDataKind == .realTime ? .green : .cyan
    }

    private func money(_ value: DecimalString?, currency: String?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency ?? "USD"
        return formatter.string(from: NSDecimalNumber(decimal: value.value)) ?? "—"
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
        guard let change = quote.priceChange?.absolute else { return .secondary }
        if change > 0 { return .green }
        if change < 0 { return .red }
        return .secondary
    }

    private func quoteAccessibilityLabel(_ quote: QuoteSnapshot) -> String {
        let stale = quote.stale ? "，数据已过期" : ""
        return "\(quote.instrument.symbol)，价格 \(price(quote.displayPrice))，\(changeText(quote))，\(quote.marketDataKind.displayName)行情\(stale)"
    }

    private func pnlColor(_ value: DecimalString?) -> Color {
        guard let value else { return .primary }
        return value.value >= 0 ? .green : .red
    }
}

private extension View {
    @ViewBuilder
    func openIBKRGlassCard(emphasized: Bool) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: DashboardLayout.cardCornerRadius,
            style: .continuous
        )
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
                .shadow(
                    color: .black.opacity(emphasized ? 0.09 : 0),
                    radius: 10,
                    y: 3
                )
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.14), lineWidth: 0.8)
                }
                .shadow(
                    color: .black.opacity(emphasized ? 0.09 : 0),
                    radius: 10,
                    y: 3
                )
        }
    }
}
