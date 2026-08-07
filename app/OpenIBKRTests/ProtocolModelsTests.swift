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
        XCTAssertEqual(window.contentMinSize.height, window.contentMaxSize.height)
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
        XCTAssertEqual(MarketDataKind.realTime.displayName, "实时")
        XCTAssertEqual(MarketDataKind.delayed.displayName, "延迟")
        XCTAssertNotEqual(MarketDataKind.realTime.displayName, MarketDataKind.delayed.displayName)
    }

    func testRejectsUnknownMajorProtocolVersion() {
        XCTAssertNoThrow(try ProtocolCoding.requireSupported(1))
        XCTAssertThrowsError(try ProtocolCoding.requireSupported(2)) { error in
            guard case HelperClientError.incompatibleProtocol(2) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
