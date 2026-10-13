import Foundation
import Observation
import ServiceManagement
import UPSKit

/// Registro del daemon root con `SMAppService` y su estado de aprobación.
@MainActor @Observable
final class DaemonController {
    enum State: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound
    }

    private(set) var state: State = .notRegistered
    private(set) var lastError: String?

    /// `com.xreq403.UPSForza.daemon` o `com.xreq403.UPSForza.debug.daemon`.
    let label = DaemonIdentity.label(forAppBundleID: Bundle.main.bundleIdentifier ?? "com.xreq403.UPSForza")

    private var service: SMAppService { SMAppService.daemon(plistName: "\(label).plist") }

    init() { refresh() }

    var isEnabled: Bool { state == .enabled }

    func refresh() {
        state = switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
        if state == .enabled { lastError = nil }
    }

    /// Registra el daemon. La primera vez macOS pide aprobarlo en
    /// Ajustes del Sistema → General → Ítems de inicio.
    func register() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        // La primera vez register() falla con "Operation not permitted" porque falta
        // la aprobación del usuario: es esperable, no un error.
        if state == .requiresApproval {
            lastError = nil
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func unregister() async {
        do {
            try await service.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
