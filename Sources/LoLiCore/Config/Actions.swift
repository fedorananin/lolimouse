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
        var parts = fn ? "fn " : ""
        if control { parts += "⌃" }
        if option { parts += "⌥" }
        if shift { parts += "⇧" }
        if command { parts += "⌘" }
        return parts + KeyCombo.keyName(keyCode)
    }

    /// Flags a real keyboard sets on its own for this key, whatever modifiers
    /// are held: arrows, function keys and the navigation block carry `fn`,
    /// arrows and keypad keys carry "numeric pad".
    ///
    /// Synthesised events must carry them too. System shortcuts are matched on
    /// the whole flag set — the "move a space left" hotkey is stored as
    /// ⌃ + fn + ←, so a bare ⌃← is simply not that shortcut.
    public var intrinsicFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if KeyCombo.functionKeys.contains(keyCode) { flags.insert(.maskSecondaryFn) }
        if KeyCombo.numericPadKeys.contains(keyCode) { flags.insert(.maskNumericPad) }
        return flags
    }

    private static let arrowKeys: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E]

    private static let functionKeys: Set<UInt16> = arrowKeys.union([
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, // F1–F12
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A, // F13–F20
        0x72, 0x73, 0x74, 0x75, 0x77, 0x79, // help, home, page up, ⌦, end, page down
    ])

    private static let numericPadKeys: Set<UInt16> = arrowKeys.union([
        0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51,
        0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C,
    ])

    /// Key names as printed on a US keyboard. Key codes are positions, not
    /// characters, so on another layout the same code may carry a different
    /// letter — but it is the key the shortcut was recorded from, and it is
    /// what applications match their ⌘ shortcuts against.
    static func keyName(_ code: UInt16) -> String {
        keyNames[code] ?? String(format: "Key %d", code)
    }

    private static let keyNames: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O",
        0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'",
        0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
        0x30: "⇥", 0x31: "Space", 0x32: "`", 0x33: "⌫", 0x35: "Esc",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x47: "Clear", 0x4B: "Keypad /",
        0x4C: "⌤", 0x4E: "Keypad -", 0x51: "Keypad =",
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4",
        0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7", 0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x72: "Help", 0x73: "Home", 0x74: "Page Up", 0x75: "⌦", 0x77: "End", 0x79: "Page Down",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]
}

public extension Set where Element == ModifierKey {
    /// Modifier symbols in the order macOS prints them: ⌃⌥⇧⌘.
    var symbols: String {
        [(ModifierKey.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }
            .map(\.1)
            .joined()
    }
}

/// A synthesised click: which button, how many times, with which modifiers.
public struct MouseClick: Codable, Equatable, Hashable, Sendable {
    /// CoreGraphics button number, 0-based: 0 left, 1 right, 2 middle.
    public var button: Int
    /// 1 for a click, 2 for a double click, 3 for a triple click.
    public var count: Int
    /// Held for the duration of the click, as in ⌘-click.
    public var modifiers: Set<ModifierKey>

    public init(button: Int = 0, count: Int = 1, modifiers: Set<ModifierKey> = []) {
        self.button = button
        self.count = count
        self.modifiers = modifiers
    }

    public static let maximumCount = 3

    public static func buttonName(_ button: Int) -> String {
        switch button {
        case 0: return "Left"
        case 1: return "Right"
        case 2: return "Middle"
        case 3: return "Back (button 4)"
        case 4: return "Forward (button 5)"
        default: return "Button \(button + 1)"
        }
    }

    public var displayName: String {
        let times: String
        switch count {
        case ...1: times = "click"
        case 2: times = "double-click"
        default: times = "triple-click"
        }
        let prefix = modifiers.isEmpty ? "" : modifiers.symbols + " "
        return prefix + MouseClick.buttonName(button).lowercased() + " " + times
    }
}

/// Which way a synthesised scroll goes.
public enum ScrollDirection: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case up, down, left, right

    public var displayName: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// A synthesised turn of the wheel, as in ⌘ + scroll down.
public struct ScrollStep: Codable, Equatable, Hashable, Sendable {
    public var direction: ScrollDirection
    public var lines: Int
    public var modifiers: Set<ModifierKey>

    public init(direction: ScrollDirection = .down, lines: Int = 3, modifiers: Set<ModifierKey> = []) {
        self.direction = direction
        self.lines = lines
        self.modifiers = modifiers
    }

    public static let lineRange = 1 ... 20

    /// Line deltas for CoreGraphics' two wheel axes.
    ///
    /// The directions are those of a traditional (non-"natural") wheel: up
    /// moves towards the top of the page. A synthesised event never passes
    /// through the trackpad's natural-scrolling inversion, so this holds
    /// whatever System Settings says. Horizontally, CoreGraphics counts
    /// leftwards as positive.
    public var wheelDeltas: (vertical: Int32, horizontal: Int32) {
        let amount = Int32(clamping: max(lines, 1))
        switch direction {
        case .up: return (amount, 0)
        case .down: return (-amount, 0)
        case .left: return (0, amount)
        case .right: return (0, -amount)
        }
    }

    public var displayName: String {
        let prefix = modifiers.isEmpty ? "" : modifiers.symbols + " "
        let unit = lines == 1 ? "line" : "lines"
        return prefix + "scroll \(direction.displayName.lowercased()) \(lines) \(unit)"
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
    /// Kept for configurations written before `mouseClick` existed; the
    /// editor turns it into a `mouseClick` as soon as it is changed.
    case mouseButton(Int)
    /// Click, double-click or triple-click any button, optionally with
    /// modifiers held.
    case mouseClick(MouseClick)
    /// Turn the wheel, optionally with modifiers held.
    case scroll(ScrollStep)

    /// Step to the next configured DPI preset, wrapping around.
    case cycleDPIPresets
    /// Jump to a specific preset by index.
    case dpiPreset(Int)
    /// Flip the wheel between ratchet and free spin.
    case toggleWheelRatchet

    /// Launch an application by bundle identifier.
    case launchApp(String)

    // Media and hardware keys, sent as the same system-defined events the
    // keyboard's function row produces.
    case volumeUp
    case volumeDown
    case mute
    case playPause
    case mediaNext
    case mediaPrevious
    case brightnessUp
    case brightnessDown

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
        case let .mouseClick(click): return click.displayName.capitalizingFirstLetter
        case let .scroll(step): return step.displayName.capitalizingFirstLetter
        case .cycleDPIPresets: return "Cycle DPI presets"
        case let .dpiPreset(index): return "DPI preset \(index + 1)"
        case .toggleWheelRatchet: return "Toggle wheel ratchet"
        case let .launchApp(bundleID): return "Open \(bundleID)"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .playPause: return "Play / pause"
        case .mediaNext: return "Next track"
        case .mediaPrevious: return "Previous track"
        case .brightnessUp: return "Display brightness up"
        case .brightnessDown: return "Display brightness down"
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
            .volumeUp, .volumeDown, .mute,
            .playPause, .mediaNext, .mediaPrevious,
            .brightnessUp, .brightnessDown,
            .cycleDPIPresets, .toggleWheelRatchet,
        ]
    }
}

private extension String {
    var capitalizingFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
