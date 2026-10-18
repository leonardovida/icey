//
//  MenuBarSearchModel.swift
//  Ice
//

import Cocoa
import Combine
import Ifrit

@MainActor
final class MenuBarSearchModel: ObservableObject {
    enum ItemID: Hashable {
        case header(MenuBarSection.Name)
        case item(MenuBarItemTag)
    }

    @Published var searchText = ""
    @Published var displayedItems = [SectionedListItem<ItemID>]()
    @Published var selection: ItemID?
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// The display of the latest average color update.
    ///
    /// The panel captures the color itself before it appears, or moves to
    /// another display. The observer below captures it again only when the
    /// visible panel is on a display that it was not captured for.
    private var averageColorDisplayID: CGDirectDisplayID?

    /// The number of average color updates started so far.
    ///
    /// The captures run off the main thread. Each update is numbered when it
    /// starts, and sets its color only if no later update has set its own
    /// already, so an older capture that finishes last does not replace a
    /// newer color.
    private var averageColorRequestCount = 0

    /// The number of the update that set ``averageColorInfo``.
    private var averageColorRequest = 0

    private var cancellables = Set<AnyCancellable>()

    let fuse = Fuse(threshold: 0.5)

    func performSetup(with panel: MenuBarSearchPanel) {
        configureCancellables(with: panel)
    }

    private func configureCancellables(with panel: MenuBarSearchPanel) {
        var c = Set<AnyCancellable>()

        Publishers.CombineLatest(
            panel.publisher(for: \.screen),
            panel.publisher(for: \.isVisible)
        )
        .compactMap { screen, isVisible in
            isVisible ? screen : nil
        }
        .sink { [weak self] screen in
            guard let self, screen.displayID != averageColorDisplayID else {
                return
            }
            updateAverageColorInfo(for: screen)
        }
        .store(in: &c)

        cancellables = c
    }

    /// Captures the menu bar on the given screen off the main thread, and
    /// sets the average color when the capture ends.
    private func updateAverageColorInfo(for screen: NSScreen) {
        let displayID = screen.displayID
        averageColorDisplayID = displayID
        averageColorRequestCount += 1
        let request = averageColorRequestCount
        Task {
            let color = await ScreenCapture.menuBarAverageColor(for: displayID)
            setAverageColor(color, request: request)
        }
    }

    /// Starts a capture of the menu bar's average color on the given screen,
    /// off the main thread, for the panel that is about to appear there.
    ///
    /// Pass its color to ``setAverageColor(_:for:)``.
    func captureAverageColor(for screen: NSScreen) -> Task<CGColor?, Never> {
        let displayID = screen.displayID
        return Task {
            await ScreenCapture.menuBarAverageColor(for: displayID)
        }
    }

    /// Sets the average color from ``captureAverageColor(for:)``, for the
    /// panel that is about to appear on the given screen.
    ///
    /// The color counts as captured now, as the panel's capture always was,
    /// so an update started while it was taken cannot replace it. Pass `nil`
    /// to keep the previous color, as a failed capture does.
    func setAverageColor(_ color: CGColor?, for screen: NSScreen) {
        averageColorDisplayID = screen.displayID
        averageColorRequestCount += 1
        setAverageColor(color, request: averageColorRequestCount)
    }

    /// Sets the average color from the given update, unless its capture
    /// failed or a later update set its color first.
    private func setAverageColor(_ color: CGColor?, request: Int) {
        guard let color, request > averageColorRequest else {
            return
        }

        averageColorRequest = request

        let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }
}
