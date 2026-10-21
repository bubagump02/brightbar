import Foundation
import ServiceManagement

/// Opens BrightBar at login through SMAppService (the app itself as login
/// item). The registration points at this bundle's path, so it is meant for
/// the copy installed by scripts/install.sh, not the rebuilt build/ one.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var enabled = false
    /// macOS wants the user to allow it in System Settings → Login Items.
    @Published private(set) var needsApproval = false
    @Published private(set) var error: String?

    init() {
        // On by default: enable once on the first launch from the installed copy.
        if !UserDefaults.standard.bool(forKey: "launchAtLoginInitialized"), isInstalled {
            UserDefaults.standard.set(true, forKey: "launchAtLoginInitialized")
            set(true)
        }
        refresh()
    }

    /// Running from /Applications (or ~/Applications), not from the build folder.
    var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
            || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
