import CoreLocation
import Foundation

/// Where the phone is, as a phrase Hermes can use — "Louisville, Kentucky".
/// Hermes runs on a Mac in one place; without this, "weather here" and
/// "flights home" needed the city said out loud every time. Coarse on
/// purpose: a city is all the prompt needs, and it is cached so the first
/// turn after launch has it before a fresh fix arrives.
@MainActor
@Observable
final class PlaceContext: NSObject, CLLocationManagerDelegate {
    private(set) var spokenDescription: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var resolvedAt: Date?
    private var isResolving = false
    private static let cacheKey = "hermesPlaceDescription"
    private static let maxAge: TimeInterval = 15 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        spokenDescription = UserDefaults.standard.string(forKey: Self.cacheKey)
    }

    /// Starts a fix (asking permission the first time). Never blocks: the
    /// description updates when the fix lands, and the cached one serves
    /// until then.
    func refresh() {
        if let resolvedAt, Date().timeIntervalSince(resolvedAt) < Self.maxAge { return }
        guard !isResolving else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            isResolving = true
            manager.requestLocation()
        default:
            return
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard [.authorizedWhenInUse, .authorizedAlways].contains(self.manager.authorizationStatus),
                  !self.isResolving
            else { return }
            self.isResolving = true
            self.manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in await self.resolve(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.isResolving = false
            AgentTurnLog.note("location unavailable: \(message)")
        }
    }

    private func resolve(_ location: CLLocation) async {
        defer { isResolving = false }
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first,
              let description = Self.describe(placemark)
        else { return }
        spokenDescription = description
        resolvedAt = Date()
        UserDefaults.standard.set(description, forKey: Self.cacheKey)
        AgentTurnLog.note("place: \(description)")
    }

    /// "Louisville, Kentucky"; falls back to the county or the country so a
    /// rural fix still says something useful.
    static func describe(_ placemark: CLPlacemark) -> String? {
        let parts = [placemark.locality ?? placemark.subAdministrativeArea, placemark.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return placemark.country }
        return parts.joined(separator: ", ")
    }
}
