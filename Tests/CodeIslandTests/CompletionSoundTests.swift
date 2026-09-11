import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class CompletionSoundTests: XCTestCase {
    private var sounds: [String] = []
    private var speech: [String] = []
    private var saved: [String: Any] = [:]
    private let keys = [SettingsKey.soundEnabled, SettingsKey.soundTaskComplete,
                        SettingsKey.completionSoundMode, SettingsKey.speechVoiceID,
                        SettingsKey.quietHoursEnabled, SettingsKey.quietHoursStart, SettingsKey.quietHoursEnd]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKey.soundTaskComplete)
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        UserDefaults.standard.set("chime", forKey: SettingsKey.completionSoundMode)
        UserDefaults.standard.set("", forKey: SettingsKey.speechVoiceID)
        SoundManager.shared.playSink = { [weak self] in self?.sounds.append($0) }
        SoundManager.shared.speechSink = { [weak self] in self?.speech.append($0) }
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        SoundManager.shared.speechSink = nil
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func app(provider: String = "codex") -> AppState {
        let app = AppState()
        var session = SessionSnapshot()
        session.source = provider
        session.sessionTitle = "额度页面"
        session.status = .processing
        app.sessions["test-session"] = session
        return app
    }

    private func apply(_ app: AppState, type: String, turn: String? = nil) throws {
        var payload = ["type": type]
        payload["turn_id"] = turn
        var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": payload])
        data.append(10)
        let delta = JSONLTailer.scanLines(data).delta
        app.applyTranscriptDelta(ConversationTailDelta(sessionId: "test-session", lastUserPrompt: nil,
            lastAssistantMessage: nil, turnStatus: delta.turnStatus, turnOutcome: delta.turnOutcome,
            turnID: delta.turnID, hasActivity: delta.hasActivity))
    }

    private func hook(_ app: AppState, name: String, reason: String? = nil) throws {
        var payload = ["hook_event_name": name, "session_id": "test-session"]
        payload["stop_reason"] = reason
        app.handleEvent(try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload))))
    }

    func testCodexCompletionChimesOncePerTurnIncludingRepeatedOldEvents() throws {
        let state = app()
        try apply(state, type: "task_complete", turn: "one")
        try apply(state, type: "task_complete", turn: "one")
        try apply(state, type: "task_complete", turn: "two")
        try apply(state, type: "task_complete", turn: "one")
        XCTAssertEqual(sounds, ["completion_chime", "completion_chime"])
    }

    func testLiveFileCompletionAnnouncesButColdStartHistoryDoesNot() async throws {
        let state = app()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let old = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"old\"}}\n"
        try old.write(to: path, atomically: true, encoding: .utf8)
        defer {
            state.detachTranscriptTailer(sessionId: "test-session")
            try? FileManager.default.removeItem(at: path)
        }
        state.sessions["test-session"]?.transcriptPath = path.path
        state.attachTranscriptTailerIfNeeded(sessionId: "test-session")
        XCTAssertTrue(sounds.isEmpty)
        let announced = expectation(description: "Live Codex completion sound")
        SoundManager.shared.playSink = { [weak self] in
            self?.sounds.append($0)
            announced.fulfill()
        }
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(old.replacingOccurrences(of: "old", with: "new").utf8))
        try handle.close()
        await fulfillment(of: [announced], timeout: 5)
        XCTAssertEqual(sounds, ["completion_chime"])
    }

    func testCodexLiveTranscriptAndHookDoNotBothAnnounce() throws {
        let state = app()
        state.attachedTranscriptPaths["test-session"] = "/synthetic/rollout.jsonl"
        try hook(state, name: "Stop")
        XCTAssertTrue(sounds.isEmpty)
        try apply(state, type: "task_complete", turn: "one")
        try hook(state, name: "Stop")
        XCTAssertEqual(sounds, ["completion_chime"])
    }

    func testCancelledFailedAndStatusOnlyUpdatesDoNotAnnounceSuccess() throws {
        let state = app()
        try apply(state, type: "turn_aborted", turn: "cancelled")
        XCTAssertEqual(state.sessions["test-session"]?.interrupted, true)
        try apply(state, type: "turn_failed", turn: "failed")
        state.applyTranscriptDelta(ConversationTailDelta(sessionId: "test-session", lastUserPrompt: nil,
            lastAssistantMessage: nil, turnStatus: .idle))
        XCTAssertTrue(sounds.isEmpty)
    }

    func testClaudeNormalTurnsAnnounceButInterruptionDoesNot() throws {
        let state = app(provider: "claude")
        try hook(state, name: "Stop", reason: "user")
        try hook(state, name: "UserPromptSubmit")
        try hook(state, name: "Stop")
        try hook(state, name: "Stop")
        try hook(state, name: "UserPromptSubmit")
        try hook(state, name: "Stop")
        XCTAssertEqual(sounds.filter { $0 == "completion_chime" }.count, 2)
    }

    func testSpeechUsesProviderAndSessionNameAndRespectsMute() throws {
        UserDefaults.standard.set("speech", forKey: SettingsKey.completionSoundMode)
        let state = app()
        try apply(state, type: "task_complete", turn: "one")
        XCTAssertEqual(speech, ["Codex，额度页面，已完成。"])
        XCTAssertTrue(sounds.isEmpty)
        UserDefaults.standard.set(false, forKey: SettingsKey.soundEnabled)
        try apply(state, type: "task_complete", turn: "two")
        UserDefaults.standard.set(true, forKey: SettingsKey.soundEnabled)
        try apply(state, type: "task_complete", turn: "two")
        XCTAssertEqual(speech.count, 1, "Do not replay muted completions later")
    }

    func testQuietHoursAndCompletionToggleSilenceBothModes() throws {
        for mode in ["chime", "speech"] {
            UserDefaults.standard.set(mode, forKey: SettingsKey.completionSoundMode)
            UserDefaults.standard.set(false, forKey: SettingsKey.soundTaskComplete)
            SoundManager.shared.playCompletion(provider: "claude", title: "Test")
            UserDefaults.standard.set(true, forKey: SettingsKey.soundTaskComplete)
            UserDefaults.standard.set(true, forKey: SettingsKey.quietHoursEnabled)
            UserDefaults.standard.set(0, forKey: SettingsKey.quietHoursStart)
            UserDefaults.standard.set(1_440, forKey: SettingsKey.quietHoursEnd)
            SoundManager.shared.playCompletion(provider: "claude", title: "Test")
            UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        }
        XCTAssertTrue(sounds.isEmpty)
        XCTAssertTrue(speech.isEmpty)
    }

    func testLegacyCodexTurnsWithoutIDsRearmOnStart() throws {
        let state = app()
        try apply(state, type: "task_complete")
        try apply(state, type: "task_complete")
        try apply(state, type: "task_started")
        try apply(state, type: "task_complete")
        XCTAssertEqual(sounds.count, 2)
    }

    func testTranscriptStartClearsPreviousOutcomeInSameBatch() {
        let data = Data("""
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"old"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"new"}}

        """.utf8)
        let delta = JSONLTailer.scanLines(data).delta
        XCTAssertEqual(delta.turnStatus, .processing)
        XCTAssertNil(delta.turnOutcome)
        XCTAssertEqual(delta.turnID, "new")
    }
}
