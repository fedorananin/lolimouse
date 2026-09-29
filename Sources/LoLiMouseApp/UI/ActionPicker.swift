// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import LoLiCore
import SwiftUI

/// A picker over the actions a button or gesture can trigger, plus the editor
/// for whichever custom action is picked: a recorded keyboard shortcut, a
/// synthesised click, or a synthesised turn of the wheel.
struct ActionPicker: View {
    let label: String
    @Binding var action: Action

    /// "Keyboard shortcut…" was picked but nothing has been recorded yet.
    /// There is no sensible shortcut to fill in on the user's behalf, so the
    /// action itself stays as it was until a key is pressed — cancelling the
    /// recording leaves the setting exactly where it started.
    @State private var awaitingShortcut = false
    @State private var recording = false

    private enum Choice: Hashable {
        case preset(Action)
        case shortcut
        case click
        case scroll
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(label, selection: choice) {
                ForEach(Action.simpleChoices, id: \.self) { preset in
                    Text(preset.displayName).tag(Choice.preset(preset))
                }
                // Keep a configured action selectable even when it is not one
                // of the fixed choices (a specific DPI preset, an app launch).
                if case let .preset(current) = choice.wrappedValue,
                   !Action.simpleChoices.contains(current) {
                    Text(current.displayName).tag(Choice.preset(current))
                }
                Divider()
                Text("Keyboard shortcut…").tag(Choice.shortcut)
                Text("Mouse click…").tag(Choice.click)
                Text("Scroll…").tag(Choice.scroll)
            }
            .pickerStyle(.menu)

            editor
        }
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                if awaitingShortcut { return .shortcut }
                switch action {
                case .keyPress: return .shortcut
                case .mouseButton, .mouseClick: return .click
                case .scroll: return .scroll
                default: return .preset(action)
                }
            },
            set: { newValue in
                awaitingShortcut = false
                recording = false
                switch newValue {
                case let .preset(preset):
                    action = preset
                case .shortcut:
                    if case .keyPress = action { return }
                    awaitingShortcut = true
                    recording = true
                case .click:
                    if case .mouseClick = action { return }
                    action = .mouseClick(click)
                case .scroll:
                    if case .scroll = action { return }
                    action = .scroll(ScrollStep())
                }
            }
        )
    }

    @ViewBuilder
    private var editor: some View {
        switch choice.wrappedValue {
        case .shortcut:
            ShortcutRecorder(combo: shortcut, isRecording: $recording) {
                awaitingShortcut = false
            }
        case .click:
            clickEditor
        case .scroll:
            scrollEditor
        case .preset:
            EmptyView()
        }
    }

    // MARK: - Keyboard shortcut

    private var shortcut: Binding<KeyCombo?> {
        Binding(
            get: {
                if case let .keyPress(combo) = action { return combo }
                return nil
            },
            set: { newValue in
                guard let newValue else { return }
                awaitingShortcut = false
                action = .keyPress(newValue)
            }
        )
    }

    // MARK: - Mouse click

    /// The click being edited. A legacy `.mouseButton` reads as a single click
    /// of that button and is rewritten as a `.mouseClick` on the first edit.
    private var click: MouseClick {
        switch action {
        case let .mouseClick(click): return click
        case let .mouseButton(button): return MouseClick(button: button)
        default: return MouseClick()
        }
    }

    private func updateClick(_ transform: (inout MouseClick) -> Void) {
        var updated = click
        transform(&updated)
        action = .mouseClick(updated)
    }

    private var clickEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Button", selection: Binding(
                    get: { click.button },
                    set: { value in updateClick { $0.button = value } }
                )) {
                    ForEach(Array(Set(0 ... 4).union([click.button])).sorted(), id: \.self) { button in
                        Text(MouseClick.buttonName(button)).tag(button)
                    }
                }
                .labelsHidden()

                Picker("Clicks", selection: Binding(
                    get: { click.count },
                    set: { value in updateClick { $0.count = value } }
                )) {
                    Text("Single").tag(1)
                    Text("Double").tag(2)
                    Text("Triple").tag(3)
                }
                .labelsHidden()
            }
            .pickerStyle(.menu)

            modifierRow(Binding(
                get: { click.modifiers },
                set: { value in updateClick { $0.modifiers = value } }
            ))
        }
    }

    // MARK: - Scroll

    private var step: ScrollStep {
        if case let .scroll(step) = action { return step }
        return ScrollStep()
    }

    private func updateStep(_ transform: (inout ScrollStep) -> Void) {
        var updated = step
        transform(&updated)
        action = .scroll(updated)
    }

    private var scrollEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Direction", selection: Binding(
                    get: { step.direction },
                    set: { value in updateStep { $0.direction = value } }
                )) {
                    ForEach(ScrollDirection.allCases, id: \.self) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Stepper(value: Binding(
                    get: { step.lines },
                    set: { value in updateStep { $0.lines = value } }
                ), in: ScrollStep.lineRange) {
                    Text(step.lines == 1 ? "1 line" : "\(step.lines) lines")
                        .monospacedDigit()
                }
            }

            modifierRow(Binding(
                get: { step.modifiers },
                set: { value in updateStep { $0.modifiers = value } }
            ))
        }
    }

    private func modifierRow(_ modifiers: Binding<Set<ModifierKey>>) -> some View {
        HStack(spacing: 6) {
            Text("Holding")
                .font(.caption)
                .foregroundStyle(.secondary)
            ModifierToggles(modifiers: modifiers) { "Hold \($0.displayName) during the action" }
        }
    }
}

