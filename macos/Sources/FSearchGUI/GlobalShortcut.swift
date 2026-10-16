import AppKit
import Carbon
import SwiftUI

struct GlobalShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), keyLabel: "Space"
    )

    var display: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require Command, Control, or Option so normal typing keeps working.
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let text = event.charactersIgnoringModifiers, !text.isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = (flags.contains(.command) ? UInt32(cmdKey) : 0)
            | (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
        let labels: [UInt16: String] = [
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End",
            116: "Page Up", 121: "Page Down"
        ]
        keyLabel = labels[event.keyCode] ?? text.uppercased()
    }
}

/// Carbon hot keys work across applications without an accessibility event tap.
final class GlobalShortcutRegistration {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onInvoke: (() -> Void)?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let registration = Unmanaged<GlobalShortcutRegistration>.fromOpaque(context).takeUnretainedValue()
            registration.onInvoke?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> Bool {
        guard handler != nil else { return false }
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: 0x46535243, id: 1), GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else { return false }
        unregister()
        hotKey = candidate
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }
}

struct ShortcutRecorder: View {
    @ObservedObject var lifecycle: AppLifecycle
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Show / hide FSearch")
                Spacer()
                Button(recording ? "Press shortcut…" : lifecycle.shortcut.display) {
                    if recording { stopRecording() } else { startRecording() }
                }
                .monospacedDigit()
                .accessibilityLabel("Record global shortcut")
                Button("Reset") {
                    stopRecording()
                    _ = lifecycle.updateShortcut(.defaultShortcut)
                }
                .disabled(lifecycle.shortcut == .defaultShortcut && !recording)
            }
            Text(message ?? lifecycle.shortcutError ?? "Click the shortcut, then press a key with ⌘, ⌃, or ⌥. Escape cancels.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .background(SettingsVisibility { visible in
            if !visible { stopRecording() }
        })
    }

    private func startRecording() {
        recording = true
        message = nil
        lifecycle.suspendShortcut()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            guard let shortcut = GlobalShortcut(event: event) else {
                message = "Include ⌘, ⌃, or ⌥ in the shortcut."
                return nil
            }
            stopRecording()
            _ = lifecycle.updateShortcut(shortcut)
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        lifecycle.resumeShortcut()
    }
}
