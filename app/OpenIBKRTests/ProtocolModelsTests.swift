import XCTest
@testable import OpenIBKR

final class ProtocolModelsTests: XCTestCase {
    @MainActor
    func testFloatingPanelAdaptsToContentAndDisablesBackgroundDragging() throws {
        let controller = FloatingPanelController(model: AppModel())
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    @MainActor
    func testFloatingPanelExpansionKeepsTopLeftAnchorFixed() {
        let original = NSRect(x: 120, y: 300, width: 388, height: 100)
        let expanded = FloatingPanelController.frameKeepingTopLeft(
            original,
            targetSize: NSSize(width: 267, height: 396)
        )

        XCTAssertEqual(expanded.minX, original.minX)
        XCTAssertEqual(expanded.maxY, original.maxY)
        XCTAssertEqual(expanded.width, 267)
        XCTAssertEqual(expanded.height, 396)
    }

    func testPnLAndWatchlistUseIdenticalWidths() {
        XCTAssertEqual(
            DashboardLayout.moduleWidth(expanded: false),
            DashboardLayout.collapsedPnLWidth
        )
        XCTAssertEqual(
            DashboardLayout.moduleWidth(expanded: true),
            DashboardLayout.expandedModuleWidth
        )
    }

    func testDailyPnLPercentageCannotHitFirstQuote() {
        let percentagePoint = CGPoint(x: 24, y: 42)

        XCTAssertTrue(
            DashboardLayout.pnlHoverFrame(expanded: false).contains(percentagePoint)
        )
        XCTAssertFalse(
            DashboardLayout.quoteHoverFrame(index: 0, expanded: false)
                .contains(percentagePoint)
        )
    }

    func testModuleAndQuoteGapsDoNotHitCards() {
        let moduleGap = CGPoint(x: 24, y: DashboardLayout.pnlHeight + 5)
        let firstQuoteGap = CGPoint(
            x: 24,
            y: DashboardLayout.pnlHeight + DashboardLayout.moduleSpacing + 10 + 51
        )

        XCTAssertFalse(DashboardLayout.pnlHoverFrame(expanded: false).contains(moduleGap))
        XCTAssertFalse(
            DashboardLayout.quoteHoverFrame(index: 0, expanded: false).contains(moduleGap)
        )
        XCTAssertFalse(
            DashboardLayout.quoteHoverFrame(index: 0, expanded: false)
                .contains(firstQuoteGap)
        )
        XCTAssertFalse(
            DashboardLayout.quoteHoverFrame(index: 1, expanded: false)
                .contains(firstQuoteGap)
        )
    }

    func testFinalQuoteHoverTargetIncludesAddButtonAccessory() {
        let finalRowAccessoryPoint = CGPoint(
            x: DashboardLayout.expandedModuleWidth + 12,
            y: DashboardLayout.pnlHeight + DashboardLayout.moduleSpacing + 10 + 24
        )

        XCTAssertFalse(
            DashboardLayout.quoteHoverFrame(index: 0, expanded: true)
                .contains(finalRowAccessoryPoint)
        )
        XCTAssertTrue(
            DashboardLayout.quoteHoverFrame(
                index: 0,
                expanded: true,
                includesAccessory: true
            )
            .contains(finalRowAccessoryPoint)
        )
    }

    func testAddSymbolSpaceDoesNotShrinkEmptyWatchlist() {
        let idleHeight = DashboardLayout.watchlistHeight(
            quoteCount: 0,
            reservesAddSymbolSpace: false
        )
        let inputHeight = DashboardLayout.watchlistHeight(
            quoteCount: 0,
            reservesAddSymbolSpace: true
        )

        XCTAssertEqual(idleHeight, DashboardLayout.emptyWatchlistHeight)
        XCTAssertEqual(inputHeight, idleHeight)
    }

    func testAddSymbolSpaceIsReservedBeforeInputTransition() {
        let idleHeight = DashboardLayout.watchlistHeight(
            quoteCount: 2,
            reservesAddSymbolSpace: false
        )
        let reservedHeight = DashboardLayout.watchlistHeight(
            quoteCount: 2,
            reservesAddSymbolSpace: true
        )

        XCTAssertEqual(reservedHeight - idleHeight, 51)
    }

    func testInputReservationDoesNotResizeFourQuoteViewport() {
        let idleHeight = DashboardLayout.quoteViewportHeight(
            quoteCount: 4,
            reservesAddSymbolSpace: false
        )
        let reservedHeight = DashboardLayout.quoteViewportHeight(
            quoteCount: 4,
            reservesAddSymbolSpace: true
        )

        XCTAssertEqual(idleHeight, DashboardLayout.quoteRowsContentHeight(count: 4))
        XCTAssertEqual(reservedHeight, idleHeight)
    }

    func testQuoteRemovalKeepsPreviousLayoutCountUntilAnimationFinishes() {
        let layoutCount = DashboardLayout.quoteCountForLayout(
            current: 3,
            reserved: 4
        )

        XCTAssertEqual(layoutCount, 4)
        XCTAssertEqual(
            DashboardLayout.watchlistHeight(
                quoteCount: layoutCount,
                reservesAddSymbolSpace: false
            ),
            DashboardLayout.watchlistHeight(
                quoteCount: 4,
                reservesAddSymbolSpace: false
            )
        )
    }

    func testQuoteTrendTracksDisplayedPriceChangesWithinCurrentMinute() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = QuoteTrendHistory.recording(price: 100, at: start, in: [])
        let sameMinute = QuoteTrendHistory.recording(
            price: 101,
            at: start.addingTimeInterval(30),
            in: first
        )
        let appended = QuoteTrendHistory.recording(
            price: 102,
            at: start.addingTimeInterval(60),
            in: sameMinute
        )

        XCTAssertEqual(sameMinute.map(\.price.value), [Decimal(101)])
        XCTAssertEqual(appended.map(\.price.value), [Decimal(101), Decimal(102)])
        XCTAssertEqual(QuoteTrendDirection.from(appended), .rising)
    }

