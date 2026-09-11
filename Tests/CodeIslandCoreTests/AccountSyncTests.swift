import XCTest
@testable import CodeIslandCore

final class AccountSyncTests: XCTestCase {
    private let firstID = "11111111-1111-1111-1111-111111111111"
    private let secondID = "22222222-2222-2222-2222-222222222222"

    private func snapshot(workspace: String = "personal", number: String = "1",
                          fetched: String = "2026-09-10T20:00:00Z", remaining: Int = 80,
                          active: Bool = true, status: String = "ok") throws -> AccountQuotaSnapshot {
        let json: [String: Any] = [
            "schemaVersion": 1, "updatedAt": fetched,
            "accounts": [["id": "codex:\(number):test@example.com:\(workspace)", "provider": "codex",
                "number": number, "email": "test@example.com", "organization": workspace,
                "workspaceId": workspace, "active": active, "status": status,
                "error": "FAKE_PRIVATE_DIAGNOSTIC", "access_token": "FAKE_SECRET",
                "fetchedAt": fetched, "windows": status == "unavailable" ? [] : [
                    ["id": "weekly", "label": "Weekly", "usedPercent": 100 - remaining,
                     "remainingPercent": remaining, "resetsAt": "2026-09-14T20:00:00Z"]]]],
            "errors": [["provider": "codex", "message": "FAKE_PRIVATE_DIAGNOSTIC"]]
        ]
        return try JSONDecoder().decode(AccountQuotaSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testNewestMeasurementDeduplicatesDifferentSlotNumbersAndKeepsLocalActiveState() throws {
        let local = try snapshot()
        let remote = AccountSyncDocument(deviceID: secondID, deviceName: "Second Mac",
            snapshot: try snapshot(number: "7", fetched: "2026-09-10T20:01:00Z", remaining: 60), preferences: [:])
        let result = try XCTUnwrap(AccountSyncDocument.mergeQuotas(local: local, documents: [remote]))
        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(result.accounts[0].windows[0].remainingPercent, 60)
        XCTAssertEqual(result.accounts[0].sourceDevice, "Second Mac")
        XCTAssertTrue(result.accounts[0].active)
        let offline = try XCTUnwrap(AccountSyncDocument.mergeQuotas(local: nil, documents: [remote]))
        XCTAssertFalse(offline.accounts[0].active)
    }

    func testSameEmailDifferentWorkspacesStaySeparateAndOldRemoteDoesNotReplaceLocal() throws {
        let older = AccountSyncDocument(deviceID: firstID, deviceName: "Older Mac",
            snapshot: try snapshot(fetched: "2026-09-10T19:00:00Z", remaining: 90), preferences: [:])
        let team = AccountSyncDocument(deviceID: secondID, deviceName: "Team Mac",
            snapshot: try snapshot(workspace: "team"), preferences: [:])
        let result = try XCTUnwrap(AccountSyncDocument.mergeQuotas(local: snapshot(), documents: [older, team]))
        XCTAssertEqual(result.accounts.count, 2)
        XCTAssertEqual(result.accounts[0].windows[0].remainingPercent, 80)
        XCTAssertNil(result.accounts[0].sourceDevice)
        XCTAssertEqual(Set(result.accounts.map(\.workspaceId)), ["personal", "team"])
        XCTAssertEqual(Set(result.accounts.map(\.id)).count, 2)
    }

    func testFailedRemoteFetchCannotEraseUsableLocalMeasurement() throws {
        let remote = AccountSyncDocument(deviceID: secondID, deviceName: "Second Mac",
            snapshot: try snapshot(fetched: "2026-09-10T20:02:00Z", status: "unavailable"), preferences: [:])
        let result = try XCTUnwrap(AccountSyncDocument.mergeQuotas(local: snapshot(), documents: [remote]))
        XCTAssertEqual(result.accounts[0].windows[0].remainingPercent, 80)
    }

    func testPreferencesMergeIndependentlyAndNeverImportUnknownKeys() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let local = ["quotaHideCodexSpark": AccountSyncPreference(value: "false", modifiedAt: new, deviceID: firstID)]
        let remote = AccountSyncDocument(deviceID: secondID, deviceName: "Second Mac", snapshot: nil, preferences: [
            "quotaHideCodexSpark": .init(value: "true", modifiedAt: old, deviceID: secondID),
            "quotaProviderOrder": .init(value: "codex", modifiedAt: new, deviceID: secondID),
            "quotaShowCountdown": .init(value: "invalid", modifiedAt: new, deviceID: secondID),
            "autoApproveTools": .init(value: "all", modifiedAt: new, deviceID: secondID)
        ])
        let merged = AccountSyncDocument.mergePreferences(local, documents: [remote])
        XCTAssertEqual(merged["quotaHideCodexSpark"]?.value, "false")
        XCTAssertEqual(merged["quotaProviderOrder"]?.value, "codex")
        XCTAssertNil(merged["autoApproveTools"])
        XCTAssertNil(merged["quotaShowCountdown"])
        let echoed = AccountSyncDocument(deviceID: firstID, deviceName: "First Mac", snapshot: nil, preferences: merged)
        XCTAssertEqual(AccountSyncDocument.mergePreferences(merged, documents: [remote, echoed]), merged)
    }

    func testPublishedDocumentContainsOnlyQuotaDataAndAllowedPreferences() throws {
        let document = AccountSyncDocument(deviceID: firstID, deviceName: "Test Mac", snapshot: try snapshot(), preferences: [:])
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        XCTAssertFalse(json.contains("FAKE_SECRET"))
        XCTAssertFalse(json.contains("FAKE_PRIVATE_DIAGNOSTIC"))
        XCTAssertFalse(json.contains("access_token"))
        XCTAssertFalse(try XCTUnwrap(document.snapshot).accounts[0].active)
        XCTAssertTrue(try XCTUnwrap(document.snapshot).errors.isEmpty)
    }

    func testTwoDeviceFilesRoundTripAndIgnoreCorruptOrFutureDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountSyncFileStore(directory: directory)
        let first = AccountSyncDocument(deviceID: firstID, deviceName: "First Mac", snapshot: try snapshot(), preferences: [:])
        let second = AccountSyncDocument(deviceID: secondID, deviceName: "Second Mac", snapshot: try snapshot(workspace: "team"), preferences: [:])
        _ = try store.write(first)
        _ = try store.write(second)
        XCTAssertEqual(Set(try store.read().map(\.deviceID)), [firstID, secondID])
        try Data("broken".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"))
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(second)) as? [String: Any])
        future["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: future).write(to: directory.appendingPathComponent(secondID + ".json"))
        XCTAssertEqual(try store.read().map(\.deviceID), [firstID])
        let newer = AccountSyncDocument(deviceID: firstID, deviceName: "First Mac", snapshot: try snapshot(remaining: 30), preferences: [:])
        _ = try store.write(newer)
        XCTAssertEqual(try store.read().first?.snapshot?.accounts.first?.windows.first?.remainingPercent, 30)
    }
}
