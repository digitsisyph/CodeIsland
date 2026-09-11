import AppKit
import SwiftUI
import CodeIslandCore

@MainActor
final class AccountQuotaMonitor: ObservableObject {
    static let shared = AccountQuotaMonitor()
    @Published private(set) var snapshot: AccountQuotaSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?

    func refresh() async {
        guard !isRefreshing else { return }
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
            error = nil
        } catch {
            self.error = "The account core returned an unreadable snapshot."
        }
    }
}

struct AccountQuotaView: View {
    @ObservedObject private var monitor = AccountQuotaMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Accounts & quota", systemImage: "gauge.with.needle")
                    .font(.headline)
                Spacer()
                if monitor.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await monitor.refresh() } }
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
            Text("Remaining quota · reset times in your local timezone · refresh every minute while open")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 320)
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
            ForEach(account.windows) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(window.label)
                        Spacer()
                        Text("\(window.remainingPercent, specifier: "%.0f")% left")
                            .monospacedDigit()
                        Text(resetText(window.resetsAt)).foregroundStyle(.secondary)
                    }.font(.caption)
                    ProgressView(value: max(0, min(100, window.remainingPercent)), total: 100)
                        .tint(window.remainingPercent < 20 ? .orange : .green)
                }
            }
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

    private func resetText(_ value: String?) -> String {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return "—" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}

@MainActor
final class AccountQuotaWindowController: NSObject, NSWindowDelegate {
    static let shared = AccountQuotaWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 650),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            created.title = "CodeIsland · Accounts & quota"
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        // A fresh hosting view gives the polling task the window's lifetime.
        window?.contentView = NSHostingView(rootView: AccountQuotaView())
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }
}