    func testQuoteTrendDoesNotCreateRepeatedPointsForUnchangedDisplayedPrice() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = QuoteTrendHistory.recording(price: 100, at: start, in: [])
        let unchanged = QuoteTrendHistory.recording(
            price: 100,
            at: start.addingTimeInterval(600),
            in: first
        )

        XCTAssertEqual(unchanged, first)
    }

    func testQuoteTrendDropsSamplesOlderThanTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        let points = [
            QuoteTrendPoint(
                sampledAt: now.addingTimeInterval(-QuoteTrendHistory.retentionInterval - 1),
                price: DecimalString(99)
            ),
            QuoteTrendPoint(
                sampledAt: now.addingTimeInterval(-60),
                price: DecimalString(100)
            ),
        ]

        let result = QuoteTrendHistory.recording(price: 98, at: now, in: points)

        XCTAssertEqual(result.map(\.price.value), [Decimal(100), Decimal(98)])
        XCTAssertEqual(QuoteTrendDirection.from(result), .falling)
    }

    func testHoverSessionUsesOneStableWidthAcrossModules() {
        let stableWidth = DashboardLayout.stableHoverWidth(
            watchlistExpanded: true,
            hasAccessory: true
        )

        XCTAssertEqual(
            stableWidth,
            DashboardLayout.expandedModuleWidth + DashboardLayout.watchlistAccessoryWidth
        )
        XCTAssertGreaterThan(stableWidth, DashboardLayout.expandedModuleWidth)
    }

    func testPnLDragSurfaceLeavesOnlyButtonAreaInteractive() {
        let collapsedDragWidth = DashboardLayout.moduleWidth(expanded: false)
            - DashboardLayout.pnlDragButtonExclusionWidth
        let expandedDragWidth = DashboardLayout.moduleWidth(expanded: true)
            - DashboardLayout.pnlDragButtonExclusionWidth

        XCTAssertGreaterThan(collapsedDragWidth, 0)
        XCTAssertGreaterThan(expandedDragWidth, collapsedDragWidth)
        XCTAssertLessThan(
            DashboardLayout.pnlDragButtonExclusionWidth,
            DashboardLayout.moduleWidth(expanded: false)
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
        XCTAssertEqual(MarketDataKind.overnightIndicative.displayName, "Overnight Indicative")
        XCTAssertNotEqual(MarketDataKind.realTime.displayName, MarketDataKind.delayed.displayName)
    }

    func testDecodesAlpacaOvernightStatusAndTrend() throws {
        let json = #"""
        {
          "protocol_version": 1,
          "sequence": 9,
          "generated_at": "2026-08-14T03:00:00Z",
          "connection": {
            "state": "connected",
            "changed_at": "2026-08-14T02:59:00Z",
            "last_error_code": null
          },
          "account": {"stale": true},
          "pnl": {"stale": true},
          "quotes": [{
            "instrument": {
              "con_id": 265598,
              "symbol": "AAPL",
              "sec_type": "STK",
              "exchange": "SMART",
              "currency": "USD",
              "primary_exchange": "NASDAQ",
              "local_symbol": "AAPL"
            },
            "bid": "100.10",
            "ask": "100.30",
            "last": "100.20",
            "close": "99.00",
            "market_data_kind": "overnight_indicative",
            "received_at": "2026-08-14T02:59:58Z",
            "stale": false,
            "trend": [{"sampled_at": "2026-08-14T02:59:00Z", "price": "100.20"}]
          }],
          "market_data": {
            "provider": "alpaca_overnight",
            "configured": true,
            "active": true,
            "last_update_at": "2026-08-14T02:59:58Z",
            "error": null
          }
        }
        """#

        let snapshot = try ProtocolCoding.decoder().decode(AppSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.currentMarketData.provider, "alpaca_overnight")
        XCTAssertTrue(snapshot.currentMarketData.active)
        XCTAssertEqual(snapshot.quotes.first?.marketDataKind, .overnightIndicative)
        XCTAssertEqual(snapshot.quotes.first?.trend?.first?.price.value, Decimal(string: "100.20"))
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
