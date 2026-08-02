// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import CoreGraphics
import Foundation
import HIDKit
import IOKitSPI
import os.log

/// Carries out an `Action`.
///
/// Window-management actions go through the Dock's own notification channel
/// rather than by synthesising their keyboard shortcuts, because those
/// shortcuts are user-configurable and frequently turned off — a bound button
/// that stops working because someone changed a System Settings checkbox is a
/// bug report waiting to happen.
public final class ActionRunner {
    private static let log = LoLiLog.events

    /// Actions that need a device to act on are handed back to the app.
    public var onDeviceAction: ((Action, ManagedDevice?) -> Void)?

    public init() {}

    /// Runs `action`. Returns `false` for `.passthrough`, meaning the caller
    /// should let the original event continue on its way.
    @discardableResult
    public func run(_ action: Action, device: ManagedDevice? = nil) -> Bool {
        switch action {
        case .passthrough:
            return false

        case .none:
            return true

        case .missionControl:
            CoreDockSendNotification("com.apple.expose.awake" as CFString, 0)

        case .applicationWindows:
            CoreDockSendNotification("com.apple.expose.front.awake" as CFString, 0)

        case .showDesktop:
            CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, 0)

        case .launchpad:
            CoreDockSendNotification("com.apple.launchpad.toggle" as CFString, 0)

        case .spaceLeft:
            postKey(KeyCombo(keyCode: 0x7B, control: true))

        case .spaceRight:
            postKey(KeyCombo(keyCode: 0x7C, control: true))

        case .back:
            postKey(KeyCombo(keyCode: 0x21, command: true)) // ⌘[

        case .forward:
            postKey(KeyCombo(keyCode: 0x1E, command: true)) // ⌘]

        case .zoomIn:
            postKey(KeyCombo(keyCode: 0x18, command: true)) // ⌘=

        case .zoomOut:
            postKey(KeyCombo(keyCode: 0x1B, command: true)) // ⌘-

        case let .keyPress(combo):
            postKey(combo)

        case let .mouseButton(button):
            postMouseButton(button)

        case let .launchApp(bundleID):
            launch(bundleID)

        case .volumeUp:
            postSystemKey(.soundUp)

        case .volumeDown:
            postSystemKey(.soundDown)

        case .mute:
            postSystemKey(.mute)

        case .playPause:
            postSystemKey(.play)

        case .mediaNext:
            postSystemKey(.next)

        case .mediaPrevious:
            postSystemKey(.previous)

        case .brightnessUp:
            postSystemKey(.brightnessUp)

        case .brightnessDown:
            postSystemKey(.brightnessDown)

        case .cycleDPIPresets, .dpiPreset, .toggleWheelRatchet:
            let handler = onDeviceAction
            DispatchQueue.main.async { handler?(action, device) }
        }

        return true
    }

    /// The NX_KEYTYPE_* codes from IOKit's ev_keymap.h. Media and brightness
    /// keys are not ordinary key codes: they travel as "system-defined"
    /// events, the same channel the keyboard's function row uses.
    public enum SystemKey: Int32 {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case play = 16
        case next = 17
        case previous = 18
    }

    // MARK: - Synthesis

    private func postKey(_ combo: KeyCombo) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
        else {
            return
        }

        down.flags = combo.flags
        up.flags = combo.flags
        down.markSynthetic()
        up.markSynthetic()

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postSystemKey(_ key: SystemKey) {
        // A press is a down (0x0A) followed by an up (0x0B), both packed into
        // data1 the way NSEvent.systemDefined subtype 8 expects:
        // key code in the top 16 bits, key state in bits 8–15.
        func post(down: Bool) {
            let state: Int32 = down ? 0x0A : 0x0B
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key.rawValue << 16) | (state << 8)),
                data2: -1
            ), let cgEvent = event.cgEvent else {
                return
            }
            cgEvent.markSynthetic()
            cgEvent.post(tap: .cghidEventTap)
        }

        post(down: true)
        post(down: false)
    }

    private func postMouseButton(_ button: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let location = CGEvent(source: nil)?.location ?? .zero

        let (downType, upType): (CGEventType, CGEventType)
        switch button {
        case 0: (downType, upType) = (.leftMouseDown, .leftMouseUp)
        case 1: (downType, upType) = (.rightMouseDown, .rightMouseUp)
        default: (downType, upType) = (.otherMouseDown, .otherMouseUp)
        }

        let cgButton = CGMouseButton(rawValue: UInt32(max(button, 0))) ?? .center

        guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                 mouseCursorPosition: location, mouseButton: cgButton),
              let up = CGEvent(mouseEventSource: source, mouseType: upType,
                               mouseCursorPosition: location, mouseButton: cgButton)
        else {
            return
        }

        down.markSynthetic()
        up.markSynthetic()
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            os_log("no application with bundle id %{public}@", log: Self.log, type: .error, bundleID)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
