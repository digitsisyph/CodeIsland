import Combine
import Foundation
import IOKit.pwr_mgt

@MainActor
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager()

    @Published private(set) var isEnabled = false
    @Published private(set) var errorKey: String?
    @Published var keepDisplayAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepDisplayAwake, forKey: SettingsKey.keepDisplayAwake)
            if isEnabled { setEnabled(true) }
        }
    }
    private var assertions: [IOPMAssertionID] = []

    init() {
        keepDisplayAwake = UserDefaults.standard.bool(forKey: SettingsKey.keepDisplayAwake)
    }

    func setEnabled(_ enabled: Bool) {
        stop()
        errorKey = nil
        guard enabled else { return }
        var types = [kIOPMAssertPreventUserIdleSystemSleep]
        if keepDisplayAwake { types.append(kIOPMAssertPreventUserIdleDisplaySleep) }
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "CodeIsland coffee mode" as CFString, &id)
            guard result == kIOReturnSuccess else {
                stop()
                errorKey = "coffee_error"
                return
            }
            assertions.append(id)
        }
        isEnabled = true
    }

    func stop() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
        isEnabled = false
    }
}
