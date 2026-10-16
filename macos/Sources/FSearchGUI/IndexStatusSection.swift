import AppKit
import SwiftUI

struct IndexStatusSection: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        Section("Index status") {
            HStack(spacing: 10) {
                if model.indexStatusError != nil {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                } else if model.indexStatus?.isBusy == true || model.indexStatus == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(model.indexStatusError != nil ? "Status unavailable" : model.indexStatus?.summary ?? "Connecting…")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshIndexStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh index status")
                .accessibilityLabel("Refresh index status")
                .disabled(model.isRefreshingIndexStatus || model.isSearching)
            }
            if let error = model.indexStatusError {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let status = model.indexStatus {
                if status.ready {
                    LabeledContent("Files and folders", value: status.entryCount.formatted())
                    LabeledContent("Indexed text files", value: status.contentDocs.formatted())
                    LabeledContent("File name index", value: bytes(status.indexBytes))
                    LabeledContent("Content index", value: bytes(status.contentBytes))
                    LabeledContent("Text files awaiting indexing", value: status.contentPending.formatted())
                } else {
                    LabeledContent("Entries scanned", value: status.listed.formatted())
                    Text("The first scan is running in the background. You can search a specific folder while it completes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Full Disk Access", value: status.fullDiskAccess ? "Granted" : "Limited")
            }
            HStack {
                Text("Refreshes every 2 seconds while Settings is open")
                Spacer()
                if let updated = model.indexStatusUpdatedAt {
                    Text(updated, style: .time).monospacedDigit()
                        .help("Last successful update")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

/// Settings windows can be retained after closing; window notifications stop
/// their polling task even when SwiftUI keeps the view alive.
struct SettingsVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Observer { Observer(onChange: onChange) }
    func updateNSView(_ nsView: Observer, context: Context) { nsView.onChange = onChange }

    final class Observer: NSView {
        var onChange: (Bool) -> Void
        private var observations: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach { NotificationCenter.default.removeObserver($0) }
            observations.removeAll()
            guard let window else { report(false); return }
            report(window.isVisible && !window.isMiniaturized)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report(true)
                })
            }
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report(false)
                })
            }
        }

        private func report(_ visible: Bool) {
            DispatchQueue.main.async { [weak self] in self?.onChange(visible) }
        }

        deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
