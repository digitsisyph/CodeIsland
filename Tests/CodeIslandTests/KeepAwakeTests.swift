import XCTest
import IOKit.pwr_mgt
@testable import CodeIsland

@MainActor
final class KeepAwakeTests: XCTestCase {
    func testAssertionsFollowDisplayOptionAndReleaseOnStop() throws {
        let saved = UserDefaults.standard.object(forKey: SettingsKey.keepDisplayAwake)
        let manager = KeepAwakeManager()
        defer {
            manager.stop()
            if let saved { UserDefaults.standard.set(saved, forKey: SettingsKey.keepDisplayAwake) }
            else { UserDefaults.standard.removeObject(forKey: SettingsKey.keepDisplayAwake) }
        }
        XCTAssertFalse(manager.isEnabled)
        manager.keepDisplayAwake = false
        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(try assertionTypes(), ["PreventUserIdleSystemSleep"])
        manager.keepDisplayAwake = true
        XCTAssertEqual(try assertionTypes(), ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"])
        manager.keepDisplayAwake = false
        XCTAssertEqual(try assertionTypes(), ["PreventUserIdleSystemSleep"])
        manager.stop()
        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(try assertionTypes().isEmpty)
    }

    private func assertionTypes() throws -> Set<String> {
        var result: Unmanaged<CFDictionary>?
        XCTAssertEqual(IOPMCopyAssertionsByProcess(&result), kIOReturnSuccess)
        let dictionary = try XCTUnwrap(result?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
        return Set((dictionary[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? [])
            .filter { $0["AssertName"] as? String == "CodeIsland coffee mode" }
            .compactMap { $0["AssertType"] as? String })
    }
}
