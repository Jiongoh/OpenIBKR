import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            header
            if !model.isCollapsed {
                pnlCard
                watchlist
                addSymbol
                if !model.contractCandidates.isEmpty {
                    contractCandidates
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(model.snapshot.connection.state == .connected ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(model.snapshot.account.accountMasked ?? "OpenIBKR")
                .font(.headline)
            Spacer()
            Text(model.snapshot.connection.state.displayName)
                .font(.caption).foregroundStyle(.secondary)
            Button { model.isCollapsed.toggle() } label: {
                Image(systemName: model.isCollapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: [.command])
            .accessibilityLabel(model.isCollapsed ? "展开悬浮窗" : "折叠悬浮窗")
        }
    }

    private var pnlCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当日盈亏").font(.caption).foregroundStyle(.secondary)
            Text(money(model.snapshot.pnl.daily, currency: model.snapshot.account.currency))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(pnlColor(model.snapshot.pnl.daily))
            HStack {
                metric("未实现", model.snapshot.pnl.unrealized)
                Spacer()
                metric("已实现", model.snapshot.pnl.realized)
            }
            if model.snapshot.pnl.stale {
                Label("数据已过期", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var watchlist: some View {
        VStack(spacing: 0) {
            ForEach(model.snapshot.quotes) { quote in
                HStack {
                    VStack(alignment: .leading) {
                        Text(quote.instrument.symbol).fontWeight(.medium)
                        Text(quote.marketDataKind.displayName)
                            .font(.caption2)
                            .foregroundStyle(quote.marketDataKind == .realTime ? .green : .secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(price(quote.last ?? quote.close))
                            .monospacedDigit()
                            .foregroundStyle(quote.stale ? .secondary : .primary)
                        Text(changeText(quote))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(changeColor(quote))
                    }
                    Button { model.remove(conId: quote.instrument.conId) } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("删除 \(quote.instrument.symbol)")
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(quoteAccessibilityLabel(quote))
                Divider()
            }
        }
    }

    private var addSymbol: some View {
        HStack {
            TextField("美股代码，例如 AAPL", text: $model.symbolInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addSymbol() }
            Button("添加") { model.addSymbol() }
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityHint("将股票代码添加到自选列表")
        }
    }

    private var contractCandidates: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("请选择合约").font(.caption).fontWeight(.semibold)
                Spacer()
                Button("取消") { model.cancelCandidateSelection() }
                    .buttonStyle(.plain)
            }
            ForEach(model.contractCandidates) { instrument in
                Button {
                    model.selectCandidate(instrument)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(instrument.localSymbol ?? instrument.symbol)
                            Text(instrument.primaryExchange ?? instrument.exchange)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("#\(instrument.conId)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择 \(instrument.localSymbol ?? instrument.symbol)，\(instrument.primaryExchange ?? instrument.exchange)")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ title: String, _ value: DecimalString?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(money(value, currency: model.snapshot.account.currency)).font(.caption).monospacedDigit()
        }
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
        return NSDecimalNumber(decimal: value.value).stringValue
    }

    private func changeText(_ quote: QuoteSnapshot) -> String {
        guard
            let last = quote.last?.value,
            let close = quote.close?.value,
            close != 0
        else { return "—" }
        let change = last - close
        let percent = change / close * 100
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
        guard let last = quote.last?.value, let close = quote.close?.value else { return .secondary }
        if last > close { return .green }
        if last < close { return .red }
        return .secondary
    }

    private func quoteAccessibilityLabel(_ quote: QuoteSnapshot) -> String {
        let stale = quote.stale ? "，数据已过期" : ""
        return "\(quote.instrument.symbol)，价格 \(price(quote.last ?? quote.close))，\(changeText(quote))，\(quote.marketDataKind.displayName)行情\(stale)"
    }

    private func pnlColor(_ value: DecimalString?) -> Color {
        guard let value else { return .primary }
        return value.value >= 0 ? .green : .red
    }
}
