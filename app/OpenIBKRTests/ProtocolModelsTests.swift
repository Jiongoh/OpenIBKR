import XCTest
@testable import OpenIBKR

final class ProtocolModelsTests: XCTestCase {
    func testAlpacaCredentialsUseTeamIDSignedV3KeychainService() {
        XCTAssertEqual(
            AlpacaCredentialsStore.service,
            "com.openibkr.alpaca.marketdata.v3"
        )
    }

    func testCloudflareCredentialsUseDedicatedTeamIDSignedKeychainService() {
        XCTAssertEqual(
            CloudflareCredentialsStore.service,
            "com.openibkr.cloudflare.wealth.v1"
        )
    }

    @MainActor
    func testFloatingPanelAdaptsToContentAndDisablesBackgroundDragging() throws {
        let controller = FloatingPanelController(model: AppModel())
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.isMovable)
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

    @MainActor
    func testFloatingPanelExpansionKeepsTopCenterAnchorFixed() {
        let original = NSRect(x: 120, y: 300, width: 548, height: 34)
        let expanded = FloatingPanelController.frameKeepingTopCenter(
            original,
            targetSize: NSSize(width: 548, height: 162)
        )

        XCTAssertEqual(expanded.midX, original.midX)
        XCTAssertEqual(expanded.maxY, original.maxY)
        XCTAssertEqual(expanded.width, 548)
        XCTAssertEqual(expanded.height, 162)
    }

