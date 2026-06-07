import SwiftUI
import CoreLocation
import PanelKit

/// Weather: a glanceable current-conditions card (big temperature, condition,
/// place + time, hi/lo) that expands in the tab to an hourly strip — SuperIsland's
/// compact→expanded shape. Data is Open-Meteo (free, no key), location is
/// CoreLocation, the place name is reverse-geocoded. No condition backgrounds by
/// design — it sits on the plain glass card. Access is requested only when shown.
@MainActor
public final class WeatherModule: NotchModule {
    public let id = "weather"
    public let title = "Weather"
    public let icon = "cloud.sun.fill"
    public var onIdleChange: (() -> Void)?

    let manager = WeatherManager()

    public init() {}

    public func expandedView() -> AnyView {
        AnyView(GlassCard(padding: 11) { WeatherContent(manager: manager, compact: false) })
    }
}

// MARK: - Manager

@MainActor
public final class WeatherManager: NSObject, ObservableObject {
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var place: String = ""
    @Published private(set) var denied = false

    private let loc = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var timer: Timer?
    private var started = false

    /// Idempotent; the view drives this on appear/disappear.
    func start() {
        guard !started else { return }
        started = true
        loc.delegate = self
        loc.desiredAccuracy = kCLLocationAccuracyKilometer

        // Stale-while-revalidate: the slow part is CoreLocation's fix handshake,
        // NOT the Open-Meteo call. So paint the last snapshot at once and fire a
        // fetch from the last-known coordinate immediately — the fresh fix from
        // `request()` then corrects coordinate/place in the background.
        if let cached = loadCache() {
            if snapshot == nil { snapshot = cached.snap; place = cached.place }
            Task { await fetch(.init(latitude: cached.lat, longitude: cached.lon)) }
        } else if let c = loc.location?.coordinate {
            Task { await fetch(c) }
        }

        request()
        // Refresh every 10 min while shown.
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.request() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate(); timer = nil
    }

    func request() {
        switch loc.authorizationStatus {
        case .notDetermined: loc.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = true
        default: denied = false; loc.requestLocation()
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(_ coord: CLLocationCoordinate2D) {
        // Name the place (best-effort; the card still works without it).
        geocoder.reverseGeocodeLocation(CLLocation(latitude: coord.latitude, longitude: coord.longitude)) { [weak self] marks, _ in
            let name = marks?.first?.locality ?? marks?.first?.administrativeArea
            guard let name else { return }
            Task { @MainActor in
                guard let self else { return }
                self.place = name
                // Fold the resolved place back into the cache so the next launch
                // shows the right city name instantly.
                if let s = self.snapshot { self.saveCache(s, coord) }
            }
        }
        Task { await fetch(coord) }
    }

    private func fetch(_ coord: CLLocationCoordinate2D) async {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(coord.latitude)),
            .init(name: "longitude", value: String(coord.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day,apparent_temperature,relative_humidity_2m,wind_speed_10m,uv_index"),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "forecast_days", value: "2"),
        ]
        guard let url = comps.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let om = try JSONDecoder().decode(OMResponse.self, from: data)
            let now = Date().timeIntervalSince1970 - 1800        // keep the current hour
            let hours = zip(zip(om.hourly.time, om.hourly.temperature_2m), om.hourly.weather_code)
                .map { WeatherSnapshot.Hour(at: Date(timeIntervalSince1970: TimeInterval($0.0.0)),
                                            tempC: $0.0.1, code: $0.1) }
                .filter { $0.at.timeIntervalSince1970 >= now }
                .prefix(10)
            let snap = WeatherSnapshot(
                tempC: om.current.temperature_2m,
                code: om.current.weather_code,
                isDay: om.current.is_day == 1,
                highC: om.daily.temperature_2m_max.first ?? om.current.temperature_2m,
                lowC: om.daily.temperature_2m_min.first ?? om.current.temperature_2m,
                feelsC: om.current.apparent_temperature,
                humidity: Int(om.current.relative_humidity_2m.rounded()),
                windKmh: om.current.wind_speed_10m,
                uv: om.current.uv_index,
                aqi: nil,
                hourly: Array(hours))
            await MainActor.run { self.snapshot = snap }
            saveCache(snap, coord)
            await fetchAQI(coord)
        } catch {
            notchLog("weather fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache (stale-while-revalidate)

    private let cacheKey = "weatherCache"
    private struct Cache: Codable { var snap: WeatherSnapshot; var place: String; var lat: Double; var lon: Double; var at: Date }

    private func saveCache(_ snap: WeatherSnapshot, _ coord: CLLocationCoordinate2D) {
        let c = Cache(snap: snap, place: place, lat: coord.latitude, lon: coord.longitude, at: Date())
        if let data = try? JSONEncoder().encode(c) { NotchKit.settingsDefaults.set(data, forKey: cacheKey) }
    }

    private func loadCache() -> Cache? {
        guard let data = NotchKit.settingsDefaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    /// Air quality is a separate Open-Meteo endpoint; fetched best-effort and
    /// merged in, so the card never blocks on it.
    private func fetchAQI(_ coord: CLLocationCoordinate2D) async {
        var comps = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        comps.queryItems = [
            .init(name: "latitude", value: String(coord.latitude)),
            .init(name: "longitude", value: String(coord.longitude)),
            .init(name: "current", value: "us_aqi"),
        ]
        guard let url = comps.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let aq = try JSONDecoder().decode(AQResponse.self, from: data)
            await MainActor.run { self.snapshot?.aqi = aq.current.us_aqi }
        } catch {
            notchLog("aqi fetch failed: \(error.localizedDescription)")
        }
    }
}

extension WeatherManager: CLLocationManagerDelegate {
    public nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        Task { @MainActor in self.handle(c) }
    }
    public nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        notchLog("weather location failed: \(error.localizedDescription)")
    }
    public nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.request() }
    }
}

