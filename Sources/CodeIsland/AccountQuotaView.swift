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
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let snapshot = monitor.snapshot {
                    Text("Claude \(snapshot.accounts.filter { $0.provider == "claude" }.count) · Codex \(snapshot.accounts.filter { $0.provider == "codex" }.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
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
            if let snapshot = monitor.snapshot {
                if snapshot.accounts.isEmpty {
                    Text("Add accounts in Terminal:\ncodeisland claude add\ncodeisland codex add")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(snapshot.accounts) { account in
                            accountRow(account)
                            Divider()
                        }
                        ForEach(Array(snapshot.errors.enumerated()), id: \.offset) { _, error in
                            Text("\(error.provider): \(error.message)").foregroundStyle(.orange)
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

    private func accountRow(_ account: AccountQuota) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.provider.uppercased()).font(.caption.bold())
                Text(account.email).fontWeight(.semibold).textSelection(.enabled)
                if account.active { Text("Active").font(.caption).foregroundStyle(.green) }
                Spacer()
            }
            Text(account.organization.isEmpty ? "Personal" : account.organization)
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(account.windows.filter {
                    account.provider != "codex" || !$0.label.localizedCaseInsensitiveContains("spark")
                }) { window in
                    quotaRing(window)
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

    private func quotaRing(_ window: AccountQuotaWindow) -> some View {
        let remaining = max(0, min(100, window.remainingPercent))
        let color: Color = remaining < 20 ? .orange : .green
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
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue("\(remaining.formatted(.number.precision(.fractionLength(0))))% \(l10n["quota_left"]), \(resetText(window.resetsAt))")
    }

    private func resetText(_ value: String?) -> String {
        guard let date = AccountQuotaTimestamp.parse(value) else { return "—" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
