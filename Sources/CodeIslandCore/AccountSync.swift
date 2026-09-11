import Foundation

/// A deliberately small allowlist. Login state, hooks, paths and permissions
/// are never part of a sync document.
public struct AccountSyncPreference: Codable, Equatable, Sendable {
    public let value: String
    public let modifiedAt: Date
    public let deviceID: String

    public init(value: String, modifiedAt: Date, deviceID: String) {
        self.value = value
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }

    public static let defaults = [
        "quotaHideCodexSpark": "true",
        "quotaShowCountdown": "true",
        "quotaProviderOrder": "claude"
    ]

    public static func isAllowed(key: String, value: String) -> Bool {
        switch key {
        case "quotaHideCodexSpark", "quotaShowCountdown": return ["true", "false"].contains(value)
        case "quotaProviderOrder": return ["claude", "codex"].contains(value)
        default: return false
        }
    }

    public func isNewer(than other: Self) -> Bool {
        modifiedAt > other.modifiedAt || (modifiedAt == other.modifiedAt && deviceID > other.deviceID)
    }
}

public struct AccountSyncDocument: Codable, Sendable, Identifiable {
    public var id: String { deviceID }
    public let schemaVersion: Int
    public let deviceID: String
    public let deviceName: String
    public let updatedAt: Date
    public let snapshot: AccountQuotaSnapshot?
    public let preferences: [String: AccountSyncPreference]

    public init(deviceID: String, deviceName: String, updatedAt: Date = Date(),
                snapshot: AccountQuotaSnapshot?, preferences: [String: AccountSyncPreference]) {
        schemaVersion = 1
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        // Re-encode typed, credential-free data; never publish the CLI's raw JSON.
        self.snapshot = snapshot.map {
            AccountQuotaSnapshot(schemaVersion: 1, updatedAt: $0.updatedAt,
                accounts: $0.accounts.map { $0.syncCopy(active: false, source: nil) }, errors: [])
        }
        self.preferences = preferences.filter { AccountSyncPreference.isAllowed(key: $0.key, value: $0.value.value) }
    }

    public static func mergePreferences(_ local: [String: AccountSyncPreference],
                                       documents: [Self]) -> [String: AccountSyncPreference] {
        var result = local.filter { AccountSyncPreference.isAllowed(key: $0.key, value: $0.value.value) }
        for document in documents where document.schemaVersion == 1 {
            for (key, value) in document.preferences where AccountSyncPreference.isAllowed(key: key, value: value.value) {
                if result[key].map({ value.isNewer(than: $0) }) ?? true { result[key] = value }
            }
        }
        return result
    }

    public static func mergeQuotas(local: AccountQuotaSnapshot?, documents: [Self]) -> AccountQuotaSnapshot? {
        let documents = documents.filter { $0.schemaVersion == 1 && $0.snapshot?.schemaVersion == 1 }
            .sorted { $0.deviceID < $1.deviceID }
        guard local != nil || !documents.isEmpty else { return nil }
        var accounts: [String: AccountQuota] = [:]
        var order: [String] = []
        for account in local?.accounts ?? [] {
            if accounts[account.syncIdentity] == nil { order.append(account.syncIdentity) }
            accounts[account.syncIdentity] = account
        }
        for document in documents {
            for remote in document.snapshot?.accounts ?? [] {
                let key = remote.syncIdentity
                let localAccount = accounts[key]
                let remoteDate = AccountQuotaTimestamp.parse(remote.fetchedAt) ?? .distantPast
                let localDate = AccountQuotaTimestamp.parse(localAccount?.fetchedAt) ?? .distantPast
                // A failed/empty newer fetch must not erase a usable measurement.
                let usable = !remote.windows.isEmpty && ["ok", "stale"].contains(remote.status)
                let localUsable = localAccount.map { !$0.windows.isEmpty && ["ok", "stale"].contains($0.status) } ?? false
                guard localAccount == nil || (usable && (!localUsable || remoteDate > localDate)) else { continue }
                if localAccount == nil { order.append(key) }
                accounts[key] = remote.syncCopy(active: localAccount?.active ?? false, source: document.deviceName)
            }
        }
        return AccountQuotaSnapshot(schemaVersion: 1,
            updatedAt: local?.updatedAt ?? documents.last?.snapshot?.updatedAt ?? "",
            accounts: order.compactMap { accounts[$0] }, errors: local?.errors ?? [])
    }
}

private extension AccountQuota {
    var syncIdentity: String {
        [provider.lowercased(), email.lowercased(), workspaceId.isEmpty ? organization : workspaceId]
            .joined(separator: "\u{1F}")
    }

    func syncCopy(active: Bool, source: String?) -> Self {
        Self(id: syncIdentity, provider: provider, number: number, email: email,
             organization: organization, workspaceId: workspaceId, active: active,
             status: status, error: nil, fetchedAt: fetchedAt, windows: windows,
             resetCredits: resetCredits, sourceDevice: source)
    }
}

/// One writer per device avoids cross-Mac read/modify/write races. Files are
/// coordinated with iCloud and atomically replaced; callers run this off the UI thread.
public struct AccountSyncFileStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func read() throws -> [AccountSyncDocument] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
        var documents: [AccountSyncDocument] = []
        for url in urls {
            // Older iCloud Drive versions expose evicted files as .name.icloud.
            if url.lastPathComponent.hasPrefix("."), url.lastPathComponent.hasSuffix(".json.icloud") {
                let name = String(url.lastPathComponent.dropFirst().dropLast(".icloud".count))
                let target = directory.appendingPathComponent(name)
                if UUID(uuidString: target.deletingPathExtension().lastPathComponent) != nil {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: target)
                }
                continue
            }
            guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
            if values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard (values?.fileSize ?? 0) <= 2_000_000 else { continue }
            var coordinatorError: NSError?
            var document: AccountSyncDocument?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordinated in
                guard let data = try? Data(contentsOf: coordinated), data.count <= 2_000_000,
                      let decoded = try? JSONDecoder().decode(AccountSyncDocument.self, from: data),
                      decoded.schemaVersion == 1,
                      decoded.deviceID == url.deletingPathExtension().lastPathComponent,
                      decoded.snapshot == nil || decoded.snapshot?.schemaVersion == 1 else { return }
                document = decoded
            }
            if let document { documents.append(document) }
        }
        return documents
    }

    public func write(_ document: AccountSyncDocument) throws -> URL {
        guard UUID(uuidString: document.deviceID) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(document.deviceID).appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinated in
            do { try data.write(to: coordinated, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinatorError ?? writeError as NSError? { throw error }
        return url
    }
}