    @MainActor
    func testCollapsedPanelFrameStaysFullyInsideTopOfScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)
        let targetSize = NSSize(width: 548, height: 34)
        let frame = FloatingPanelController.frameAtTopCenter(
            of: screen,
            targetSize: targetSize
        )

        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertTrue(screen.contains(frame))
    }

    func testDynamicIslandKeepsDrawerWidthConstantAcrossStates() {
        XCTAssertEqual(DashboardLayout.collapsedIslandSize, CGSize(width: 520, height: 20))
        XCTAssertEqual(DashboardLayout.expandedIslandSize, CGSize(width: 520, height: 148))
        XCTAssertEqual(
            DashboardLayout.collapsedIslandSize.width,
            DashboardLayout.expandedIslandSize.width
        )
        XCTAssertLessThan(
            DashboardLayout.collapsedIslandSize.height,
            DashboardLayout.expandedIslandSize.height
        )
    }

    func testPointerTrackingUsesVisibleDrawerAndIncludesScreenTopEdge() {
        let compactWindow = CGRect(x: 120, y: 1016, width: 548, height: 34)
        let trackingRect = DashboardLayout.pointerTrackingRect(
            windowFrame: compactWindow,
            expanded: false
        )

        XCTAssertEqual(trackingRect.width, 520)
        XCTAssertEqual(trackingRect.height, DashboardLayout.drawerLipDepth)
        XCTAssertEqual(trackingRect.maxY, compactWindow.maxY)
        XCTAssertTrue(
            DashboardLayout.pointerIsInside(
                CGPoint(x: trackingRect.midX, y: trackingRect.maxY),
                trackingRect: trackingRect
            )
        )
        XCTAssertFalse(
            DashboardLayout.pointerIsInside(
                CGPoint(x: trackingRect.midX, y: trackingRect.minY - 1),
                trackingRect: trackingRect
            )
        )
        XCTAssertFalse(
            DashboardLayout.pointerIsInside(
                CGPoint(x: trackingRect.minX - 1, y: trackingRect.midY),
                trackingRect: trackingRect
            )
        )
    }

    func testWatchlistSelectionWrapsInBothDirectionsAndHandlesEmptyLists() {
        XCTAssertEqual(
            IslandWatchlistSelection.wrappedIndex(current: 4, offset: 1, count: 5),
            0
        )
        XCTAssertEqual(
            IslandWatchlistSelection.wrappedIndex(current: 0, offset: -1, count: 5),
            4
        )
        XCTAssertNil(IslandWatchlistSelection.wrappedIndex(current: 0, offset: 1, count: 0))
    }

    func testWatchlistIndicatorShowsFiveItemsAndTracksSelection() {
        XCTAssertEqual(
            IslandWatchlistSelection.visibleIndicatorRange(selected: 0, count: 8),
            0..<5
        )
        XCTAssertEqual(
            IslandWatchlistSelection.visibleIndicatorRange(selected: 3, count: 8),
            1..<6
        )
        XCTAssertEqual(
            IslandWatchlistSelection.visibleIndicatorRange(selected: 7, count: 8),
            3..<8
        )
    }

    func testWatchlistIndicatorUsesActualCountBelowFiveAndHandlesEmptyLists() {
        XCTAssertEqual(
            IslandWatchlistSelection.visibleIndicatorRange(selected: 1, count: 3),
            0..<3
        )
        XCTAssertEqual(
            IslandWatchlistSelection.visibleIndicatorRange(selected: 0, count: 0),
            0..<0
        )
    }

    func testPositionSlotSelectionWrapsForContinuousScrolling() {
        XCTAssertEqual(PositionSlotSelection.wrappedIndex(current: 2, offset: 1, count: 3), 0)
        XCTAssertEqual(PositionSlotSelection.wrappedIndex(current: 0, offset: -1, count: 3), 2)
        XCTAssertNil(PositionSlotSelection.wrappedIndex(current: 0, offset: 1, count: 0))
    }

    func testPositionSlotSelectionFindsLineNearestPointer() {
        XCTAssertEqual(
            PositionSlotSelection.nearestIndex(
                values: [90, 100, 110],
                minimum: 80,
                maximum: 120,
                height: 100,
                pointerY: 27
            ),
            2
        )
        XCTAssertEqual(
            PositionSlotSelection.nearestIndex(
                values: [90, 100, 110],
                minimum: 80,
                maximum: 120,
                height: 100,
                pointerY: 76
            ),
            0
        )
    }

    func testPositionChartHoverSelectsPriceCurveNearItsInterpolatedPath() {
        XCTAssertEqual(
            PositionChartHoverSelection.target(
                trendValues: [90, 110],
                slotValues: [100],
                minimum: 80,
                maximum: 120,
                size: CGSize(width: 200, height: 100),
                pointer: CGPoint(x: 160, y: 30)
            ),
            .trend(1)
        )
    }

    func testPositionChartHoverKeepsSlotSelectionWhenSlotLineIsCloser() {
        XCTAssertEqual(
            PositionChartHoverSelection.target(
                trendValues: [90, 110],
                slotValues: [100],
                minimum: 80,
                maximum: 120,
                size: CGSize(width: 200, height: 100),
                pointer: CGPoint(x: 160, y: 49)
            ),
            .slot(0)
        )
    }

    func testScrollGestureGateSwitchesOnceAndIgnoresMomentum() {
        var gate = IslandScrollGestureGate(threshold: 20, discreteGestureGap: 0.24)

        XCTAssertNil(
            gate.consume(
                IslandScrollSample(
                    deltaY: -8,
                    phase: .began,
                    momentumPhase: [],
                    timestamp: 1
                )
            )
        )
        XCTAssertEqual(
            gate.consume(
                IslandScrollSample(
                    deltaY: -14,
                    phase: .changed,
                    momentumPhase: [],
                    timestamp: 1.02
                )
            ),
            1
        )
        XCTAssertNil(
            gate.consume(
                IslandScrollSample(
                    deltaY: -40,
                    phase: .changed,
                    momentumPhase: [],
                    timestamp: 1.04
                )
            )
        )
        XCTAssertNil(
            gate.consume(
                IslandScrollSample(
                    deltaY: -40,
                    phase: [],
                    momentumPhase: .began,
                    timestamp: 1.06
                )
            )
        )

        _ = gate.consume(
            IslandScrollSample(
                deltaY: 0,
                phase: .ended,
                momentumPhase: [],
                timestamp: 1.08
            )
        )
        XCTAssertEqual(
            gate.consume(
                IslandScrollSample(
                    deltaY: 24,
                    phase: .began,
                    momentumPhase: [],
                    timestamp: 2
                )
            ),
            -1
        )
    }

    func testDefaultScrollGestureGateRespondsToLightScroll() {
        var gate = IslandScrollGestureGate()

        XCTAssertNil(
            gate.consume(
                IslandScrollSample(
                    deltaY: -6,
                    phase: .began,
                    momentumPhase: [],
                    timestamp: 1
                )
            )
        )
        XCTAssertEqual(
            gate.consume(
                IslandScrollSample(
                    deltaY: -8,
                    phase: .changed,
                    momentumPhase: [],
                    timestamp: 1.02
                )
            ),
            1
        )
    }

    func testScrollGestureGateRepeatsWithinOneContinuousGesture() {
        var gate = IslandScrollGestureGate()

        XCTAssertEqual(
            gate.consume(
                IslandScrollSample(
                    deltaY: -14,
                    phase: .began,
                    momentumPhase: [],
                    timestamp: 1
                )
            ),
            1
        )
        XCTAssertNil(
            gate.consume(
                IslandScrollSample(
                    deltaY: -14,
                    phase: .changed,
                    momentumPhase: [],
                    timestamp: 1.04
                )
            )
        )
        XCTAssertEqual(
            gate.consume(
                IslandScrollSample(
                    deltaY: -1,
                    phase: .changed,
                    momentumPhase: [],
                    timestamp: 1.10
                )
            ),
            1
        )
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

    func testSuppliedFallbackTrendCanRetainTheLatestPriorTradingDay() {
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        let priorSession = [
            QuoteTrendPoint(
                sampledAt: now.addingTimeInterval(-4 * 24 * 60 * 60),
                price: DecimalString(97)
            ),
            QuoteTrendPoint(
                sampledAt: now.addingTimeInterval(-4 * 24 * 60 * 60 + 60),
                price: DecimalString(98)
            ),
        ]

        XCTAssertTrue(QuoteTrendHistory.pruned(priorSession, relativeTo: now).isEmpty)
        XCTAssertEqual(
            QuoteTrendHistory.pruned(
                priorSession,
                relativeTo: now,
                retention: QuoteTrendHistory.suppliedFallbackRetentionInterval
            ).map(\.price.value),
            [Decimal(97), Decimal(98)]
        )
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
        XCTAssertEqual(snapshot.pnl.unrealized?.value, Decimal(string: "10.01"))
        XCTAssertEqual(snapshot.pnl.realized?.value, Decimal(string: "2.33"))
        XCTAssertNil(snapshot.positions)
    }

    func testDecodesPositionAndCalculatesReturnPercent() throws {
        let json = #"""
        {
          "protocol_version": 1,
          "sequence": 8,
          "generated_at": "2026-08-27T02:52:22Z",
          "connection": {"state":"connected","changed_at":"2026-08-27T02:52:20Z"},
          "account": {"stale":false},
          "pnl": {"stale":false},
          "quotes": [],
          "positions": [{
            "con_id": 265598,
            "quantity": "10",
            "average_cost": "100",
            "market_value": "1125",
            "daily_pnl": "12.5",
            "unrealized_pnl": "125",
            "realized_pnl": "0",
            "cost_slots": [{
              "id": "265598:base",
              "quantity": "7",
              "price": "95",
              "source": "historical_base"
            }, {
              "id": "265598:exec:42",
              "quantity": "3",
              "price": "111.6667",
              "source": "execution"
            }],
            "received_at": "2026-08-27T02:52:21Z",
            "stale": false
          }]
        }
        """#
        let snapshot = try ProtocolCoding.decoder().decode(AppSnapshot.self, from: Data(json.utf8))
        let position = try XCTUnwrap(snapshot.position(for: 265598))
        XCTAssertEqual(position.returnPercent, Decimal(string: "12.5"))
        XCTAssertEqual(position.resolvedCostSlots.count, 2)
        XCTAssertTrue(position.resolvedCostSlots[0].isHistoricalBase)
        XCTAssertEqual(position.resolvedCostSlots[1].price.value, Decimal(string: "111.6667"))
    }

    func testMarketDataLabelsRemainExplicit() {
        XCTAssertEqual(MarketDataKind.realTime.displayName, "Real-Time")
        XCTAssertEqual(MarketDataKind.delayed.displayName, "Delayed")
        XCTAssertEqual(MarketDataKind.overnightIndicative.displayName, "Overnight Indicative")
        XCTAssertNotEqual(MarketDataKind.realTime.displayName, MarketDataKind.delayed.displayName)
        XCTAssertEqual(MarketDataKind.realTime.compactFeedName, "IEX · LIVE")
        XCTAssertEqual(MarketDataKind.delayed.compactFeedName, "DELAYED_SIP")
        XCTAssertEqual(MarketDataKind.overnightIndicative.compactFeedName, "OVERNIGHT")
        XCTAssertEqual(MarketDataKind.unknown.compactFeedName, "WAITING")
    }

    func testAlpacaStatusDoesNotClaimActiveBeforeSuccessfulData() {
        let configured = MarketDataStatus(
            provider: "alpaca",
            configured: true,
            active: false,
            lastUpdateAt: nil,
            error: nil
        )
        var unavailable = configured
        unavailable.error = "Alpaca market-data credentials are invalid or have been revoked"
        var active = configured
        active.active = true
        active.lastUpdateAt = Date()

        XCTAssertEqual(configured.displayName, "Alpaca · Configured")
        XCTAssertEqual(unavailable.displayName, "Alpaca · Unavailable")
        XCTAssertEqual(active.displayName, "Alpaca · Active")
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
            "provider": "alpaca",
            "configured": true,
            "active": true,
            "last_update_at": "2026-08-14T02:59:58Z",
            "error": null
          }
        }
        """#

        let snapshot = try ProtocolCoding.decoder().decode(AppSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.currentMarketData.provider, "alpaca")
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
