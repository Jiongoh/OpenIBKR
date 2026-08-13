import XCTest
@testable import OpenIBKR

final class ProtocolModelsTests: XCTestCase {
    @MainActor
    func testFloatingPanelResizesHorizontallyButKeepsFixedHeight() throws {
        let controller = FloatingPanelController(model: AppModel())
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.hasShadow)

        let narrow = controller.windowWillResize(
            window,
            to: NSSize(width: DashboardLayout.minimumWidth - 80, height: 200)
        )
        let wide = controller.windowWillResize(
            window,
            to: NSSize(width: DashboardLayout.maximumWidth + 80, height: 900)
        )

        XCTAssertEqual(narrow.width, DashboardLayout.minimumWidth)
        XCTAssertEqual(wide.width, DashboardLayout.maximumWidth)
        XCTAssertEqual(narrow.height, wide.height)
        XCTAssertEqual(window.contentMinSize.height, DashboardLayout.collapsedContentHeight)
        XCTAssertEqual(window.contentMaxSize.height, DashboardLayout.contentHeight)
    }

    @MainActor
    func testFloatingPanelExpansionKeepsTopLeftAnchorFixed() {
        let original = NSRect(x: 120, y: 300, width: 388, height: 100)
        let expanded = FloatingPanelController.frameKeepingTopLeft(
            original,
            targetHeight: 396
        )

        XCTAssertEqual(expanded.minX, original.minX)
        XCTAssertEqual(expanded.maxY, original.maxY)
        XCTAssertEqual(expanded.width, original.width)
        XCTAssertEqual(expanded.height, 396)
    }

    func testPnLAndWatchlistUseIdenticalWidths() {
        let totalWidth: CGFloat = 364

        XCTAssertEqual(
            DashboardLayout.moduleWidth(totalWidth: totalWidth, expanded: false),
            DashboardLayout.collapsedPnLWidth
        )
        XCTAssertEqual(
            DashboardLayout.moduleWidth(totalWidth: totalWidth, expanded: true),
            (totalWidth - DashboardLayout.watchlistAccessoryWidth)
                * DashboardLayout.expandedPnLWidthRatio
        )
    }

    func testDecodesPythonSnapshotFixture() throws {
        let json = #"""
        {
          "protocol_version": 1,
          "sequence": 7,
          "generated_at": "2026-08-07T02:52:22.832576Z",
          "connection": {
            "state": "connected",
            "changed_at": "2026-08-07T02:52:20Z",
            "last_error_code": null
          },
          "account": {
            "account_masked": "*****TEST",
            "currency": "USD",
            "net_liquidation": "100000.25",
            "received_at": "2026-08-07T02:52:21Z",
            "stale": false
          },
          "pnl": {
            "daily": "12.34",
            "unrealized": "10.01",
            "realized": "2.33",
            "received_at": "2026-08-07T02:52:21.123456Z",
            "stale": false
          },
          "quotes": []
        }
        """#
        let snapshot = try ProtocolCoding.decoder().decode(AppSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.protocolVersion, 1)
        XCTAssertEqual(snapshot.sequence, 7)
        XCTAssertEqual(snapshot.connection.state, .connected)
        XCTAssertEqual(snapshot.account.accountMasked, "*****TEST")
        XCTAssertEqual(snapshot.pnl.daily?.value, Decimal(string: "12.34"))
    }

    func testMarketDataLabelsRemainExplicit() {
        XCTAssertEqual(MarketDataKind.realTime.displayName, "Real-Time")
        XCTAssertEqual(MarketDataKind.delayed.displayName, "Delayed")
        XCTAssertNotEqual(MarketDataKind.realTime.displayName, MarketDataKind.delayed.displayName)
    }

    func testQuoteFallsBackToCloseWhenLastPriceIsZero() {
        let quote = makeQuote(last: 0, close: 97.52)

        XCTAssertEqual(quote.displayPrice?.value, Decimal(string: "97.52"))
        XCTAssertNil(quote.priceChange)
    }

    func testQuoteCalculatesChangeOnlyFromPositivePrices() {
        let quote = makeQuote(last: 98.75, close: 97.52)

        XCTAssertEqual(quote.displayPrice?.value, Decimal(string: "98.75"))
        XCTAssertEqual(quote.priceChange?.absolute, Decimal(string: "1.23"))
    }

    func testStaleQuoteRetainsComputablePriceDirection() {
        var quote = makeQuote(last: 98.75, close: 97.52)
        quote.stale = true

        XCTAssertEqual(quote.priceChange?.absolute, Decimal(string: "1.23"))
        XCTAssertGreaterThan(quote.priceChange?.percent ?? 0, 0)
    }

    func testDailyPnLPercentUsesFreshNetLiquidation() {
        var snapshot = AppSnapshot.empty
        snapshot.account.netLiquidation = DecimalString(100_000)
        snapshot.account.stale = false
        snapshot.pnl.daily = DecimalString(125)
        snapshot.pnl.stale = false

        XCTAssertEqual(snapshot.dailyPnLPercent, Decimal(string: "0.125"))

        snapshot.account.stale = true
        XCTAssertNil(snapshot.dailyPnLPercent)
    }

    func testDailyPnLPercentRejectsNonPositiveNAV() {
        var snapshot = AppSnapshot.empty
        snapshot.account.netLiquidation = DecimalString(0)
        snapshot.account.stale = false
        snapshot.pnl.daily = DecimalString(125)
        snapshot.pnl.stale = false

        XCTAssertNil(snapshot.dailyPnLPercent)
    }

    func testRejectsUnknownMajorProtocolVersion() {
        XCTAssertNoThrow(try ProtocolCoding.requireSupported(1))
        XCTAssertThrowsError(try ProtocolCoding.requireSupported(2)) { error in
            guard case HelperClientError.incompatibleProtocol(2) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testSymbolEntryRejectsInvalidCharactersBeforeCallingHelper() {
        let model = AppModel()
        model.symbolInput = "AAPL;DROP"

        model.addSymbol()

        XCTAssertEqual(
            model.symbolErrorMessage,
            "Stock symbols may contain only letters, numbers, periods, or hyphens"
        )
        XCTAssertFalse(model.isSearchingSymbol)
    }

    func testHelperHTTPErrorMessagesAreUserFacing() {
        XCTAssertEqual(
            HelperClientError.http(503, "IB Gateway unavailable").errorDescription,
            "IB Gateway is unavailable. Make sure it is logged in and API access is enabled"
        )
        XCTAssertEqual(
            HelperClientError.http(504, "timed out").errorDescription,
            "The IB Gateway contract lookup timed out. Please try again"
        )
        XCTAssertEqual(
            HelperClientError.http(418, "Test error").errorDescription,
            "Test error"
        )
    }

    private func makeQuote(last: Decimal, close: Decimal) -> QuoteSnapshot {
        QuoteSnapshot(
            instrument: Instrument(
                conId: 270639,
                symbol: "TEST",
                secType: "STK",
                exchange: "SMART",
                currency: "USD",
                primaryExchange: "NASDAQ",
                localSymbol: "TEST"
            ),
            bid: nil,
            ask: nil,
            last: DecimalString(last),
            close: DecimalString(close),
            marketDataKind: .delayed,
            receivedAt: .now,
            stale: false
        )
    }
}
