import AppKit
import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var mode = SearchMode.names
    @Published var filters = SearchFilters()
    @Published var scope: String?
    @Published var results: [SearchHit] = []
    @Published var selection: String?
    @Published var isSearching = false
    @Published var isClearingHistory = false
    @Published var error: String?
    @Published var next: Int?
    @Published var tookMicroseconds: Double?
    @Published var indexing = false
    @Published var incomplete = false
    @Published var indexStatus: IndexStatus?
    @Published var indexStatusError: String?
    @Published var indexStatusUpdatedAt: Date?
    @Published var isRefreshingIndexStatus = false
    @Published var showRecentlyOpened: Bool {
        didSet {
            guard showRecentlyOpened != oldValue else { return }
            defaults.set(showRecentlyOpened, forKey: "showRecentlyOpened")
            if !hasSearchCriteria { search() }
        }
    }
    @Published var executablePath: String {
        didSet {
            defaults.set(executablePath, forKey: "executablePath")
            indexStatus = nil
            indexStatusError = nil
            indexStatusUpdatedAt = nil
        }
    }
    private let defaults: UserDefaults
    private let client: SearchClient
    private var task: Task<Void, Never>?
    private var revision = 0
    private var isShuttingDown = false

    init(defaults: UserDefaults = .standard, client: SearchClient = SearchClient()) {
        self.defaults = defaults
        self.client = client
        executablePath = defaults.string(forKey: "executablePath") ?? ""
        showRecentlyOpened = defaults.object(forKey: "showRecentlyOpened") as? Bool ?? true
    }
    var queryIsEmpty: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasSearchCriteria: Bool { !queryIsEmpty || filters.isActive }
    var selectedHit: SearchHit? { results.first { $0.id == selection } }

    func moveSelection(by offset: Int) {
        guard let index = results.firstIndex(where: { $0.id == selection }), !results.isEmpty else { return }
        let nextIndex = min(max(index + offset, 0), results.count - 1)
        selection = results[nextIndex].id
    }

    /// Start the built-in engine as soon as the window appears.
    func start() async {
        guard !isShuttingDown else { return }
        let startingRevision = revision
        isSearching = hasSearchCriteria || showRecentlyOpened
        do {
            let executable = SearchClient.locateExecutable(customPath: executablePath)
            _ = try await client.request(SearchRequest(op: "ping"), executable: executable)
            try Task.checkCancellation()
            if revision == startingRevision { search() }
        } catch {
            guard revision == startingRevision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            isSearching = false
        }
    }

    func search(loadMore: Bool = false) {
        guard !isShuttingDown else { return }
        task?.cancel()
        revision += 1
        let revision = revision
        let cursor = loadMore ? next : nil
        if loadMore && cursor == nil { return }
        error = nil
        if !loadMore {
            results = []
            selection = nil
            next = nil
            tookMicroseconds = nil
            indexing = false
            incomplete = false
        }
        // Also invalidate in-flight recents so a late reply cannot repopulate
        // the list after the user turns this preference off.
        guard hasSearchCriteria || showRecentlyOpened else {
            isSearching = false
            return
        }
        let request = SearchRequest.search(query: query, mode: mode, scope: scope, next: cursor, filters: filters)
        let executable = SearchClient.locateExecutable(customPath: executablePath)
        isSearching = true
        task = Task {
            do {
                if !loadMore { try await Task.sleep(nanoseconds: 160_000_000) }
                let reply = try await client.request(request, executable: executable)
                try Task.checkCancellation()
                guard self.revision == revision else { return }
                var seen = Set(results.map(\.id))
                results.append(contentsOf: reply.results.filter { seen.insert($0.id).inserted })
                if selection == nil { selection = results.first?.id }
                next = reply.next
                tookMicroseconds = reply.took_us
                indexing = (reply.indexing ?? 0) > 0
                incomplete = reply.complete == false
                isSearching = false
            } catch is CancellationError {
                // A newer request owns the view state.
            } catch {
                guard self.revision == revision, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isSearching = false
            }
        }
    }

    func shutdown() async {
        isShuttingDown = true
        revision += 1
        task?.cancel()
        await client.shutdown()
    }

    func clearHistory() async {
        guard !isShuttingDown, !isClearingHistory else { return }
        isClearingHistory = true
        defer { isClearingHistory = false }
        if !hasSearchCriteria {
            task?.cancel()
            revision += 1
            isSearching = false
        }
        do {
            let executable = SearchClient.locateExecutable(customPath: executablePath)
            _ = try await client.request(SearchRequest(op: "clear_recent"), executable: executable)
            guard !isShuttingDown else { return }
            if !hasSearchCriteria {
                // Invalidate any recents request started while clearing was in flight.
                task?.cancel()
                revision += 1
                results = []
                selection = nil
                next = nil
                tookMicroseconds = nil
                isSearching = false
                error = nil
            }
        } catch {
            guard !isShuttingDown else { return }
            self.error = "Could not clear history: \(error.localizedDescription)"
        }
    }

    func refreshIndexStatus() async {
        guard !isShuttingDown, !isSearching, !isRefreshingIndexStatus else { return }
        let path = executablePath
        isRefreshingIndexStatus = true
        defer { isRefreshingIndexStatus = false }
        do {
            let executable = SearchClient.locateExecutable(customPath: path)
            let status = try await client.request(
                SearchRequest(op: "status", progress: true), executable: executable, as: IndexStatus.self
            )
            try Task.checkCancellation()
            guard !isShuttingDown, path == executablePath else { return }
            indexStatus = status
            indexStatusError = nil
            indexStatusUpdatedAt = Date()
        } catch is CancellationError {
            // Closing Settings cancels its refresh without affecting search state.
        } catch {
            guard !isShuttingDown, path == executablePath, !Task.isCancelled else { return }
            indexStatusError = error.localizedDescription
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Search Here"
        if panel.runModal() == .OK, let url = panel.url { scope = url.path }
    }

    func open(_ hit: SearchHit) {
        guard NSWorkspace.shared.open(hit.url) else {
            error = "macOS could not open this file. It may have moved or been deleted."
            return
        }
        let executable = SearchClient.locateExecutable(customPath: executablePath)
        Task { _ = try? await client.request(SearchRequest(op: "open", path: hit.path), executable: executable) }
    }

    func reveal(_ hit: SearchHit) { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
    func copyPath(_ hit: SearchHit) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.path, forType: .string)
    }
}
