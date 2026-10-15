import BetterWMCore
import Cocoa
import CoreLocation

/// Current conditions from Open-Meteo (no API key). Location is a fixed coordinate or Location Services.
final class WeatherService: NSObject, CLLocationManagerDelegate {
    struct Reading { let temperature: Double; let symbol: String; let fahrenheit: Bool }

    var onUpdate: ((Reading?) -> Void)?
    private(set) var reading: Reading?
    private var config: Config
    private var timer: Timer?
    private var locationManager: CLLocationManager?
    private var coordinate: CLLocationCoordinate2D?

    init(config: Config) {
        self.config = config
        super.init()
        apply(config)
    }

    func apply(_ config: Config) {
        self.config = config
        timer?.invalidate()
        guard config.bar, config.barWeather else { reading = nil; onUpdate?(nil); return }
        resolveLocation()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.fetch() }
    }

    private func resolveLocation() {
        let spec = config.barWeatherLocation.lowercased().trimmingCharacters(in: .whitespaces)
        if spec == "auto" {
            if locationManager == nil {
                locationManager = CLLocationManager()
                locationManager?.delegate = self
                locationManager?.desiredAccuracy = kCLLocationAccuracyKilometer
            }
            if CLLocationManager.locationServicesEnabled() {
                locationManager?.requestWhenInUseAuthorization()
                locationManager?.requestLocation()
            }
            return
        }
        let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { reading = nil; onUpdate?(nil); return }
        coordinate = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
        fetch()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        coordinate = c
        fetch()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        print(denied
            ? "Weather: Location Services denied. Run the app bundle (make run / make install), allow BetterWM in System Settings › Privacy & Security › Location Services, or set barWeatherLocation = lat,lon."
            : "Weather: location failed (\(error.localizedDescription)).")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if [.authorizedAlways, .authorized].contains(manager.authorizationStatus) { manager.requestLocation() }
    }

    private func fetch() {
        guard let c = coordinate else { return }
        let unit = config.barWeatherFahrenheit ? "fahrenheit" : "celsius"
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(c.latitude)&longitude=\(c.longitude)&current=temperature_2m,weather_code,is_day&temperature_unit=\(unit)")!
        let fahrenheit = config.barWeatherFahrenheit
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            if let error { print("Weather: \(error.localizedDescription)"); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temp = current["temperature_2m"] as? Double,
                  let code = current["weather_code"] as? Int else { print("Weather: unexpected response"); return }
            let day = (current["is_day"] as? Int ?? 1) == 1
            let r = Reading(temperature: temp, symbol: WeatherService.symbol(for: code, day: day), fahrenheit: fahrenheit)
            DispatchQueue.main.async {
                self?.reading = r
                self?.onUpdate?(r)
            }
        }.resume()
    }

    /// WMO weather interpretation codes → SF Symbols.
    static func symbol(for code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max" : "moon.stars"
        case 1, 2: return day ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55, 56, 57: return "cloud.drizzle"
        case 61, 63, 65, 66, 67: return "cloud.rain"
        case 71, 73, 75, 77: return "cloud.snow"
        case 80, 81, 82: return "cloud.heavyrain"
        case 85, 86: return "cloud.snow"
        case 95, 96, 99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
}
