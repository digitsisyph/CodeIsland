import AppKit
import SwiftUI
import CodeIslandCore

@MainActor
final class AccountICloudSync: ObservableObject {
    static let shared = AccountICloudSync()
    static let enabledKey = "accountICloudSyncEnabled"
    private static let usageKey = "accountICloudSyncUsage"
    private static let preferencesKey = "accountICloudSyncPreferences"

    @Published var enabled: Bool { didSet { configurationChanged(key: Self.enabledKey, value: enabled) } }
    @Published var syncUsage: Bool { didSet { configurationChanged(key: Self.usageKey, value: syncUsage) } }
    @Published var syncPreferences: Bool { didSet { configurationChanged(key: Self.preferencesKey, value: syncPreferences) } }
    @Published private(set) var devices: [AccountSyncDocument] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var errorKey: String?
    @Published private(set) var lastWriteAt: Date?
    @Published private(set) var lastUploadedAt: Date?
    let deviceID: String
    let directory: URL

    private let defaults = UserDefaults.standard
    private var preferences: [String: AccountSyncPreference]
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var lastAttempt: Date?

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.enabledKey: false, Self.usageKey: true, Self.preferencesKey: true])
        enabled = defaults.bool(forKey: Self.enabledKey)
        syncUsage = defaults.bool(forKey: Self.usageKey)
        syncPreferences = defaults.bool(forKey: Self.preferencesKey)
        if let saved = defaults.string(forKey: "accountICloudDeviceID"), UUID(uuidString: saved) != nil {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "accountICloudDeviceID")
        }
        preferences = defaults.data(forKey: "accountICloudPreferenceVersions")
            .flatMap { try? JSONDecoder().decode([String: AccountSyncPreference].self, from: $0) } ?? [:]
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/CodeIsland/Sync/v1", isDirectory: true)
        capturePreferenceChanges()
    }

    var available: Bool {
        var isDirectory: ObjCBool = false
        let root = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var remoteDevices: [AccountSyncDocument] { devices.filter { $0.deviceID != deviceID } }

    func mergedSnapshot(local: AccountQuotaSnapshot?) -> AccountQuotaSnapshot? {
        guard enabled && syncUsage else { return local }
        return AccountSyncDocument.mergeQuotas(local: local, documents: remoteDevices)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.enabled {
                    if self.lastAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
                        await self.syncNow()
                    } else {
                        await self.checkUploadStatus()
                    }
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    private func configurationChanged(key: String, value: Bool) {
        defaults.set(value, forKey: key)
        generation += 1
        lastAttempt = nil
        if !enabled { devices = []; errorKey = nil }
        else { Task { await syncNow() } }
    }

    func syncNow() async {
        guard enabled, !isSyncing else { return }
        guard available else { errorKey = "icloud_unavailable"; return }
        isSyncing = true
        lastAttempt = Date()
        let currentGeneration = generation
        defer { isSyncing = false }
        let store = AccountSyncFileStore(directory: directory)
        do {
            let received = try await Task.detached(priority: .utility) { try store.read() }.value
            guard enabled, currentGeneration == generation else { return }
            capturePreferenceChanges()
            if syncPreferences {
                preferences = AccountSyncDocument.mergePreferences(preferences, documents: received)
                applyPreferences()
            }
            // Only local measurements are published. Imported accounts never echo
            // back into another device's document or alter the active CLI login.
            if syncUsage { await AccountQuotaMonitor.shared.refresh() }
            guard enabled, currentGeneration == generation else { return }
            capturePreferenceChanges()
            let document = AccountSyncDocument(deviceID: deviceID,
                deviceName: Host.current().localizedName ?? "Mac",
                snapshot: syncUsage ? AccountQuotaMonitor.shared.snapshot : nil,
                preferences: syncPreferences ? preferences : [:])
            _ = try await Task.detached(priority: .utility) { try store.write(document) }.value
            guard enabled, currentGeneration == generation else { return }
            devices = (received.filter { $0.deviceID != deviceID } + [document])
                .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
            lastWriteAt = document.updatedAt
            errorKey = nil
            await checkUploadStatus()
        } catch {
            guard enabled, currentGeneration == generation else { return }
            errorKey = "icloud_io_error"
        }
    }

    private func checkUploadStatus() async {
        guard enabled, let written = lastWriteAt else { return }
        let url = directory.appendingPathComponent(deviceID).appendingPathExtension("json")
        let uploaded = await Task.detached(priority: .utility) {
            (try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?.ubiquitousItemIsUploaded == true
        }.value
        if enabled, uploaded { lastUploadedAt = written }
    }

    private func capturePreferenceChanges() {
        for (key, fallback) in AccountSyncPreference.defaults {
            let value: String
            if key == SettingsKey.quotaProviderOrder { value = defaults.string(forKey: key) ?? fallback }
            else { value = (defaults.object(forKey: key) as? Bool).map(String.init) ?? fallback }
            guard AccountSyncPreference.isAllowed(key: key, value: value) else { continue }
            if preferences[key]?.value != value {
                preferences[key] = AccountSyncPreference(value: value,
                    modifiedAt: preferences[key] == nil ? Date(timeIntervalSince1970: 0) : Date(), deviceID: deviceID)
            }
        }
        savePreferenceVersions()
    }

    private func applyPreferences() {
        for (key, setting) in preferences where AccountSyncPreference.isAllowed(key: key, value: setting.value) {
            if key == SettingsKey.quotaProviderOrder { defaults.set(setting.value, forKey: key) }
            else { defaults.set(setting.value == "true", forKey: key) }
        }
        savePreferenceVersions()
    }

    private func savePreferenceVersions() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: "accountICloudPreferenceVersions")
        }
    }
}

