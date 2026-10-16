import AppKit
import SwiftUI

extension Notification.Name {
    static let focusFSearch = Notification.Name("focusFSearch")
}

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon")
            applyActivationPolicy()
        }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }
    @Published private(set) var shortcut: GlobalShortcut
    @Published private(set) var shortcutError: String?
    var shutdown: (() async -> Void)?
    var openSearch: (() -> Void)?
    private weak var searchWindow: NSWindow?
    private var openingSearchWindow = false
    private var terminating = false
    private let registration = GlobalShortcutRegistration()

    override init() {
        let defaults = UserDefaults.standard
        showDockIcon = defaults.object(forKey: "showDockIcon") as? Bool ?? true
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        shortcut = defaults.data(forKey: "globalShortcut")
            .flatMap { try? JSONDecoder().decode(GlobalShortcut.self, from: $0) } ?? .defaultShortcut
        super.init()
        registration.onInvoke = { [weak self] in
            Task { @MainActor in self?.toggleSearch() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        applyActivationPolicy()
        resumeShortcut()
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        // Changing activation policy may resign the settings window.
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSearch() {
        if let searchWindow {
            if searchWindow.isMiniaturized { searchWindow.deminiaturize(nil) }
            searchWindow.makeKeyAndOrderFront(nil)
        } else if !openingSearchWindow, let openSearch {
            // Repeated hot keys must not queue multiple window openings.
            openingSearchWindow = true
            openSearch()
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .focusFSearch, object: nil)
        }
    }

    func hideSearch() {
        searchWindow?.orderOut(nil)
    }

    func toggleSearch() {
        if let searchWindow, searchWindow.isVisible, !searchWindow.isMiniaturized, !NSApp.isHidden {
            hideSearch()
        } else {
            showSearch()
        }
    }

    func registerSearchWindow(_ window: NSWindow) {
        searchWindow = window
        openingSearchWindow = false
        window.tabbingMode = .disallowed
    }

    func unregisterSearchWindow(_ window: NSWindow) {
        if searchWindow === window { searchWindow = nil }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSearch()
        return false
    }

    func suspendShortcut() { registration.unregister() }

    func resumeShortcut() {
        if registration.register(shortcut) { shortcutError = nil }
        else { shortcutError = "This shortcut could not be registered. It may be used by another app. Choose a different shortcut." }
    }

    @discardableResult
    func updateShortcut(_ candidate: GlobalShortcut) -> Bool {
        if candidate == shortcut { return true }
        guard registration.register(candidate) else {
            shortcutError = "This shortcut could not be registered. It may be used by another app. Your previous shortcut is unchanged."
            return false
        }
        shortcut = candidate
        shortcutError = nil
        UserDefaults.standard.set(try? JSONEncoder().encode(candidate), forKey: "globalShortcut")
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let shutdown else { return .terminateNow }
        terminating = true
        registration.unregister()
        Task {
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Track the singleton SwiftUI Window so every entry point reuses it.
struct SearchWindowRegistration: NSViewRepresentable {
    let lifecycle: AppLifecycle

    func makeNSView(context: Context) -> Observer { Observer(lifecycle: lifecycle) }
    func updateNSView(_ nsView: Observer, context: Context) {}

    final class Observer: NSView {
        private let lifecycle: AppLifecycle
        private var observations: [NSObjectProtocol] = []

        init(lifecycle: AppLifecycle) {
            self.lifecycle = lifecycle
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            observations.removeAll()
            guard let window else { return }
            lifecycle.registerSearchWindow(window)
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak lifecycle, weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { lifecycle?.unregisterSearchWindow(window) }
            })
            // SwiftUI may reopen the same NSWindow without reattaching this
            // view. Restore its registration when it becomes key again.
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak lifecycle, weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { lifecycle?.registerSearchWindow(window) }
            })
        }

        deinit {
            observations.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
