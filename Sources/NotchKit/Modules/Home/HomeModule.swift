import SwiftUI
import Combine
import PanelKit

/// The Home tab: the music player (left, flexible) plus the configurable slot on
/// the right — the webcam mirror by default. Owns the now-playing manager, so it
/// also drives the idle peeks (album art + visualizer) beside the cutout.
@MainActor
public final class HomeModule: NotchModule {
    public let id = "home"
    public let title = "Home"
    public let icon = "house.fill"
    /// High — when something's playing, Home owns the idle peek.
    public let idlePriority = 100
    public var onIdleChange: (() -> Void)?

    let nowPlaying = NowPlayingManager()
    private var cancellable: AnyCancellable?

    public var wantsIdle: Bool { nowPlaying.track != nil }

    public init() {
        cancellable = nowPlaying.$track
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in self?.onIdleChange?() }
    }

    public func activate() { nowPlaying.start() }
    public func deactivate() { nowPlaying.stop() }

    /// A small store for the Home shelf slot (separate from the Shelf tab).
    let homeShelfStore = ShelfStore()
    /// A calendar manager for the Home calendar slot (separate from the Calendar
    /// tab; self-starts only when the slot is shown, so it never prompts early).
    let calendarManager = CalendarManager()
    /// Likewise a weather manager for the Home weather slot.
    let weatherManager = WeatherManager()

    public func leftPeek() -> AnyView { AnyView(NowPlayingPeekLeft(manager: nowPlaying)) }
    public func rightPeek() -> AnyView { AnyView(NowPlayingPeekRight(manager: nowPlaying)) }
    public func expandedView() -> AnyView { AnyView(HomeView(home: self)) }
}

/// What the Home tab's right-hand slot shows. `none` hides the slot entirely so
/// the player fills the whole tab (the "player only" layout).
enum HomeSlot: String {
    case camera, calendar, shelf, weather, none
    static var current: HomeSlot {
        HomeSlot(rawValue: NotchKit.settingsDefaults.string(forKey: "notchHomeSlot") ?? "camera") ?? .camera
    }
}

private struct HomeView: View {
    let home: HomeModule
    @ObservedObject var nowPlaying: NowPlayingManager
    @State private var slotDropTargeted = false

    init(home: HomeModule) {
        self.home = home
        self.nowPlaying = home.nowPlaying
    }

    private var isShelfSlot: Bool { HomeSlot.current == .shelf }

    var body: some View {
        HStack(spacing: 10) {
            // Player is a fixed, tighter width when a slot shares the row; with the
            // slot hidden it fills the whole tab so a wide (video) thumbnail and the
            // title get the full width.
            GlassCard(padding: 9, tint: nowPlaying.tint) { NowPlayingPlayer(manager: nowPlaying) }
                .frame(maxWidth: HomeSlot.current == .none ? .infinity : 330)
                .frame(maxHeight: .infinity)
            if HomeSlot.current != .none {
                slotCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var slotCard: some View {
        GlassCard(padding: HomeSlot.current == .camera ? 0 : 9) { slot }
            // For the shelf slot, the drop target lives on the OUTER card (above
            // the glass) — the inner one inside the GlassCard wasn't catching, so
            // home-slot drops failed even though the tab worked.
            .onDrop(of: isShelfSlot ? [.fileURL] : [], isTargeted: $slotDropTargeted) { providers in
                guard isShelfSlot else { return false }
                loadDroppedURLs(providers) { urls in urls.forEach(home.homeShelfStore.add) }
                return true
            }
    }

    @ViewBuilder private var slot: some View {
        switch HomeSlot.current {
        case .camera:   CameraSlot()
        case .calendar: CalendarTimeline(manager: home.calendarManager)
        case .weather:  WeatherContent(manager: home.weatherManager, compact: true)
        // No AirDrop tile, and no inner onDrop — the outer card handles the drop
        // (see `slotCard`); we just pass the targeted state down for the highlight.
        case .shelf:    ShelfExpanded(store: home.homeShelfStore, showAirDrop: false,
                                      handlesOwnDrop: false, externalTargeted: slotDropTargeted)
        case .none:     EmptyView()   // player fills the tab; slotCard isn't rendered
        }
    }
}