// MARK: - Model

struct WeatherSnapshot: Codable {
    var tempC: Double
    var code: Int
    var isDay: Bool
    var highC: Double
    var lowC: Double
    var feelsC: Double
    var humidity: Int
    var windKmh: Double
    var uv: Double
    var aqi: Int?
    var hourly: [Hour]

    struct Hour: Identifiable, Codable {
        var id = UUID()
        let at: Date
        let tempC: Double
        let code: Int
    }
}

private struct OMResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
        let is_day: Int
        let apparent_temperature: Double
        let relative_humidity_2m: Double
        let wind_speed_10m: Double
        let uv_index: Double
    }
    struct Hourly: Decodable { let time: [Int]; let temperature_2m: [Double]; let weather_code: [Int] }
    struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
    let current: Current
    let hourly: Hourly
    let daily: Daily
}

private struct AQResponse: Decodable {
    struct Current: Decodable { let us_aqi: Int? }
    let current: Current
}

/// WMO weather-code → words + SF Symbol (day/night aware).
enum WMO {
    static func text(_ code: Int) -> String {
        switch code {
        case 0: return "Clear Skies"
        case 1: return "Mainly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Rain Showers"
        case 85, 86: return "Snow Showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm"
        default: return "—"
        }
    }

    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0, 1: return day ? "sun.max.fill" : "moon.stars.fill"
        case 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "thermometer.medium"
        }
    }
}

// MARK: - View

struct WeatherContent: View {
    @ObservedObject var manager: WeatherManager
    /// Compact = the Home slot (current only); full = the tab (adds the hourly strip).
    var compact: Bool

    var body: some View {
        Group {
            if manager.denied {
                prompt
            } else if let snap = manager.snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    if compact { current(snap, now: ctx.date) }
                    else { full(snap, now: ctx.date) }
                }
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.start() }
        .onDisappear { manager.stop() }
    }

    // The current-conditions block (the Home slot).
    private func current(_ snap: WeatherSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                HStack(alignment: .top, spacing: 1) {
                    Text("\(Int(snap.tempC.rounded()))")
                        .font(.system(size: 42, weight: .medium))
                    Text("°C")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 5)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(manager.place.isEmpty ? "—" : manager.place)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(now, format: .dateTime.hour().minute())
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 4)
            HStack(alignment: .bottom) {
                Text(WMO.text(snap.code))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                Text("H:\(Int(snap.highC.rounded()))°  L:\(Int(snap.lowC.rounded()))°")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    // The full tab: current + H/L up top, a divider, then hourly on the left and a
    // metrics grid (feels / humidity / aqi / wind / uv) on the right.
    private func full(_ snap: WeatherSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: WMO.symbol(snap.code, day: snap.isDay))
                    .font(.system(size: 30))
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .top, spacing: 1) {
                        Text("\(Int(snap.tempC.rounded()))")
                            .font(.system(size: 30, weight: .medium))
                        Text("°C").font(.system(size: 12, weight: .semibold)).padding(.top, 3)
                    }
                    .foregroundStyle(.white)
                    Text("\(WMO.text(snap.code)) · \(manager.place.isEmpty ? "—" : manager.place)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(now, format: .dateTime.hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Text("H:\(Int(snap.highC.rounded()))°").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    Text("L:\(Int(snap.lowC.rounded()))°").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Divider().overlay(Color.white.opacity(0.12))
            HStack(alignment: .center, spacing: 14) {
                hourly(snap)
                Spacer(minLength: 0)
                metrics(snap)
            }
        }
    }

    // The expanded hourly strip (next several hours).
    private func hourly(_ snap: WeatherSnapshot) -> some View {
        HStack(spacing: 9) {
            ForEach(snap.hourly.prefix(6)) { h in
                VStack(spacing: 2) {
                    Text(h.at, format: .dateTime.hour())
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Image(systemName: WMO.symbol(h.code, day: isDay(h.at)))
                        .font(.system(size: 12))
                        .symbolRenderingMode(.multicolor)
                        .frame(height: 15)
                    Text("\(Int(h.tempC.rounded()))°")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .fixedSize()
    }

    // The metrics grid on the right of the expanded tab.
    private func metrics(_ snap: WeatherSnapshot) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                metric("thermometer.medium", "Feels", "\(Int(snap.feelsC.rounded()))°")
                metric("humidity.fill", "Humidity", "\(snap.humidity)%")
                metric("aqi.medium", "AQI", snap.aqi.map(String.init) ?? "—")
            }
            GridRow {
                metric("wind", "Wind", "\(Int(snap.windKmh.rounded())) km/h")
                metric("sun.max.fill", "UV", "\(Int(snap.uv.rounded()))")
                Color.clear.frame(height: 1)
            }
        }
        .fixedSize()
    }

    private func metric(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            }
        }
    }

    /// Rough day/night for an hour's icon (06:00–19:00 local = day).
    private func isDay(_ date: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: date)
        return h >= 6 && h < 19
    }

    private var prompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.panelAccent)
            Button("Enable Location for Weather") { manager.openSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
