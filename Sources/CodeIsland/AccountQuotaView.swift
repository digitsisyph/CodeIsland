import AppKit
import SwiftUI
import CodeIslandCore

@MainActor
final class AccountQuotaMonitor: ObservableObject {
    static let shared = AccountQuotaMonitor()
    @Published private(set) var snapshot: AccountQuotaSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private var refreshedAt: Date?

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let refreshedAt, Date().timeIntervalSince(refreshedAt) < 60 { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codeisland")
        // Source builds use this repository's environment. Release builds embed
        // the interpreter and all dependencies alongside the executable.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let development = repository.appendingPathComponent("AccountCore/.venv/bin/codeisland")
        let helper = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : development
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            error = "Account core is missing. Build CodeIsland with ./build.sh."
            return
        }
        let path = helper.path
        let data = await Task.detached(priority: .utility) {
            ProcessRunner.run(path: path, args: ["usage", "--json"], timeout: 90)
        }.value
        guard let data else {
            error = "Accounts could not refresh. Previous measurements may be out of date."
            return
        }
        do {
            let result = try JSONDecoder().decode(AccountQuotaSnapshot.self, from: data)
            guard result.schemaVersion == 1 else {
                error = "Update the app and account core together."
                return
            }
            snapshot = result
            refreshedAt = Date()
            error = nil
        } catch {
            self.error = "The account core returned an unreadable snapshot."
        }
    }
}

