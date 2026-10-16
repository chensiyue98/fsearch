import AppKit
import Carbon
import Darwin
import XCTest
@testable import FSearchGUI

final class SearchTests: XCTestCase {
    @MainActor
    func testClickingResultsTransfersKeyboardFocusFromSearchField() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let content = try XCTUnwrap(window.contentView)
        var focusTransfers = 0
        let observer = ResultListPreviewShortcut.Observer(previewURL: nil, moveSelection: { _ in },
            focusResults: { focusTransfers += 1 }, preview: { true })
        observer.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        content.addSubview(observer)
        let table = NSTableView(frame: observer.frame)
        final class ResultsDataSource: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 10 }
        }
        let dataSource = ResultsDataSource()
        table.dataSource = dataSource
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let scrollView = NSScrollView(frame: observer.frame)
        scrollView.documentView = table
        content.addSubview(scrollView)
        let search = NSTextField(frame: NSRect(x: 0, y: 240, width: 300, height: 24))
        content.addSubview(search)
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertTrue(window.firstResponder is NSTextView)

        func click(at point: NSPoint, count: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: count, pressure: 1))
        }
        observer.focusListForClick(try click(at: NSPoint(x: 50, y: 50)))
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertEqual(focusTransfers, 1)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        XCTAssertTrue(ResultListPreviewShortcut.Observer.shouldPreview(space, responder: window.firstResponder))

        // Re-clicking an already selected result must also recover focus, including double-clicks.
        XCTAssertTrue(window.makeFirstResponder(search))
        observer.focusListForClick(try click(at: NSPoint(x: 50, y: 50), count: 2))
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertEqual(focusTransfers, 2)
        XCTAssertEqual(table.selectedRow, 0)

        XCTAssertTrue(window.makeFirstResponder(search))
        observer.focusListForClick(try click(at: NSPoint(x: 50, y: 250)))
        XCTAssertTrue(window.firstResponder is NSTextView)
        XCTAssertEqual(focusTransfers, 2)
        XCTAssertFalse(ResultListPreviewShortcut.Observer.shouldPreview(space, responder: window.firstResponder))
        XCTAssertEqual(search.stringValue, "")
    }

    @MainActor
    func testPreviewArrowNavigationMovesSelectionAndStopsAtBoundaries() throws {
        _ = NSApplication.shared
        let model = SearchModel()
        model.results = [SearchHit(path: "/tmp/first"), SearchHit(path: "/tmp/second"), SearchHit(path: "/tmp/third")]
        model.selection = model.results[1].id
        func offset(keyCode: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> Int? {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: repeatKey, keyCode: keyCode))
            return ResultListPreviewShortcut.Observer.previewNavigationOffset(event)
        }
        model.moveSelection(by: try XCTUnwrap(offset(keyCode: 125)))
        XCTAssertEqual(model.selectedHit?.url, URL(fileURLWithPath: "/tmp/third"))
        model.moveSelection(by: try XCTUnwrap(offset(keyCode: 125, repeatKey: true)))
        XCTAssertEqual(model.selection, "/tmp/third")
        model.moveSelection(by: try XCTUnwrap(offset(keyCode: 126)))
        XCTAssertEqual(model.selection, "/tmp/second")
        model.moveSelection(by: -1)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, "/tmp/first")
        for key: UInt16 in [49, 123, 124, 53, 36] {
            XCTAssertNil(try offset(keyCode: key))
        }
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            XCTAssertNil(try offset(keyCode: 125, flags: modifier))
            XCTAssertNil(try offset(keyCode: 126, flags: modifier))
        }
        model.selection = nil
        model.moveSelection(by: 1)
        XCTAssertNil(model.selection)
        model.results = []
        model.moveSelection(by: -1)
        XCTAssertNil(model.selection)
    }

    @MainActor
    func testSpacePreviewRequiresUnmodifiedSpaceAndListFocus() throws {
        _ = NSApplication.shared
        func event(keyCode: UInt16 = 49, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: keyCode))
        }
        let list = NSTableView()
        let row = NSView()
        list.addSubview(row)
        let editor = NSTextView()
        list.addSubview(editor)
        let space = try event()
        XCTAssertTrue(ResultListPreviewShortcut.Observer.shouldPreview(space, responder: list))
        XCTAssertTrue(ResultListPreviewShortcut.Observer.shouldPreview(space, responder: row))
        XCTAssertFalse(ResultListPreviewShortcut.Observer.shouldPreview(space, responder: editor))
        XCTAssertFalse(ResultListPreviewShortcut.Observer.shouldPreview(space, responder: NSTextField()))
        XCTAssertFalse(ResultListPreviewShortcut.Observer.shouldPreview(space, responder: NSButton()))
        XCTAssertFalse(ResultListPreviewShortcut.Observer.shouldPreview(space, responder: nil))
        XCTAssertFalse(ResultListPreviewShortcut.Observer.shouldPreview(try event(keyCode: 36), responder: list))
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            XCTAssertFalse(ResultListPreviewShortcut.Observer.shouldPreview(try event(flags: modifier), responder: list))
        }
    }

    @MainActor
    func testRecentlyOpenedPreferencePersistsAndRejectsLateReplies() async throws {
        let suite = "FSearchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = try makeFixture("""
        while IFS= read -r request; do
          case "$request" in
            *recent*) printf 'recent\\n' >> '\(log.path)'; sleep 0.3; printf '%s\\n' '{"ok":true,"hits":[{"path":"/tmp/recent"}]}' ;;
            *ping*) printf '%s\\n' '{"ok":true}' ;;
            *) printf 'search\\n' >> '\(log.path)'; printf '%s\\n' '{"ok":true,"hits":[{"path":"/tmp/search"}]}' ;;
          esac
        done
        """)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: log)
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(condition(), "Timed out waiting for fixture")
        }
        func requests() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        let client = SearchClient()
        let model = SearchModel(defaults: defaults, client: client)
        defer { client.close() }
        model.executablePath = fixture.path
        XCTAssertTrue(model.showRecentlyOpened)
        model.search()
        try await waitUntil { requests().contains("recent") }
        model.showRecentlyOpened = false
        _ = try await client.request(SearchRequest(op: "ping"), executable: fixture.path)
        XCTAssertTrue(model.results.isEmpty, "An in-flight recent reply must not repopulate the list")
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(SearchModel(defaults: defaults).showRecentlyOpened)
        model.query = "  \n"
        model.search()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(requests(), "recent\n", "Disabled recents must not send another request")
        model.filters = SearchFilters(kind: .pdf)
        model.search()
        try await waitUntil { model.results.first?.path == "/tmp/search" }
        model.filters = SearchFilters()
        model.query = "needle"
        model.search()
        try await waitUntil { model.results.first?.path == "/tmp/search" }
        model.showRecentlyOpened = true
        XCTAssertEqual(model.results.first?.path, "/tmp/search", "Changing recents must preserve keyword results")
        model.query = ""
        model.search()
        try await waitUntil { model.results.first?.path == "/tmp/recent" }
        XCTAssertEqual(requests(), "recent\nsearch\nsearch\nrecent\n")
        XCTAssertTrue(SearchModel(defaults: defaults).showRecentlyOpened)
        await model.shutdown()
    }

    func testGlobalShortcutRecordingAndPersistence() throws {
        func event(flags: NSEvent.ModifierFlags, keyCode: UInt16 = 49, text: String = " ") throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode))
        }
        XCTAssertNil(GlobalShortcut(event: try event(flags: [])))
        XCTAssertNil(GlobalShortcut(event: try event(flags: [.shift])))
        let recorded = try XCTUnwrap(GlobalShortcut(event: try event(flags: [.control, .option])))
        XCTAssertEqual(recorded, .defaultShortcut)
        XCTAssertEqual(recorded.display, "⌃⌥Space")
        let custom = try XCTUnwrap(GlobalShortcut(event: try event(flags: [.command, .shift], keyCode: 40, text: "k")))
        XCTAssertEqual(custom.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(custom.display, "⇧⌘K")
        XCTAssertEqual(try JSONDecoder().decode(GlobalShortcut.self, from: JSONEncoder().encode(custom)), custom)
    }

    @MainActor
    func testGlobalShortcutConflictPreservesPreviousRegistration() {
        _ = NSApplication.shared
        let original = GlobalShortcut(keyCode: UInt32(kVK_F19),
            modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey), keyLabel: "F19")
        let occupied = GlobalShortcut(keyCode: UInt32(kVK_F20),
            modifiers: original.modifiers, keyLabel: "F20")
        let registration = GlobalShortcutRegistration()
        let blocker = GlobalShortcutRegistration()
        let probe = GlobalShortcutRegistration()
        defer { registration.unregister(); blocker.unregister(); probe.unregister() }
        XCTAssertTrue(registration.register(original))
        XCTAssertTrue(blocker.register(occupied))
        XCTAssertFalse(registration.register(occupied))
        XCTAssertFalse(probe.register(original), "A failed replacement must keep the old shortcut registered")
        registration.unregister()
        XCTAssertTrue(probe.register(original), "Unregistering must release the shortcut")
    }

    @MainActor
    func testSearchShortcutTogglesAndReusesOneWindow() {
        _ = NSApplication.shared
        let lifecycle = AppLifecycle()
        var openings = 0
        lifecycle.openSearch = { openings += 1 }
        lifecycle.showSearch()
        lifecycle.showSearch()
        XCTAssertEqual(openings, 1, "Repeated requests must coalesce until the window is attached")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = SearchWindowRegistration.Observer(lifecycle: lifecycle)
        lifecycle.showSearch()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        lifecycle.toggleSearch()
        XCTAssertFalse(window.isVisible)
        lifecycle.toggleSearch()
        XCTAssertTrue(window.isVisible)
        lifecycle.showSearch()
        XCTAssertEqual(openings, 1, "Showing a hidden or visible window must reuse the existing instance")

        // Escape must preserve the registered window through repeated cycles.
        for _ in 0..<3 {
            lifecycle.hideSearch()
            XCTAssertFalse(window.isVisible)
            lifecycle.toggleSearch()
            XCTAssertTrue(window.isVisible)
            lifecycle.toggleSearch()
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(openings, 1)
        }

        window.close()
        lifecycle.showSearch()
        XCTAssertEqual(openings, 2, "Only a closed window should request a new instance")
        // Reproduce SwiftUI reopening a retained window without moving its view.
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        lifecycle.toggleSearch()
        XCTAssertFalse(window.isVisible)
        lifecycle.toggleSearch()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(openings, 2)
    }

    func testBundledEngineDiscoveryDoesNotDependOnWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Moved App/FSearch.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: String] = [
            "CFBundleIdentifier": "io.fsearch.test.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "FSearchGUI"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let engine = macOS.appendingPathComponent("fsearch")
        try "#!/bin/sh\nexit 0\n".write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(SearchClient.locateExecutable(customPath: "", bundle: bundle), engine.path)
        // A stale saved override must not replace the bundled engine.
        XCTAssertEqual(SearchClient.locateExecutable(customPath: root.appendingPathComponent("missing").path, bundle: bundle), engine.path)
    }

    private func json(_ request: SearchRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }

    func testPresetFiltersPreserveTextAndPagingInBothModes() throws {
        let filters = SearchFilters(kind: .code, modified: .week, size: .medium)
        let names = try json(.search(query: "readme ext:md", mode: .names, scope: "/a folder", next: 100, filters: filters))
        XCTAssertEqual(names["q"] as? String, "readme ext:md")
        XCTAssertEqual(names["type"] as? String, "code")
        XCTAssertEqual(names["mtime"] as? String, "<7d")
        XCTAssertEqual(names["size"] as? String, "1mb..100mb")
        XCTAssertEqual(names["offset"] as? Int, 100)
        XCTAssertEqual(names["in"] as? String, "/a folder")
        let content = try json(.search(query: "some text.*", mode: .content, scope: nil, next: 231, filters: filters))
        XCTAssertEqual(content["pattern"] as? String, "some text.*")
        XCTAssertEqual(content["type"] as? String, "code")
        XCTAssertEqual(content["mode"] as? String, "literal")
        XCTAssertEqual(content["cursor"] as? Int, 231)
        XCTAssertNil(content["q"])
        XCTAssertNil(content["offset"])
        for mode in SearchMode.allCases {
            let onlyFilters = try json(.search(query: " ", mode: mode, scope: nil, next: 100, filters: filters))
            XCTAssertEqual(onlyFilters["op"] as? String, "search")
            XCTAssertEqual(onlyFilters["q"] as? String, "")
            XCTAssertEqual(onlyFilters["offset"] as? Int, 100)
            XCTAssertEqual(onlyFilters["type"] as? String, "code")
            XCTAssertNil(onlyFilters["pattern"])
            let cleared = try json(.search(query: "", mode: mode, scope: nil))
            XCTAssertEqual(cleared["op"] as? String, "recent")
            XCTAssertNil(cleared["type"])
            XCTAssertNil(cleared["size"])
        }
        let folders = try json(.search(query: "", mode: .names, scope: nil, filters: SearchFilters(kind: .folders)))
        XCTAssertEqual(folders["kind"] as? String, "dir")
        let pdf = try json(.search(query: "", mode: .names, scope: nil, filters: SearchFilters(kind: .pdf)))
        XCTAssertEqual(pdf["ext"] as? String, "pdf")
    }

    func testRequestsPreserveScopeAndPagingSemantics() throws {
        let names = try json(.search(query: "ext:rs grep:hello", mode: .names, scope: "/a folder", next: 100))
        XCTAssertEqual(names["q"] as? String, "ext:rs grep:hello")
        XCTAssertEqual(names["in"] as? String, "/a folder")
        XCTAssertEqual(names["offset"] as? Int, 100)
        XCTAssertNil(names["cursor"])
        let content = try json(.search(query: "a b.*", mode: .content, scope: nil, next: 231))
        XCTAssertEqual(content["pattern"] as? String, "a b.*")
        XCTAssertEqual(content["mode"] as? String, "literal")
        XCTAssertEqual(content["cursor"] as? Int, 231)
        XCTAssertNil(content["offset"])
        XCTAssertNil(content["q"])
        XCTAssertEqual(try json(.search(query: "  ", mode: .content, scope: nil))["op"] as? String, "recent")
    }

    func testDecodeBothBackendResultShapes() throws {
        let names = Data(#"{"ok":true,"hits":[{"path":"/tmp/a.swift","kind":"file","size":42,"mtime":123,"score":8}],"next":100,"took_us":75}"#.utf8)
        let reply = try JSONDecoder().decode(SearchReply.self, from: names)
        XCTAssertEqual(reply.results.first?.size, 42)
        XCTAssertEqual(reply.next, 100)
        let grep = Data(#"{"ok":true,"files":[{"path":"/tmp/a.swift","matches":[{"line":4,"text":"hello","ranges":[[0,5]]}]}],"complete":false,"indexing":12,"next":231}"#.utf8)
        let content = try JSONDecoder().decode(SearchReply.self, from: grep)
        XCTAssertEqual(content.results.first?.matches?.first?.line, 4)
        XCTAssertEqual(content.indexing, 12)
        XCTAssertEqual(content.complete, false)
    }

    func testIndexStatusReportsStagesAndLiveEntryCount() throws {
        var fields: [String: Any] = [
            "ok": true, "ready": true, "replaying": false, "content_ready": true,
            "listed": 500, "entries": 100, "overlay": 5, "removed": 3,
            "index_bytes": 1024, "content_docs": 12, "content_bytes": 4096,
            "content_pending": 0, "full_disk_access": false, "owner": true
        ]
        func status() throws -> IndexStatus {
            try JSONDecoder().decode(IndexStatus.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        XCTAssertEqual(try status().entryCount, 102)
        XCTAssertEqual(try status().summary, "Up to date")
        XCTAssertFalse(try status().isBusy)
        fields["ready"] = false
        XCTAssertEqual(try status().summary, "Scanning file names…")
        XCTAssertEqual(try status().listed, 500)
        fields["ready"] = true
        fields["replaying"] = true
        XCTAssertEqual(try status().summary, "Catching up on changes…")
        fields["replaying"] = false
        fields["content_ready"] = false
        XCTAssertEqual(try status().summary, "Indexing file contents…")
        fields["content_ready"] = true
        fields["content_pending"] = 9
        XCTAssertTrue(try status().isBusy)
        fields["owner"] = false
        XCTAssertEqual(try status().summary, "Following shared index")
    }

    func testTypedStatusRequestUsesProgressEndpoint() async throws {
        let fixture = try makeFixture("""
        while IFS= read -r request; do
          case "$request" in
            *'"progress":true'*) printf '%s\\n' '{"ok":true,"ready":false,"replaying":true,"content_ready":false,"listed":250,"entries":0,"overlay":0,"removed":0,"index_bytes":0,"content_docs":0,"content_bytes":0,"content_pending":0,"full_disk_access":false,"owner":true}' ;;
            *) printf '%s\\n' '{"ok":false,"error":"progress required"}' ;;
          esac
        done
        """)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let client = SearchClient(embeddedEngine: false)
        defer { client.close() }
        let status = try await client.request(SearchRequest(op: "status", progress: true), executable: fixture.path, as: IndexStatus.self)
        XCTAssertFalse(status.ready)
        XCTAssertEqual(status.listed, 250)
        do {
            _ = try await client.request(SearchRequest(op: "status"), executable: fixture.path, as: IndexStatus.self)
            XCTFail("Expected backend error, not a decoding error")
        } catch { XCTAssertEqual(error.localizedDescription, "progress required") }
    }

    func testBridgeKeepsConnectionAfterBackendError() async throws {
        let fixture = try makeFixture("""
        IFS= read -r request
        printf '%s\\n' '{"ok":false,"error":"bad filter"}'
        IFS= read -r request
        printf '%s\\n' '{"ok":true,"hits":[{"path":"/tmp/文件.swift"}]}'
        """)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let client = SearchClient(embeddedEngine: false)
        defer { client.close() }
        do {
            _ = try await client.request(SearchRequest(), executable: fixture.path)
            XCTFail("Expected backend error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "bad filter")
        }
        let reply = try await client.request(SearchRequest(), executable: fixture.path)
        XCTAssertEqual(reply.results.first?.name, "文件.swift")
    }

    func testBridgeReconnectsAfterEOF() async throws {
        let fixture = try makeFixture("""
        IFS= read -r request
        case "$request" in
          *ping*) printf '%s\\n' '{"ok":true}' ;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let client = SearchClient(embeddedEngine: false)
        defer { client.close() }
        do {
            _ = try await client.request(SearchRequest(), executable: fixture.path)
            XCTFail("Expected EOF")
        } catch {
            XCTAssertEqual(error.localizedDescription, SearchFailure.disconnected.localizedDescription)
        }
        let reply = try await client.request(SearchRequest(op: "ping"), executable: fixture.path)
        XCTAssertTrue(reply.ok)
    }

    func testCancellationInterruptsBlockedRead() async throws {
        let fixture = try makeFixture("""
        IFS= read -r request
        while IFS= read -r request; do :; done
        """)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let client = SearchClient(embeddedEngine: false)
        defer { client.close() }
        let task = Task { try await client.request(SearchRequest(), executable: fixture.path) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEmbeddedEngineSurvivesQueryCancellationAndStopsAtShutdown() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = try makeFixture("""
        case "$1" in
          embedded-gui)
            printf '%s\\n' "$$" >> '\(pidFile.path)'
            while IFS= read -r request; do
              case "$request" in
                *blocked*) sleep 0.4; printf '%s\\n' '{"ok":true,"hits":[{"path":"/tmp/stale"}]}' ;;
                *) printf '%s\\n' '{"ok":true,"hits":[{"path":"/tmp/current"}]}' ;;
              esac
            done
            ;;
          *) exit 1 ;;
        esac
        """)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let client = SearchClient()
        defer { client.close() }
        _ = try await client.request(SearchRequest(op: "ping"), executable: fixture.path)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let blocked = Task { try await client.request(SearchRequest(q: "blocked"), executable: fixture.path) }
        try await Task.sleep(nanoseconds: 200_000_000)
        blocked.cancel()
        do { _ = try await blocked.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await client.request(SearchRequest(op: "ping"), executable: fixture.path)
        XCTAssertEqual(next.results.first?.path, "/tmp/current", "Cancelled replies must be drained before the next request")
        XCTAssertEqual(try String(contentsOf: pidFile, encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
        await client.shutdown()
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        do {
            _ = try await client.request(SearchRequest(op: "ping"), executable: fixture.path)
            XCTFail("Shutdown must not restart a service")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func makeFixture(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
