//
//  IceBarColorManager.swift
//  Ice
//

import Combine
import SwiftUI

@MainActor
final class IceBarColorManager: ObservableObject {
    @Published private(set) var colorInfo: MenuBarAverageColorInfo?

    private weak var iceBarPanel: IceBarPanel?

    private var windowImage: CGImage?

    /// The number of window image captures started so far.
    ///
    /// The captures run off the main thread. Each one is numbered when it
    /// starts, and a capture stores its image only if no later one has
    /// stored its own already, so an older capture that finishes last does
    /// not replace a newer image.
    private var windowImageRequestCount = 0

    /// The number of the capture that stored ``windowImage``.
    private var windowImageRequest = 0

    private var cancellables = Set<AnyCancellable>()

    func performSetup(with iceBarPanel: IceBarPanel) {
        self.iceBarPanel = iceBarPanel
        configureCancellables()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let iceBarPanel {
            iceBarPanel.publisher(for: \.screen)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak iceBarPanel] screen in
                    guard
                        let self,
                        let iceBarPanel,
                        // The image is only used while the panel is visible. The panel
                        // captures a fresh image itself right before it is shown.
                        iceBarPanel.isVisible,
                        let screen,
                        screen == .main
                    else {
                        return
                    }
                    updateWindowImage(for: screen)
                }
                .store(in: &c)