struct AccountQuotaView: View {
    @ObservedObject private var monitor = AccountQuotaMonitor.shared
    @ObservedObject private var sync = AccountICloudSync.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKey.quotaHideCodexSpark) private var hideSpark = true
    @AppStorage(SettingsKey.quotaShowCountdown) private var showCountdown = true
    @AppStorage(SettingsKey.quotaProviderOrder) private var providerOrder = "claude"

    private var snapshot: AccountQuotaSnapshot? { sync.mergedSnapshot(local: monitor.snapshot) }

    private func orderedAccounts(_ accounts: [AccountQuota]) -> [AccountQuota] {
        accounts.filter { $0.provider == providerOrder } + accounts.filter { $0.provider != providerOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let snapshot {
                    HStack(spacing: 12) {
                        ForEach(["claude", "codex"], id: \.self) { provider in
                            let count = snapshot.accounts.filter { $0.provider == provider }.count
                            HStack(spacing: 4) {
                                QuotaProviderIcon(provider: provider, size: 14)
                                Text("\(count)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(provider.capitalized): \(count)")
                        }
                    }
                }
                if sync.enabled {
                    Image(systemName: sync.errorKey == nil ? "icloud" : "icloud.slash")
                        .font(.caption).foregroundStyle(sync.errorKey == nil ? Color.secondary : Color.orange)
                        .help(l10n[sync.errorKey ?? "icloud"])
                }
                Spacer()
                if monitor.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await monitor.refresh(force: true) } } label: {
                    Label(l10n["quota_refresh"], systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                    .buttonStyle(.plain)
                    .disabled(monitor.isRefreshing)
            }
            if let error = monitor.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let snapshot {
                if snapshot.accounts.isEmpty {
                    Text("Add accounts in Terminal:\ncodeisland claude add\ncodeisland codex add")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(orderedAccounts(snapshot.accounts)) { account in
                                accountRow(account, now: context.date)
                                Divider()
                            }
                            ForEach(Array(snapshot.errors.enumerated()), id: \.offset) { _, error in
                                Text("\(error.provider): \(error.message)").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } else if !monitor.isRefreshing {
                Text("Refresh to load account quotas.").foregroundStyle(.secondary)
            }
            Text(l10n["quota_footer"])
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
        .task {
            await monitor.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await monitor.refresh()
            }
        }
    }

    private func accountRow(_ account: AccountQuota, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                QuotaProviderIcon(provider: account.provider, size: 18)
                Text(account.email).fontWeight(.semibold).textSelection(.enabled)
                if account.active { Text("Active").font(.caption).foregroundStyle(.green) }
                Spacer()
            }
            Text(account.organization.isEmpty ? "Personal" : account.organization)
                .font(.caption).foregroundStyle(.secondary)
            if let source = account.sourceDevice {
                Text("\(l10n["icloud_via"]) \(source)")
                    .font(.caption2).foregroundStyle(.cyan)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(account.windows.filter {
                    !hideSpark || account.provider != "codex" || !$0.label.localizedCaseInsensitiveContains("spark")
                }) { window in
                    quotaRing(window, now: now)
                }
            }
            .padding(.vertical, 6)
            if let credits = account.resetCredits {
                Text("Reset credits: \(credits.available.map(String.init) ?? "—") · earliest expiry: \(resetText(credits.earliestExpiresAt))")
                    .font(.caption)
            }
            if account.status != "ok" {
                Text(account.error ?? account.status).font(.caption).foregroundStyle(.orange)
            }
            Text("Updated: \(resetText(account.fetchedAt))").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func quotaRing(_ window: AccountQuotaWindow, now: Date) -> some View {
        let remaining = max(0, min(100, window.remainingPercent))
        let color: Color = remaining < 20 ? .orange : .green
        let countdown = showCountdown ? Self.countdownText(window.resetsAt, now: now, language: l10n.effectiveLanguage) : nil
        let countdownColor = Self.countdownColor(window.resetsAt, now: now)
        return HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                if remaining > 0 {
                    Circle()
                        .trim(from: 0, to: remaining / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 1) {
                    Text("\(remaining, specifier: "%.0f")%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(l10n["quota_left"])
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(window.label).font(.caption.weight(.medium))
                Text(resetText(window.resetsAt))
                    .font(.caption2).foregroundStyle(.secondary)
                if let countdown {
                    Text(countdown)
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(countdownColor)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue("\(remaining.formatted(.number.precision(.fractionLength(0))))% \(l10n["quota_left"]), \(resetText(window.resetsAt))\(countdown.map { ", \($0)" } ?? "")")
    }

    static func countdownColor(_ value: String?, now: Date) -> Color {
        guard let date = AccountQuotaTimestamp.parse(value) else { return .white.opacity(0.8) }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 86_400 { return .red }
        if seconds <= 3 * 86_400 { return .yellow }
        return .white.opacity(0.8)
    }

    static func countdownText(_ value: String?, now: Date, language: String) -> String? {
        guard let date = AccountQuotaTimestamp.parse(value) else { return nil }
        let seconds = date.timeIntervalSince(now)
        let key: String
        let arguments: [CVarArg]
        if seconds <= 0 {
            key = "quota_reset_due"
            arguments = []
        } else if seconds < 60 {
            key = "quota_reset_soon"
            arguments = []
        } else {
            let minutes = Int(seconds / 60)
            if minutes >= 1_440 {
                key = "quota_countdown_days"
                arguments = [minutes / 1_440, (minutes % 1_440) / 60]
            } else if minutes >= 60 {
                key = "quota_countdown_hours"
                arguments = [minutes / 60, minutes % 60]
            } else {
                key = "quota_countdown_minutes"
                arguments = [minutes]
            }
        }
        let format = L10n.strings[language]?[key] ?? L10n.strings["en"]?[key] ?? key
        return String(format: format, arguments: arguments)
    }

    private func resetText(_ value: String?) -> String {
        guard let date = AccountQuotaTimestamp.parse(value) else { return "—" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}

private struct QuotaProviderIcon: View {
    let provider: String
    let size: CGFloat

    private static let images: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for provider in ["claude", "codex"] {
            if let url = Bundle.appModule.url(forResource: provider, withExtension: "png",
                                             subdirectory: "Resources/quota-icons"),
               let image = NSImage(contentsOf: url) {
                images[provider] = image
            }
        }
        return images
    }()

    var body: some View {
        Group {
            if let image = Self.images[provider] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "terminal").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.capitalized)
        .help(provider.capitalized)
    }
}
