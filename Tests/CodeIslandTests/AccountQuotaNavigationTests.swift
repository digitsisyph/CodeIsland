import XCTest
@testable import CodeIsland

@MainActor
final class AccountQuotaNavigationTests: XCTestCase {
    func testQuotaPageOpensWithoutSessionsAndSurvivesCollapse() {
        let state = AppState()
        XCTAssertTrue(state.sessions.isEmpty)
        state.showAccountQuotas()
        XCTAssertEqual(state.surface, .accountQuotas)
        XCTAssertTrue(state.surface.isExpanded)
        XCTAssertNil(state.surface.sessionId)
        XCTAssertNil(state.surface.approvalSessionId)
        state.surface = .collapsed
        XCTAssertEqual(state.overviewSurface, .accountQuotas)
        state.surface = state.overviewSurface
        XCTAssertEqual(state.surface, .accountQuotas)
    }

    func testInteractiveCardDoesNotEraseSelectedTab() {
        let state = AppState()
        state.showAccountQuotas()
        state.surface = .approvalCard(sessionId: "test-session")
        XCTAssertEqual(state.overviewSurface, .accountQuotas)
        state.surface = .sessionList
        XCTAssertEqual(state.overviewSurface, .sessionList)
    }
}
