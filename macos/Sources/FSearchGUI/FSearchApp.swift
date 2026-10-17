import SwiftUI

@main
struct FSearchApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var model = SearchModel()

    var body: some Scene {
        Window("FSearch", id: "search") {
            SearchWindowContent(model: model, lifecycle: lifecycle)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 680)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Search Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Search Everywhere") { model.scope = nil }
                Divider()
                Button("Open Selected File") {
                    if let hit = model.selectedHit { model.open(hit) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.selectedHit == nil)
                Button("Reveal in Finder") {
                    if let hit = model.selectedHit { model.reveal(hit) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedHit == nil)
            }
        }
        Settings { SettingsView(model: model, lifecycle: lifecycle) }
        MenuBarExtra("FSearch", systemImage: "magnifyingglass", isInserted: menuBarInsertion) {
            Button("Show FSearch") { lifecycle.showSearch() }
            Divider()
            if #available(macOS 14.0, *) {
                SettingsLink { Text("Settings…") }
            } else {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            Divider()
            Button("Quit FSearch") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarInsertion: Binding<Bool> {
        Binding(
            get: { lifecycle.showMenuBarIcon },
            set: { isInserted in
                guard lifecycle.showMenuBarIcon != isInserted else { return }
                // MenuBarExtra can write back while SwiftUI updates the scene.
                // Publish the change only after that update has completed.
                DispatchQueue.main.async {
                    guard lifecycle.showMenuBarIcon != isInserted else { return }
                    lifecycle.showMenuBarIcon = isInserted
                }
            }
        )
    }
}

private struct SearchWindowContent: View {
    @ObservedObject var model: SearchModel
    let lifecycle: AppLifecycle
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SearchView(model: model)
            .background(SearchWindowRegistration(lifecycle: lifecycle))
            .onExitCommand { lifecycle.hideSearch() }
            .onAppear {
                lifecycle.shutdown = { await model.shutdown() }
                lifecycle.openSearch = { openWindow(id: "search") }
            }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var lifecycle: AppLifecycle
    @State private var isVisible = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show Dock icon", isOn: $lifecycle.showDockIcon)
                Toggle("Show menu bar icon", isOn: $lifecycle.showMenuBarIcon)
                Text("FSearch keeps running when its search window closes. Use the global shortcut or reopen the app in Finder to show it, even when both icons are hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Global shortcut") {
                ShortcutRecorder(lifecycle: lifecycle)
            }
            Section("Search") {
                Toggle("Show recently opened", isOn: $model.showRecentlyOpened)
                Text("Show recent items when the search field is empty.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Search engine") {
                Text("The search engine is included in FSearch and runs with the app. No separate installation or background service is required.")
                    .foregroundStyle(.secondary)
            }
            IndexStatusSection(model: model)
            Section("Index access") {
                Text("The built-in search engine stops when you quit FSearch. Its saved index is retained. Protected folders require Full Disk Access for the fsearch engine.")
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .buttonStyle(FeedbackButtonStyle())
        .padding()
        .frame(width: 560, height: 680)
        .background(SettingsVisibility { isVisible = $0 })
        .task(id: "\(isVisible):\(model.executablePath)") {
            guard isVisible else { return }
            while !Task.isCancelled {
                await model.refreshIndexStatus()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
    }
}
