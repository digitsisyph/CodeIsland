import XCTest
@testable import CodeIsland

@MainActor
final class AccountQuotaCountdownTests: XCTestCase {
    private let reset = "2026-09-14T09:00:00Z"
    private let resetDate = Date(timeIntervalSince1970: 1_789_376_400)

    func testCountdownChangesUnitsAtDayAndHourBoundaries() {
        for (seconds, expected) in [
            (3 * 86_400 + 2 * 3_600, "3d 2h left"),
            (86_400, "1d 0h left"),
            (86_399, "23h 59m left"),
            (3_600, "1h 0m left"),
            (3_599, "59m left"),
            (60, "1m left"),
            (59, "<1m left")
        ] {
            XCTAssertEqual(AccountQuotaView.countdownText(reset,
                now: resetDate.addingTimeInterval(-Double(seconds)), language: "en"), expected)
        }
    }

    func testDueAndUnknownDatesDoNotClaimQuotaHasReset() {
        XCTAssertEqual(AccountQuotaView.countdownText(reset, now: resetDate, language: "en"),
                       "Due · awaiting refresh")
        XCTAssertEqual(AccountQuotaView.countdownText(reset, now: resetDate.addingTimeInterval(60), language: "en"),
                       "Due · awaiting refresh")
        XCTAssertNil(AccountQuotaView.countdownText(nil, now: resetDate, language: "en"))
        XCTAssertNil(AccountQuotaView.countdownText("unknown", now: resetDate, language: "en"))
    }

    func testChineseCountdownAndEquivalentTimezoneTimestamp() {
        let now = resetDate.addingTimeInterval(-(2 * 86_400 + 3 * 3_600))
        XCTAssertEqual(AccountQuotaView.countdownText("2026-09-14T02:00:00.000-07:00", now: now, language: "zh"),
                       "剩余 2 天 3 小时")
    }
}