/// Compact ⌃⌥⇧⌘ toggles over a set of modifier keys.
struct ModifierToggles: View {
    @Binding var modifiers: Set<ModifierKey>
    var help: (ModifierKey) -> String = { "Fire only while \($0.displayName) is held" }

    private static let symbols: [(ModifierKey, String)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.symbols, id: \.0) { modifier, symbol in
                Toggle(symbol, isOn: Binding(
                    get: { modifiers.contains(modifier) },
                    set: { held in
                        if held { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
                    }
                ))
                .toggleStyle(.button)
                .help(help(modifier))
            }
        }
    }
}

/// A button that, once clicked, takes the next key press as a shortcut.
///
/// Recording goes through a local event monitor, which sees key presses
/// before the menu does — so ⌘W or ⌘Q can be recorded without closing the
/// window or quitting the app. Shortcuts the system itself owns (⌘Tab,
/// ⌘Space, the Mission Control keys) never reach the app and cannot be
/// recorded; the fixed actions cover the useful ones.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @Binding var isRecording: Bool
    /// Called when recording ends without a shortcut (Esc, or a second click).
    var onCancel: () -> Void = {}

    @State private var monitor: Any?
    @State private var heldModifiers = ""

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if isRecording {
                    isRecording = false
                    onCancel()
                } else {
                    isRecording = true
                }
            } label: {
                Text(label)
                    .monospacedDigit()
                    .frame(minWidth: 140)
            }
            .help(isRecording ? "Press Esc or click again to cancel" : "Click, then press the shortcut")

            if isRecording {
                Text("Esc cancels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { if isRecording { startMonitor() } }
        .onDisappear { stopMonitor() }
        .onChange(of: isRecording) { _, recording in
            if recording { startMonitor() } else { stopMonitor() }
        }
    }

    private var label: String {
        if isRecording {
            return heldModifiers.isEmpty ? "Type a shortcut…" : heldModifiers + "…"
        }
        return combo?.displayString ?? "Click to record"
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        heldModifiers = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.type == .flagsChanged {
                var held: Set<ModifierKey> = []
                if flags.contains(.command) { held.insert(.command) }
                if flags.contains(.option) { held.insert(.option) }
                if flags.contains(.control) { held.insert(.control) }
                if flags.contains(.shift) { held.insert(.shift) }
                heldModifiers = held.symbols
                return nil
            }

            let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            if event.keyCode == 0x35, flags.intersection(modifiers).isEmpty {
                isRecording = false
                onCancel()
                return nil
            }

            // `fn` is left out on purpose: the keyboard adds it by itself to
            // arrows and function keys, and `KeyCombo.intrinsicFlags` puts it
            // back when the shortcut is sent.
            combo = KeyCombo(
                keyCode: event.keyCode,
                command: flags.contains(.command),
                option: flags.contains(.option),
                control: flags.contains(.control),
                shift: flags.contains(.shift)
            )
            isRecording = false
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        heldModifiers = ""
    }
}
