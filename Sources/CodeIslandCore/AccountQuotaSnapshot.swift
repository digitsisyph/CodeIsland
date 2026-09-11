import Foundation

/// Public, credential-free output from the account core bundled with this app.
public struct AccountQuotaSnapshot: Decodable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: String
    public let accounts: [AccountQuota]
    public let errors: [AccountQuotaError]
}

public struct AccountQuotaError: Decodable, Sendable {
    public let provider: String
    public let message: String
}

public struct AccountQuota: Decodable, Identifiable, Sendable {
    public let id: String
    public let provider: String
    public let number: String
    public let email: String
    public let organization: String
    public let workspaceId: String
    public let active: Bool
    public let status: String
    public let error: String?
    public let fetchedAt: String?
    public let windows: [AccountQuotaWindow]
    public let resetCredits: AccountResetCredits?
}

public struct AccountQuotaWindow: Decodable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let remainingPercent: Double
    public let resetsAt: String?
}

public struct AccountResetCredits: Decodable, Sendable {
    public let available: Int?
    public let earliestExpiresAt: String?
}
