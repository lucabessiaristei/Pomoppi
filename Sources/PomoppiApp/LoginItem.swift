import Foundation
import ServiceManagement

// "Open Pomoppi when I log in" (SPEC.md §7). Unlike lib/login-item.js's dual
// mechanism (a Login Items entry via System Events, with a LaunchAgent
// fallback when Automation permission is refused), this only needs
// SMAppService: the JS version's fallback dance existed specifically
// because Electron's own app.setLoginItemSettings registers whatever bundle
// the process happens to be running from, which for an unpackaged dev
// checkout is always the shared Electron binary, not Pomoppi.app.
// SMAppService.mainApp instead always refers to *this* app's own bundle —
// exactly what's wanted — and needs no Automation permission at all.
//
// Only meaningful when running from a real, installed .app bundle: a raw
// `swift run`/`.build/debug/PomoppiApp` binary has no stable bundle
// identity for SMAppService to register, so `apply` becomes a no-op (returns
// success without doing anything) outside of a bundle.
public enum LoginItem {
    public static func apply(enabled: Bool) -> Result<Void, Error> {
        guard Bundle.main.bundleIdentifier != nil else {
            // Unbundled dev binary — nothing meaningful to register.
            return .success(())
        }
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
