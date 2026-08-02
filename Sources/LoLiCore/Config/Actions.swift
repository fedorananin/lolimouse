// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import Foundation

/// A keyboard shortcut, described the way a user would type it.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    /// Virtual key code, as used by `CGEvent(keyboardEventSource:)`.
    public var keyCode: UInt16
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool
    public var fn: Bool

    public init(
        keyCode: UInt16,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        fn: Bool = false
    ) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.fn = fn
    }

    public var flags: CGEventFlags {
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }
        if option { flags.insert(.maskAlternate) }
        if control { flags.insert(.maskControl) }
        if shift { flags.insert(.maskShift) }
        if fn { flags.insert(.maskSecondaryFn) }
        return flags
    }

    public var displayString: String {
        var parts = ""
        if control { parts += "⌃" }
        if option { parts += "⌥" }
        if shift { parts += "⇧" }
        if command { parts += "⌘" }
        return parts + KeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt16) -> String {
        switch code {
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x24: return "↩"
        case 0x30: return "⇥"
        case 0x31: return "Space"
        case 0x33: return "⌫"
        case 0x35: return "Esc"
        case 0x00: return "A"
        case 0x08: return "C"
        case 0x09: return "V"
        case 0x0B: return "B"
        case 0x2D: return "N"
        case 0x0C: return "Q"
        case 0x0D: return "W"
        case 0x0E: return "E"
        case 0x0F: return "R"
        case 0x11: return "T"
        default: return String(format: "key %d", code)
        }
    }
}

/// Something LoLiMouse can do in response to a button or a gesture.
///
/// The list deliberately mirrors what people actually bind mice to on macOS,
/// plus the two device-level actions that only make sense here (DPI presets and
/// the wheel ratchet).
public enum Action: Codable, Equatable, Hashable, Sendable {
    /// Do nothing at all — but still swallow the button, so it stops behaving
    /// like its factory default.
    case none
    /// Let the button through untouched.
    case passthrough

    case missionControl
    case applicationWindows
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight

    case back
    case forward

    case zoomIn
    case zoomOut

    /// Send a keyboard shortcut.
    case keyPress(KeyCombo)
    /// Send a plain mouse button, 0-based as CoreGraphics numbers them.
    case mouseButton(Int)

    /// Step to the next configured DPI preset, wrapping around.
    case cycleDPIPresets
    /// Jump to a specific preset by index.
    case dpiPreset(Int)
    /// Flip the wheel between ratchet and free spin.
    case toggleWheelRatchet

    /// Launch an application by bundle identifier.
    case launchApp(String)

    public var displayName: String {
        switch self {
        case .none: return "Do nothing"
        case .passthrough: return "Leave to the system"
        case .missionControl: return "Mission Control"
        case .applicationWindows: return "Application Windows"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .spaceLeft: return "Space to the left"
        case .spaceRight: return "Space to the right"
        case .back: return "Back"
        case .forward: return "Forward"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case let .keyPress(combo): return "Keyboard shortcut \(combo.displayString)"
        case let .mouseButton(button): return "Mouse button \(button + 1)"
        case .cycleDPIPresets: return "Cycle DPI presets"
        case let .dpiPreset(index): return "DPI preset \(index + 1)"
        case .toggleWheelRatchet: return "Toggle wheel ratchet"
        case let .launchApp(bundleID): return "Open \(bundleID)"
        }
    }

    /// Actions the user can pick from a menu without extra parameters.
    public static var simpleChoices: [Action] {
        [
            .none, .passthrough,
            .missionControl, .applicationWindows, .showDesktop, .launchpad,
            .spaceLeft, .spaceRight,
            .back, .forward,
            .zoomIn, .zoomOut,
            .cycleDPIPresets, .toggleWheelRatchet,
        ]
    }
}
