//
//  IceWindow.swift
//  Ice
//

import Combine
import SwiftUI

// MARK: - IceWindow

/// A custom scene representing one of Ice's windows.
struct IceWindow<Content: View>: Scene {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// The window's identifier.
    let id: IceWindowIdentifier

    /// The window's content view.
    let content: Content

    /// Creates a window with an identifier constant.
    ///
    /// - Parameters:
    ///   - id: A custom identifier constant.
    ///   - content: The content view to display in the window.
    init(id: IceWindowIdentifier, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    var body: some Scene {
        windowScene.once {
            // SwiftUI waits to create the underlying NSWindow until the scene
            // is first presented. We may need a valid window reference before
            // that point, so we open the window and immediately dismiss it.
            //
            // - Note: Both actions are called during the same run loop cycle,
            //   so the window isn't actually opened.
            openWindow(id: id)
            dismissWindow(id: id)
        }
    }

    @ViewBuilder
    private var windowContentView: some View {
        content.onWindowChange { window in
            window?.collectionBehavior.insert(.moveToActiveSpace)
        }
    }

    private var windowScene: some Scene {
        if #available(macOS 15.0, *) {
            return windowSceneModern
        } else {
            return windowSceneLegacy
        }
    }

    @available(macOS 15.0, *)
    private var windowSceneModern: some Scene {
        Window(id.titleKey, id: id.rawValue) {
            windowContentView
        }
        .defaultLaunchBehavior(.suppressed)
    }

    private var windowSceneLegacy: some Scene {
        Window(id.titleKey, id: id.rawValue) {
            windowContentView.once {
                // On launch, SwiftUI tries to show the first scene provided
                // to the app. Override this behavior and dismiss the window
                // the first time it is shown.
                dismissWindow(id: id)
            }
        }
    }
}

// MARK: - IceWindowIdentifier

/// Custom identifier constants uses to create Ice's windows.
enum IceWindowIdentifier: String, Sendable, CustomStringConvertible {
    /// The identifier for Ice's main settings window.
    case settings = "SettingsWindow"

    /// The identifier for Ice's permissions window.
    case permissions = "PermissionsWindow"

    /// The non-localized title of the corresponding window.
    ///
    /// - Note: Use ``titleKey`` to get the localized title.
    var titleString: String {
        switch self {
        case .settings: "Icey"
        case .permissions: "Permissions"
        }
    }

    /// The localized title of the corresponding window.
    ///
    /// - Note: Use ``titleString`` to get the non-localized title.
    var titleKey: LocalizedStringKey {
        switch self {
        case .settings: "Icey"
        case .permissions: "Permissions"
        }
    }

    /// A textual representation of the identifier.
    var description: String {
        rawValue
    }
}

// MARK: - Window Content

extension IceWindowIdentifier {
    /// Requests to build the content of a closed window.
    @MainActor
    fileprivate static let contentRequests = PassthroughSubject<IceWindowIdentifier, Never>()

    /// Builds the content of the corresponding window while the window
    /// is still closed.
    ///
    /// A window's content is built when the window opens. Call this
    /// before opening the window after a delay, so the work is done
    /// during the delay and the window can show its content at once.
    @MainActor
    func prepareContent() {
        Self.contentRequests.send(self)
    }

    /// Whether the window's content is built when SwiftUI creates the
    /// window at launch, before the window first opens.
    ///
    /// The permissions window takes its size from its content, so it
    /// needs the content when it is created to get its size and position
    /// on first open. The settings window gets its default size and size
    /// limits from outside the content, so its content waits until the
    /// window opens.
    fileprivate var buildsContentWhenCreated: Bool {
        switch self {
        case .settings: false
        case .permissions: true
        }
    }
}

/// A modifier that keeps a view in the view tree only while its window
/// is open.
///
/// A closed SwiftUI window keeps its view tree, and the tree is updated,
/// laid out and drawn on every change to the state it observes, though
/// nobody sees it. While the window is closed, this modifier puts a clear
/// view that takes any size in place of the content, so the window keeps
/// its frame, and the content is built again when the window opens.
private struct IceWindowContentModifier: ViewModifier {
    @State private var isPresented: Bool
    @State private var cancellable: AnyCancellable?

    let id: IceWindowIdentifier

    init(id: IceWindowIdentifier) {
        self.id = id
        self._isPresented = State(initialValue: id.buildsContentWhenCreated)
    }

    func body(content: Content) -> some View {
        ZStack {
            if isPresented {
                content
            } else {
                Color.clear
            }
        }
        .onWindowChange { window in
            guard let window else {
                cancellable = nil
                return
            }
            cancellable = window.publisher(for: \.isVisible)
                .merge(with: IceWindowIdentifier.contentRequests.filter { $0 == id }.map { _ in true })
                .map { [weak window] isShown in
                    if isShown {
                        return Just(true).eraseToAnyPublisher()
                    }
                    // SwiftUI orders a window out and back in while opening it,
                    // so check again after a pause. A minimized window is not
                    // visible, but keeps its content.
                    let isOpen = { [weak window] in
                        window.map { $0.isVisible || $0.isMiniaturized } ?? false
                    }
                    return Just(())
                        .delay(for: 1, scheduler: DispatchQueue.main)
                        .flatMap { _ -> AnyPublisher<Bool, Never> in
                            guard !isOpen(), NSApp.isHidden else {
                                return Just(isOpen()).eraseToAnyPublisher()
                            }
                            // The windows of a hidden app aren't visible either.
                            // Keep the content until the app is unhidden, then
                            // check again.
                            return NotificationCenter.default
                                .publisher(for: NSApplication.didUnhideNotification)
                                .first()
                                .delay(for: 1, scheduler: DispatchQueue.main)
                                .map { _ in isOpen() }
                                .prepend(true)
                                .eraseToAnyPublisher()
                        }
                        .eraseToAnyPublisher()
                }
                .switchToLatest()
                .removeDuplicates()
                .sink { isOpen in
                    isPresented = isOpen
                }
        }
    }
}

extension View {
    /// Keeps the view in the view tree only while the window with the
    /// given identifier is open.
    ///
    /// Apply this to the content of an ``IceWindow``, inside the modifiers
    /// that configure the window or set its size limits, so that those
    /// keep running once and keep applying while the window is closed.
    ///
    /// - Parameter id: The identifier of the view's window.
    func presentedWhileWindowIsOpen(_ id: IceWindowIdentifier) -> some View {
        modifier(IceWindowContentModifier(id: id))
    }
}

// MARK: - OpenWindowAction

extension OpenWindowAction {
    /// Opens the corresponding window for the given identifier.
    ///
    /// - Parameter id: An identifier for one of Ice's windows.
    func callAsFunction(id: IceWindowIdentifier) {
        callAsFunction(id: id.rawValue)
    }
}

// MARK: - DismissWindowAction

extension DismissWindowAction {
    /// Dismisses the corresponding window for the given identifier.
    ///
    /// - Parameter id: An identifier for one of Ice's windows.
    func callAsFunction(id: IceWindowIdentifier) {
        callAsFunction(id: id.rawValue)
    }
}
