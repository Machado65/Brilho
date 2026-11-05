// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreLocation

/// Where the Mac is, once, for the sunset times: through Location Services,
/// which ask the user the first time.
final class Locator: NSObject, CLLocationManagerDelegate {
    enum Problem: Error { case denied }

    private let manager = CLLocationManager()
    private let done: (Result<CLLocation, Error>) -> Void
    private var waiting = false

    init(done: @escaping (Result<CLLocation, Error>) -> Void) {
        self.done = done
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func locate() {
        waiting = true
        step()
    }

    private func step() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization() // goes on in locationManagerDidChangeAuthorization
        case .denied, .restricted: finish(.failure(Problem.denied))
        default: manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        if waiting, manager.authorizationStatus != .notDetermined { step() }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if waiting, let location = locations.last { finish(.success(location)) }
    }

    func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        if waiting { finish(.failure(error)) }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        waiting = false
        done(result)
    }

    static func describe(_ error: Error) -> String {
        if case Problem.denied = error { return "Location is off for Brilho: System Settings > Privacy & Security > Location Services" }
        switch (error as? CLError)?.code {
        case .denied: return "Location is off for Brilho: System Settings > Privacy & Security > Location Services"
        case .locationUnknown: return "Couldn't find the location just now; try again in a moment"
        default: return error.localizedDescription
        }
    }
}
