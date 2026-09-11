import CodeIslandCore

extension AppState {
    func notifySessionCompletion(sessionId: String, outcome: ConversationTurnOutcome, turnID: String? = nil) {
        guard let session = sessions[sessionId] else { return }
        if let turnID, !turnID.isEmpty {
            guard completionSoundTurns[sessionId, default: []].insert(turnID).inserted else { return }
            completionSoundSettled.insert(sessionId)
        } else {
            guard completionSoundSettled.insert(sessionId).inserted else { return }
        }
        guard outcome == .completed else { return }
        SoundManager.shared.playCompletion(provider: session.source,
            title: session.sessionLabel ?? session.projectDisplayName)
    }
}