struct ICloudSyncPage: View {
    @ObservedObject private var sync = AccountICloudSync.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.quotaHideCodexSpark) private var hideSpark = true
    @AppStorage(SettingsKey.quotaShowCountdown) private var showCountdown = true
    @AppStorage(SettingsKey.quotaProviderOrder) private var providerOrder = "claude"

    var body: some View {
        Form {
            Section(l10n["icloud"]) {
                Toggle(l10n["icloud_enable"], isOn: $sync.enabled)
                    .disabled(!sync.available && !sync.enabled)
                Toggle(l10n["icloud_usage"], isOn: $sync.syncUsage).disabled(!sync.enabled)
                Toggle(l10n["icloud_preferences"], isOn: $sync.syncPreferences).disabled(!sync.enabled)
                Text(l10n["icloud_description"]).font(.caption).foregroundStyle(.secondary)
                if !sync.available { Text(l10n["icloud_unavailable"]).foregroundStyle(.orange) }
                if let error = sync.errorKey { Text(l10n[error]).foregroundStyle(.orange) }
                HStack {
                    Button(l10n["icloud_sync_now"]) { Task { await sync.syncNow() } }
                        .disabled(!sync.enabled || sync.isSyncing)
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                    if let uploaded = sync.lastUploadedAt {
                        Text("\(l10n["icloud_uploaded"]) \(uploaded.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if sync.lastWriteAt != nil {
                        Text(l10n["icloud_pending"]).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section(l10n["icloud_display"]) {
                Toggle(l10n["icloud_hide_spark"], isOn: $hideSpark)
                Toggle(l10n["icloud_countdown"], isOn: $showCountdown)
                Picker(l10n["icloud_provider_first"], selection: $providerOrder) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                }
            }
            if sync.enabled {
                Section(l10n["icloud_devices"]) {
                    if sync.devices.isEmpty { Text(l10n["icloud_no_devices"]).foregroundStyle(.secondary) }
                    ForEach(sync.devices) { device in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.deviceName + (device.deviceID == sync.deviceID ? " · " + l10n["icloud_this_mac"] : ""))
                            Text(device.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(l10n["icloud"])
    }
}
