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
                resultsPane.frame(minWidth: 400, maxWidth: .infinity)
                detailPane.frame(minWidth: 260, idealWidth: 290, maxWidth: 320)
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
        .onChange(of: model.executablePath) { _ in model.search() }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(searchFocused ? Color.accentColor : Color.secondary)
                    TextField(model.mode == .names ? "Search files and folders…" : "Search text inside files…", text: $model.query)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($searchFocused)
                        .onSubmit { if let hit = model.selectedHit { model.open(hit) } }
                        .accessibilityLabel("Search query")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                    } else {
                        Text("⌘F").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(searchFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.1), lineWidth: 1)
                }
                Picker("Search mode", selection: $model.mode) {
                    ForEach(SearchMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).controlSize(.small).labelsHidden().frame(width: 174)
            }
            HStack(spacing: 10) {
                Button { model.chooseFolder() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.scope == nil ? "internaldrive" : "folder")
                        Text(model.scope.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Everywhere")
                            .lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .buttonStyle(.plain).help(model.scope ?? "Choose a search folder")
                if model.scope != nil {
                    Button { model.scope = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Search everywhere")
                }
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 12)
                Button { showFilters.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(activeFilterCount == 0 ? "Filters" : "Filters · \(activeFilterCount)")
                        Image(systemName: showFilters ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(showFilters || activeFilterCount > 0 ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showFilters ? "Expanded" : "Collapsed")
                Spacer(minLength: 8)
                Text(model.mode == .names ? "Try ext:pdf or mtime:<7d" : "Literal text · Smart case")
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            if showFilters {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { filterPickers }
                    VStack(alignment: .leading, spacing: 8) { filterPickers }
                }
                .pickerStyle(.menu).controlSize(.small)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }

    @ViewBuilder
    private var filterPickers: some View {
        Picker("Kind", selection: $model.filters.kind) {
            ForEach(SearchFilters.Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Modified", selection: $model.filters.modified) {
            ForEach(SearchFilters.Modified.allCases) { Text($0.rawValue).tag($0) }
        }
        Picker("Size", selection: $model.filters.size) {
            ForEach(SearchFilters.Size.allCases) { Text($0.rawValue).tag($0) }
        }
        if model.filters.isActive {
            Button("Clear filters") { model.filters = SearchFilters() }
                .help("Reset preset filters and keep the search text")
        }
    }

    private var activeFilterCount: Int {
        [model.filters.kind != .all, model.filters.modified != .any, model.filters.size != .any]
            .filter { $0 }.count
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: model.hasSearchCriteria ? "list.bullet" : "clock")
                Text(model.hasSearchCriteria ? "Search results" : model.showRecentlyOpened ? "Recently opened" : "Files")
                Spacer()
                if !model.results.isEmpty {
                    Text(model.results.count.formatted()).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).frame(height: 36)
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
                .scrollContentBackground(.hidden)
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
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var detailPane: some View {
        ScrollView {
            if let hit = model.selectedHit {
                VStack(alignment: .leading, spacing: 14) {
                    Text("FILE DETAILS")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                            .resizable().scaledToFit().frame(width: 48, height: 48)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(hit.name).font(.system(size: 15, weight: .semibold))
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                .help(hit.name)
                            Text(hit.kind == "dir" ? "Folder" : hit.url.pathExtension.isEmpty ? "File" : "\(hit.url.pathExtension.uppercased()) file")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button { model.open(hit) } label: {
                            HStack {
                                Text("Open")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { model.reveal(hit) } label: { Image(systemName: "folder") }
                            .help("Reveal in Finder (⌘R)").accessibilityLabel("Reveal in Finder")
                        Button { model.copyPath(hit) } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy path").accessibilityLabel("Copy path")
                    }
                    .controlSize(.regular)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Location").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text((hit.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                            .help(hit.path)
                    }
                    VStack(spacing: 14) {
                        if let kind = hit.kind { detail("Kind", value: kind == "dir" ? "Folder" : kind.capitalized) }
                        if let size = hit.size, hit.kind != "dir" {
                            detail("Size", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                        }
                        if let mtime = hit.mtime, mtime > 0 {
                            detail("Modified", value: Date(timeIntervalSince1970: mtime).formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if let matches = hit.matches, !matches.isEmpty {
                        Divider()
                        Text("MATCHING LINES").font(.system(size: 10, weight: .semibold))
                            .tracking(1).foregroundStyle(.secondary)
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
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28, weight: .light))
                    Text("Select a file").font(.system(size: 13, weight: .medium))
                    Text("Preview its details here").font(.caption)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity).padding(.top, 100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detail(_ name: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 11))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isSearching { ProgressView().controlSize(.mini) }
            Text("\(model.results.count) results\(model.next == nil ? "" : " · more available")")
                .monospacedDigit()
            if let time = model.tookMicroseconds, model.hasSearchCriteria {
                Text(String(format: "· %.2f ms", time / 1000)).monospacedDigit()
            }
            if model.indexing { Text("· Content index updating") }
            else if model.incomplete { Text("· Partial results — continue with Load More") }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                shortcutHint("↵", title: "Open")
                shortcutHint("⌘R", title: "Reveal")
                shortcutHint("⌘F", title: "Search")
            }
            .layoutPriority(1)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 32)
    }

    private func shortcutHint(_ key: String, title: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            Text(title)
        }
        .fixedSize()
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
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                .resizable().scaledToFit().frame(width: 30, height: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.parent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let first = hit.matches?.first {
                    Text("\(first.line): \(first.text.trimmingCharacters(in: .whitespacesAndNewlines))")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if hit.kind == "dir" { Image(systemName: "folder").foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 7)
        .help(hit.path)
        .contentShape(Rectangle())
    }
}