            iceBarPanel.publisher(for: \.isVisible)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak iceBarPanel] isVisible in
                    guard
                        let self,
                        let iceBarPanel,
                        let screen = iceBarPanel.screen,
                        isVisible,
                        screen == .main
                    else {
                        return
                    }
                    updateColorInfo(with: iceBarPanel.frame, screen: screen)
                }
                .store(in: &c)

            iceBarPanel.publisher(for: \.frame)
                .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self, weak iceBarPanel] frame in
                    guard
                        let self,
                        let iceBarPanel,
                        let screen = iceBarPanel.screen,
                        iceBarPanel.isVisible,
                        screen == .main
                    else {
                        return
                    }
                    withAnimation(.interactiveSpring) {
                        self.updateColorInfo(with: frame, screen: screen)
                    }
                }
                .store(in: &c)

            Publishers.Merge4(
                NSWorkspace.shared.notificationCenter
                    .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
                    .replace(with: ()),
                NotificationCenter.default
                    .publisher(for: NSApplication.didChangeScreenParametersNotification)
                    .replace(with: ()),
                DistributedNotificationCenter.default()
                    .publisher(for: DistributedNotificationCenter.interfaceThemeChangedNotification)
                    .replace(with: ()),
                // The update below does nothing while the panel is hidden, so the
                // timer only runs while the panel is visible.
                iceBarPanel.publisher(for: \.isVisible)
                    .receive(on: DispatchQueue.main)
                    .map { [weak iceBarPanel] _ in
                        iceBarPanel?.isVisible == true
                    }
                    .removeDuplicates()
                    .map { isVisible -> AnyPublisher<Void, Never> in
                        guard isVisible else {
                            return Empty().eraseToAnyPublisher()
                        }
                        return Timer.publish(every: 5, tolerance: 1, on: .main, in: .default)
                            .autoconnect()
                            .replace(with: ())
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak iceBarPanel] in
                guard
                    let self,
                    let iceBarPanel,
                    // Capturing the menu bar is expensive, and the image is only used
                    // while the panel is visible. The panel captures a fresh image
                    // itself right before it is shown.
                    iceBarPanel.isVisible,
                    let screen = iceBarPanel.screen,
                    screen == .main
                else {
                    return
                }
                let windowImageUpdate = updateWindowImage(for: screen)
                Task {
                    await windowImageUpdate.value
                    // The capture took a moment, so the panel can have closed
                    // or moved to another display since.
                    guard
                        iceBarPanel.isVisible,
                        iceBarPanel.screen == screen
                    else {
                        return
                    }
                    withAnimation {
                        self.updateColorInfo(with: iceBarPanel.frame, screen: screen)
                    }
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    /// Captures the menu bar on the given screen off the main thread, and
    /// stores the image.
    ///
    /// - Returns: A task that finishes once the image is stored, or once the
    ///   capture failed, which keeps the previous image.
    @discardableResult
    private func updateWindowImage(for screen: NSScreen) -> Task<Void, Never> {
        windowImageRequestCount += 1
        let request = windowImageRequestCount
        let displayID = screen.displayID
        return Task {
            let image = await ScreenCapture.menuBarStrip(for: displayID)
            storeWindowImage(image, request: request)
        }
    }

    /// Stores the image of the given capture, unless it failed or a later
    /// capture stored its image first.
    private func storeWindowImage(_ image: CGImage?, request: Int) {
        guard let image, request > windowImageRequest else {
            return
        }
        windowImage = image
        windowImageRequest = request
    }

    /// Starts a capture of the menu bar on the given screen, off the main
    /// thread, for the panel that is about to be shown there.
    ///
    /// Pass its image to ``updateAllProperties(with:screen:windowImage:)``.
    func captureWindowImage(for screen: NSScreen) -> Task<CGImage?, Never> {
        let displayID = screen.displayID
        return Task {
            await ScreenCapture.menuBarStrip(for: displayID)
        }
    }

    private func updateColorInfo(with frame: CGRect, screen: NSScreen) {
        guard let image = windowImage else {
            return
        }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        let insetScreenFrame = screen.frame.insetBy(dx: frame.width / 2, dy: 0)
        let percentage = ((frame.midX - insetScreenFrame.minX) / insetScreenFrame.width).clamped(to: 0...1)

        let cropRect = CGRect(x: imageBounds.width * percentage, y: 0, width: 0, height: 1)
            .insetBy(dx: -150, dy: 0)
            .intersection(imageBounds)

        guard
            let croppedImage = image.cropping(to: cropRect),
            let averageColor = croppedImage.averageColor()
        else {
            return
        }

        // Just use `menuBarWindow` as the source for now, regardless
        // of whether its image contributed to the average.
        let info = MenuBarAverageColorInfo(color: averageColor, source: .menuBarWindow)

        // Assigning an equal colour redrew the Ice Bar every few seconds.
        if colorInfo != info {
            colorInfo = info
        }
    }

    func updateAllProperties(with frame: CGRect, screen: NSScreen) {
        updateAllProperties(with: frame, screen: screen, windowImage: ScreenCapture.captureMenuBarStrip(for: screen.displayID))
    }

    /// Updates the color for the panel that is about to be shown, using an
    /// image from ``captureWindowImage(for:)``.
    ///
    /// The image counts as captured now, as the panel's own capture always
    /// was, so a capture started while it was taken cannot replace it. Pass
    /// `nil` to keep the previous image, as a failed capture does.
    func updateAllProperties(with frame: CGRect, screen: NSScreen, windowImage image: CGImage?) {
        windowImageRequestCount += 1
        storeWindowImage(image, request: windowImageRequestCount)
        updateColorInfo(with: frame, screen: screen)
    }

    /// One flat colour for macOS 27, where the menu bar window cannot be captured.
    ///
    /// Item images are cut out of a capture of the bar, so a colour read off the bar
    /// would only match the moment of that capture: when a dark window later sits under
    /// the menu bar, or the Ice Bar opens on the other display, the panel and the items
    /// disagree. A flat colour that follows the system appearance always agrees with the
    /// glyphs, which the capture takes in that same appearance.
    static func flatColor27() -> CGColor {
        var color = NSColor.windowBackgroundColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        return color.cgColor
    }

    /// Sets the flat macOS 27 colour.
    func setColor27() {
        colorInfo = MenuBarAverageColorInfo(color: Self.flatColor27(), source: .menuBarWindow)
    }
}
