import AppKit
import CoreLocation

/// Location access, used only so macOS reveals the Wi-Fi network name. No location is ever read.
@MainActor
@Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus

    override private init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var granted: Bool { status == .authorizedAlways || status == .authorized }
    var undecided: Bool { status == .notDetermined }

    /// Explains why once, then shows the system prompt. Does nothing once the user has decided.
    func requestIfNeeded() {
        guard undecided, CLLocationManager.locationServicesEnabled(), PermissionPrimer.ensure(.location) else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// For "Show network names" after a decline: the choice can only be changed in System Settings.
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}
