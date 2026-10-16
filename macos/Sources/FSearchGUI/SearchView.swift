import AppKit
import SwiftUI

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var searchFocused: Bool
    @State private var showHelp = false
    @State private var showFilters = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HSplitView {
                resultsPane.frame(minWidth: 420)
                detailPane.frame(minWidth: 260, idealWidth: 320, maxWidth: 400)
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help("Choose search folder (⇧⌘O)")
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .help("Query syntax")
                    .popover(isPresented: $showHelp) { queryHelp }
            }
        }
        .task { searchFocused = true; await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: .focusFSearch)) { _ in searchFocused = true }
        .onChange(of: model.query) { _ in model.search() }
        .onChange(of: model.mode) { _ in
            // Empty queries show the same recents in either search mode.
            guard !model.queryIsEmpty else { return }
            model.search()
        }
        .onChange(of: model.scope) { _ in model.search() }
        .onChange(of: model.filters) { _ in model.search() }
        .onChange(of: model.sort) { _ in model.search() }
        .onChange(of: model.executablePath) { _ in model.search() }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField(model.mode == .names ? "Find files, folders, or use ext:rs…" : "Search text inside files…", text: $model.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($searchFocused)
                    .onSubmit { if let hit = model.selectedHit { model.open(hit) } }
                    .accessibilityLabel("Search query")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                }
                Picker("Search mode", selection: $model.mode) {
                    ForEach(SearchMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            }
            DisclosureGroup(isExpanded: $showFilters) {
                HStack(spacing: 12) {
                    Picker("Kind", selection: $model.filters.kind) {
                        ForEach(SearchFilters.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Modified", selection: $model.filters.modified) {
                        ForEach(SearchFilters.Modified.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Size", selection: $model.filters.size) {
                        ForEach(SearchFilters.Size.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Spacer(minLength: 0)
                }
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)
                .controlSize(.small)
                .padding(.top, 8)
                HStack(spacing: 12) {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(SearchSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    if activeFilterCount > 0 {
                        Button("Reset") {
                            model.filters = SearchFilters()
                            model.sort = .relevance
                        }
                        .help("Reset filters and sorting, keeping search text and folder")
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .padding(.top, 4)
            } label: {
                Label(activeFilterCount == 0 ? "Filters" : "Filters (\(activeFilterCount))", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                    .foregroundStyle(activeFilterCount > 0 ? Color.accentColor : Color.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: model.scope == nil ? "internaldrive" : "folder")
                Text(model.scope.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Everywhere")
                    .lineLimit(1).truncationMode(.middle)
                if model.scope != nil {
                    Button { model.scope = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Search everywhere")
                }
                Spacer()
                Text(model.queryIsEmpty ? (model.filters.isActive ? "Filtered files" : model.showRecentlyOpened ? "Recently opened" : "") : model.mode == .names ? "Fuzzy matching · Query filters supported" : "Literal text · Smart case")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var activeFilterCount: Int {
        [model.filters.kind != .all, model.filters.modified != .any, model.filters.size != .any, model.sort != .relevance]
            .filter { $0 }.count
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Search unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).textSelection(.enabled)
                    Button("Try Again") { model.search() }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
            }
            if model.results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.isSearching ? "hourglass" : "magnifyingglass")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.isSearching ? "Searching…" : model.hasSearchCriteria ? "No matching files" : "Find your next file")
                        .font(.headline)
                    Text(model.hasSearchCriteria ? "Try fewer words, adjust the filters, or choose a different folder." : model.showRecentlyOpened ? "Start typing to search your disk.\nFiles opened here appear in your recents." : "Start typing to search your disk.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.results) { hit in
                        ResultRow(hit: hit)
                            .tag(hit.id)
                    }
                }
                .listStyle(.inset)
                // Use the list's native double-click action. A row-level
                // double-tap recognizer delays its single-click selection.
                .contextMenu(forSelectionType: String.self) { ids in
                    if let hit = model.results.first(where: { ids.contains($0.id) }) {
                        Button("Open") { model.open(hit) }
                        Button("Reveal in Finder") { model.reveal(hit) }
                        Button("Copy Path") { model.copyPath(hit) }
                    }
                } primaryAction: { ids in
                    if let hit = model.results.first(where: { ids.contains($0.id) }) {
                        model.open(hit)
                    }
                }
                if model.next != nil {
                    Button("Load More Results") { model.search(loadMore: true) }
                        .disabled(model.isSearching).padding(10)
                }
            }
        }
    }

    private var detailPane: some View {
        ScrollView {
            if let hit = model.selectedHit {
                VStack(alignment: .leading, spacing: 20) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                        .resizable().scaledToFit().frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(hit.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(hit.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    HStack {
                        Button("Open") { model.open(hit) }.buttonStyle(.borderedProminent)
                        Button { model.reveal(hit) } label: { Image(systemName: "folder") }.help("Reveal in Finder")
                        Button { model.copyPath(hit) } label: { Image(systemName: "doc.on.doc") }.help("Copy path")
                    }
                    Divider()
                    if let kind = hit.kind { detail("Kind", value: kind == "dir" ? "Folder" : kind.capitalized) }
                    if let size = hit.size, hit.kind != "dir" {
                        detail("Size", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                    }
                    if let mtime = hit.mtime, mtime > 0 {
                        detail("Modified", value: Date(timeIntervalSince1970: mtime).formatted(date: .abbreviated, time: .shortened))
                    }
                    if let matches = hit.matches, !matches.isEmpty {
                        Text("MATCHING LINES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Line \(match.line)").font(.caption).foregroundStyle(.secondary)
                                Text(match.text.trimmingCharacters(in: .newlines))
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a file to see details")
                    .font(.callout).foregroundStyle(.secondary).padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detail(_ name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isSearching { ProgressView().controlSize(.small) }
            Text("\(model.results.count) results\(model.next == nil ? "" : " · more available")")
            if let time = model.tookMicroseconds { Text(String(format: "· %.2f ms", time / 1000)) }
            if model.indexing { Text("· Content index updating") }
            else if model.incomplete { Text("· Partial results — continue with Load More") }
            Spacer()
            Text("↵ Open    ⌘R Reveal    ⌘F Search")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var queryHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search your way").font(.headline)
            Text("File names support FSearch’s full query syntax. Contents searches for literal text; uppercase letters enable case-sensitive matching.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(["readme ext:md", "type:image size:>5mb", "mtime:<7d", "ext:rs grep:apply_dir", "git:modified in:~/Developer/app"], id: \.self) {
                Text($0).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
        }
        .padding(20).frame(width: 360)
    }
}

private struct ResultRow: View {
    let hit: SearchHit
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                .resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.name).font(.system(.body, weight: .medium)).lineLimit(1)
                Text(hit.parent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let first = hit.matches?.first {
                    Text("\(first.line): \(first.text.trimmingCharacters(in: .whitespacesAndNewlines))")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if hit.kind == "dir" { Image(systemName: "folder").foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
