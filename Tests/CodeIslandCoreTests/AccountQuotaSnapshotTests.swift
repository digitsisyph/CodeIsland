import XCTest
@testable import CodeIslandCore

final class AccountQuotaSnapshotTests: XCTestCase {
    func testProviderResetTimesWithFractionalSecondsAndOffsets() throws {
        let plain = try XCTUnwrap(AccountQuotaTimestamp.parse("2026-09-14T09:00:00Z"))
        let fractional = try XCTUnwrap(AccountQuotaTimestamp.parse("2026-09-14T09:00:00.123456+00:00"))
        XCTAssertEqual(fractional.timeIntervalSince(plain), 0.123456, accuracy: 0.001)
        XCTAssertEqual(AccountQuotaTimestamp.parse("2026-09-14T02:00:00-07:00"), plain)
        XCTAssertNil(AccountQuotaTimestamp.parse(nil))
        XCTAssertNil(AccountQuotaTimestamp.parse("unknown"))
    }

    func testAccountsKeepIndependentWorkspacesAndUnknownResetCredits() throws {
        let data = Data(#"{"schemaVersion":1,"updatedAt":"2026-09-10T20:00:00+00:00","accounts":[{"id":"codex:1:a@example.com:personal","provider":"codex","number":"1","email":"a@example.com","organization":"Personal","workspaceId":"personal","active":true,"status":"ok","error":null,"fetchedAt":"2026-09-10T20:00:00+00:00","windows":[{"id":"weekly","label":"Weekly","usedPercent":52,"remainingPercent":48,"resetsAt":null}],"resetCredits":null},{"id":"codex:2:a@example.com:team","provider":"codex","number":"2","email":"a@example.com","organization":"Team","workspaceId":"team","active":false,"status":"unavailable","windows":[],"resetCredits":{"available":0,"earliestExpiresAt":null}}],"errors":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(AccountQuotaSnapshot.self, from: data)
        XCTAssertEqual(snapshot.accounts.count, 2)
        XCTAssertNotEqual(snapshot.accounts[0].id, snapshot.accounts[1].id)
        XCTAssertEqual(snapshot.accounts[0].windows[0].remainingPercent, 48)
        XCTAssertNil(snapshot.accounts[0].windows[0].resetsAt)
        XCTAssertNil(snapshot.accounts[0].resetCredits)
        XCTAssertEqual(snapshot.accounts[1].resetCredits?.available, 0)
    }
}
