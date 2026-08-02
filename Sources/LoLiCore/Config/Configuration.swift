// MIT License
// Copyright (c) 2026 LoLiMouse contributors
//
// The whole configuration model. Every leaf is a `Setting`, so every single
// feature can be switched on and off independently — see Setting.swift for why
// that matters.

import Foundation
import HIDPP

// MARK: - Wheel ratchet

/// What the scroll wheel should do.
public enum WheelRatchetMode: String, Codable, Equatable, CaseIterable, Sendable {
    /// Always clicks through detents, never releases into free spin no matter
    /// how fast it is flicked. This is the setting Logitech's own software does
    /// not offer.
    case alwaysRatchet
    /// Clicks through detents, but releases into free spin above `threshold`.
    /// This is Logitech's factory "SmartShift" behaviour.
    case smartShift
    /// Always spins freely.
    case freeSpin

    public var displayName: String {
        switch self {
        case .alwaysRatchet: return "Always ratchet"
        case .smartShift: return "SmartShift (automatic)"
        case .freeSpin: return "Always free spin"
        }
    }
}

public struct WheelRatchetSetting: Codable, Equatable, Sendable {
    public var mode: WheelRatchetMode
    /// Speed, in quarter-turns per second, at which SmartShift releases the
    /// ratchet. Only meaningful in `.smartShift` mode.
    public var threshold: Int
    /// Ratchet resistance, 1…100 % of the motor's maximum force. Only some
    /// devices have a tunable-torque wheel; `nil` leaves it alone.
    public var torque: Int?

    public init(mode: WheelRatchetMode = .alwaysRatchet, threshold: Int = 16, torque: Int? = nil) {
        self.mode = mode
        self.threshold = threshold
        self.torque = torque
    }

    /// Lowest threshold worth offering. Below roughly two turns per second the
    /// wheel releases during ordinary scrolling and feels broken.
    public static let minimumThreshold = 8
    public static let maximumThreshold = 50

    public var hidppMode: HIDPPWheelRatchetMode {
        mode == .freeSpin ? .freespin : .ratchet
    }

    public var hidppAutoDisengage: UInt8 {
        switch mode {
        case .alwaysRatchet:
            return HIDPPSmartShift.permanentRatchet
        case .freeSpin:
            // Irrelevant in free spin, but a valid byte must be sent.
            return HIDPPSmartShift.permanentRatchet
        case .smartShift:
            return UInt8(clamping: max(threshold, Self.minimumThreshold))
        }
    }
}

// MARK: - Hardware settings (written to the device over HID++)

public struct DPIPresets: Codable, Equatable, Sendable {
    public var values: [Int]
    /// Which preset is currently selected. Persisted so cycling survives a
    /// restart.
    public var activeIndex: Int

    public init(values: [Int] = [1000, 1600], activeIndex: Int = 0) {
        self.values = values
        self.activeIndex = activeIndex
    }

    public var active: Int? {
        guard !values.isEmpty else { return nil }
        return values[min(max(activeIndex, 0), values.count - 1)]
    }

    public func next() -> DPIPresets {
        guard !values.isEmpty else { return self }
        return DPIPresets(values: values, activeIndex: (activeIndex + 1) % values.count)
    }
}

/// Settings that live in the mouse's own memory.
///
/// These are volatile: the device forgets them when it powers down, which is
/// exactly why `HardwareReconciler` exists.
public struct HardwareSettings: Codable, Equatable, Sendable {
    /// Ratchet / free-spin behaviour (HID++ 0x2110 / 0x2111).
    public var wheelRatchet: Setting<WheelRatchetSetting>
    /// Whether the wheel reports many increments per detent (HID++ 0x2121).
    ///
    /// Off by default and, when managed, normally set to `false`: the
    /// high-resolution stream is what makes scrolling feel uncontrollable in
    /// photo galleries and other wheel-driven UIs.
    public var highResolutionWheel: Setting<Bool>
    /// Invert scroll direction in the device firmware rather than in software.
    public var invertScrollInFirmware: Setting<Bool>
    /// Sensor resolution (HID++ 0x2201).
    public var dpi: Setting<Int>
    /// Presets for the cycle action.
    public var dpiPresets: Setting<DPIPresets>
    /// Report interval in milliseconds (HID++ 0x8060); 1 means 1000 Hz.
    public var reportRate: Setting<Int>

    public init(
        wheelRatchet: Setting<WheelRatchetSetting> = .off(WheelRatchetSetting()),
        highResolutionWheel: Setting<Bool> = .off(false),
        invertScrollInFirmware: Setting<Bool> = .off(false),
        dpi: Setting<Int> = .off(1000),
        dpiPresets: Setting<DPIPresets> = .off(DPIPresets()),
        reportRate: Setting<Int> = .off(1)
    ) {
        self.wheelRatchet = wheelRatchet
        self.highResolutionWheel = highResolutionWheel
        self.invertScrollInFirmware = invertScrollInFirmware
        self.dpi = dpi
        self.dpiPresets = dpiPresets
        self.reportRate = reportRate
    }

    /// Whether anything here is managed at all. When nothing is, LoLiMouse
    /// never opens a HID++ conversation with the device.
    public var managesAnything: Bool {
        wheelRatchet.enabled || highResolutionWheel.enabled || invertScrollInFirmware.enabled
            || dpi.enabled || dpiPresets.enabled || reportRate.enabled
    }
}

// MARK: - Pointer settings (written to macOS, per device)

public struct PointerSettings: Codable, Equatable, Sendable {
    /// Tracking speed, 0…1, mapped onto the pointer resolution macOS uses.
    public var speed: Setting<Double>
    /// Acceleration curve strength, 0…40 in macOS's units.
    public var acceleration: Setting<Double>
    /// Turn the acceleration curve off entirely, giving one-to-one tracking.
    public var disableAcceleration: Setting<Bool>

    public init(
        speed: Setting<Double> = .off(0.5),
        acceleration: Setting<Double> = .off(1.0),
        disableAcceleration: Setting<Bool> = .off(false)
    ) {
        self.speed = speed
        self.acceleration = acceleration
        self.disableAcceleration = disableAcceleration
    }

    public var managesAnything: Bool {
        speed.enabled || acceleration.enabled || disableAcceleration.enabled
    }
}

// MARK: - Scrolling (applied in the event pipeline)

/// How far one wheel step should scroll.
public enum ScrollDistance: Codable, Equatable, Sendable {
    /// Whatever the system would do.
    case system
    /// A fixed number of lines per detent.
    case lines(Int)
    /// A fixed number of pixels per detent.
    case pixels(Int)

    public var displayName: String {
        switch self {
        case .system: return "System default"
        case let .lines(count): return "\(count) lines"
        case let .pixels(count): return "\(count) pixels"
        }
    }
}

public struct AxisScrolling: Codable, Equatable, Sendable {
    /// Fixed step size. Switching this on is what makes scrolling linear:
    /// every detent moves exactly the same distance.
    public var distance: Setting<ScrollDistance>
    /// Exponent applied to scroll speed. 1 is linear; above 1 accelerates fast
    /// flicks. Only meaningful when `distance` is not managed, since a fixed
    /// step size is by definition unaccelerated.
    public var acceleration: Setting<Double>
    /// Flat multiplier applied after acceleration.
    public var speed: Setting<Double>
    /// Reverse this axis.
    public var reverse: Setting<Bool>

    public init(
        distance: Setting<ScrollDistance> = .off(.lines(3)),
        acceleration: Setting<Double> = .off(1.0),
        speed: Setting<Double> = .off(1.0),
        reverse: Setting<Bool> = .off(false)
    ) {
        self.distance = distance
        self.acceleration = acceleration
        self.speed = speed
        self.reverse = reverse
    }

    public var managesAnything: Bool {
        distance.enabled || acceleration.enabled || speed.enabled || reverse.enabled
    }
}

/// A modifier key that can change what the scroll wheel does while held.
public enum ModifierKey: String, Codable, Equatable, CaseIterable, Sendable {
    case command, shift, option, control

    public var displayName: String {
        switch self {
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        }
    }
}

/// What scrolling does while a modifier key is held.
///
/// One map covers both axes: a modifier changes what *the wheel* does, and
/// splitting that decision per axis doubles the UI for a distinction nobody
/// asked for. (LinearMouse configures the two axes separately; if that ever
/// turns out to matter, the map moves into `AxisScrolling`.)
public enum ModifierKeyAction: Codable, Hashable, Sendable {
    /// Strip the modifier so applications see a plain scroll — the wheel keeps
    /// scrolling instead of triggering the app's own modifier behaviour.
    case ignore
    /// Swallow the event entirely.
    case preventDefault
    /// Swap the vertical and horizontal axes.
    case alterOrientation
    /// Multiply the scroll distance.
    case changeSpeed(Double)
    /// Send the application's zoom shortcut (⌘= / ⌘−) per wheel click.
    case zoom
    case zoomReversed
    /// Synthesise a trackpad pinch, for the smooth zoom apps reserve for it.
    case pinchZoom
    case pinchZoomReversed

    public var displayName: String {
        switch self {
        case .ignore: return "Scroll (ignore the modifier)"
        case .preventDefault: return "Do nothing"
        case .alterOrientation: return "Swap axes"
        case .changeSpeed: return "Change speed"
        case .zoom: return "Zoom (⌘= / ⌘−)"
        case .zoomReversed: return "Zoom, reversed"
        case .pinchZoom: return "Pinch zoom (smooth)"
        case .pinchZoomReversed: return "Pinch zoom, reversed"
        }
    }

    // `changeSpeed` carries a payload, so the compiler-written conformance
    // would encode it as a nested container; a flat `type` + `scale` object
    // keeps the config file hand-editable.
    private enum CodingKeys: String, CodingKey { case type, scale }

    private enum Kind: String, Codable {
        case ignore, preventDefault, alterOrientation, changeSpeed
        case zoom, zoomReversed, pinchZoom, pinchZoomReversed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .ignore: self = .ignore
        case .preventDefault: self = .preventDefault
        case .alterOrientation: self = .alterOrientation
        case .changeSpeed:
            self = .changeSpeed(try container.decodeIfPresent(Double.self, forKey: .scale) ?? 2)
        case .zoom: self = .zoom
        case .zoomReversed: self = .zoomReversed
        case .pinchZoom: self = .pinchZoom
        case .pinchZoomReversed: self = .pinchZoomReversed
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ignore: try container.encode(Kind.ignore, forKey: .type)
        case .preventDefault: try container.encode(Kind.preventDefault, forKey: .type)
        case .alterOrientation: try container.encode(Kind.alterOrientation, forKey: .type)
        case let .changeSpeed(scale):
            try container.encode(Kind.changeSpeed, forKey: .type)
            try container.encode(scale, forKey: .scale)
        case .zoom: try container.encode(Kind.zoom, forKey: .type)
        case .zoomReversed: try container.encode(Kind.zoomReversed, forKey: .type)
        case .pinchZoom: try container.encode(Kind.pinchZoom, forKey: .type)
        case .pinchZoomReversed: try container.encode(Kind.pinchZoomReversed, forKey: .type)
        }
    }
}

public struct ScrollingSettings: Codable, Equatable, Sendable {
    public var vertical: AxisScrolling
    public var horizontal: AxisScrolling

    /// What the wheel does while a modifier key is held. A modifier that is
    /// absent from the map behaves normally — the event passes through with
    /// its flag intact.
    public var modifiers: Setting<[ModifierKey: ModifierKeyAction]>

    /// Collapse the device's high-resolution wheel stream back into whole
    /// detents.
    ///
    /// This is the fix for galleries and carousels that jump several items per
    /// click: the mouse sends eight or more events per detent, and this folds
    /// them back into one. Independent of the firmware `highResolutionWheel`
    /// switch, because Logitech's own software may have turned that on behind
    /// our back.
    public var normalizeHighResolutionWheel: Setting<Bool>

    public init(
        vertical: AxisScrolling = AxisScrolling(),
        horizontal: AxisScrolling = AxisScrolling(),
        normalizeHighResolutionWheel: Setting<Bool> = .off(true),
        modifiers: Setting<[ModifierKey: ModifierKeyAction]> = .off([.command: .zoom])
    ) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.normalizeHighResolutionWheel = normalizeHighResolutionWheel
        self.modifiers = modifiers
    }

    public var managesAnything: Bool {
        vertical.managesAnything || horizontal.managesAnything
            || normalizeHighResolutionWheel.enabled || modifiers.enabled
    }

    /// Whether any modifier is bound to a pinch action, which is the one case
    /// where the event tap also has to watch `flagsChanged` — releasing the
    /// modifier is what ends the synthesised gesture.
    public var wantsFlagsChanged: Bool {
        guard let actions = modifiers.effective else { return false }
        return actions.values.contains { $0 == .pinchZoom || $0 == .pinchZoomReversed }
    }
}

// MARK: - Buttons

/// A remap of an ordinary mouse button that macOS already sees.
public struct ButtonMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// CoreGraphics button number, 0-based.
    public var button: Int
    /// Modifier keys that must be held for this mapping to fire, so the same
    /// button can do different things plain and with ⌘. Empty means "any".
    public var modifiers: Set<ModifierKey>
    public var action: Action

    public init(id: UUID = UUID(), button: Int, modifiers: Set<ModifierKey> = [], action: Action) {
        self.id = id
        self.button = button
        self.modifiers = modifiers
        self.action = action
    }

    // Config files written before modifiers existed have no `modifiers` key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        button = try container.decode(Int.self, forKey: .button)
        modifiers = try container.decodeIfPresent(Set<ModifierKey>.self, forKey: .modifiers) ?? []
        action = try container.decode(Action.self, forKey: .action)
    }

    /// The mapping that should fire for `button` with `held` modifiers down:
    /// the most specific one whose required modifiers are all held. A mapping
    /// with no modifiers is the fallback and matches anything.
    public static func bestMatch(
        in mappings: [ButtonMapping],
        button: Int,
        held: Set<ModifierKey>
    ) -> ButtonMapping? {
        mappings
            .filter { $0.button == button && $0.modifiers.isSubset(of: held) }
            .max { $0.modifiers.count < $1.modifiers.count }
    }
}

/// Which way the mouse was flicked while a gesture button was held.
public enum GestureDirection: String, Codable, Equatable, CaseIterable, Sendable {
    case up, down, left, right

    public var displayName: String {
        switch self {
        case .up: return "Flick up"
        case .down: return "Flick down"
        case .left: return "Flick left"
        case .right: return "Flick right"
        }
    }
}

/// The thumb button, and what it does when held and flicked.
public struct GestureButtonSettings: Codable, Equatable, Sendable {
    /// What a plain press does, with no movement.
    public var tap: Setting<Action>
    /// What flicking in each direction does. Switch this off to keep the button
    /// working as a plain button with no gesture behaviour at all.
    public var gestures: Setting<[GestureDirection: Action]>
    /// How far the mouse must move, in device units, before a flick counts.
    public var threshold: Double

    public init(
        tap: Setting<Action> = .off(.missionControl),
        gestures: Setting<[GestureDirection: Action]> = .off([
            .up: .missionControl,
            .down: .showDesktop,
            .left: .spaceLeft,
            .right: .spaceRight,
        ]),
        threshold: Double = 60
    ) {
        self.tap = tap
        self.gestures = gestures
        self.threshold = threshold
    }

    public var managesAnything: Bool { tap.enabled || gestures.enabled }
}

public struct ButtonSettings: Codable, Equatable, Sendable {
    /// Remaps for buttons that arrive as ordinary macOS mouse events.
    public var mappings: Setting<[ButtonMapping]>
    /// The small button below the scroll wheel (HID++ control 0x00C4).
    /// Diverted only when managed, so its factory behaviour survives otherwise.
    public var wheelModeButton: Setting<Action>
    /// The thumb button (HID++ control 0x00C3 and friends).
    public var thumbButton: GestureButtonSettings

    public init(
        mappings: Setting<[ButtonMapping]> = .off([]),
        wheelModeButton: Setting<Action> = .off(.cycleDPIPresets),
        thumbButton: GestureButtonSettings = GestureButtonSettings()
    ) {
        self.mappings = mappings
        self.wheelModeButton = wheelModeButton
        self.thumbButton = thumbButton
    }

    /// Which HID++ controls need diverting for the current configuration.
    /// Anything not listed here keeps behaving exactly as the factory intended.
    public var divertedControls: Set<HIDPPControlID> {
        var controls: Set<HIDPPControlID> = []
        if wheelModeButton.enabled {
            controls.insert(HIDPPControl.wheelModeButton)
        }
        if thumbButton.managesAnything {
            controls.formUnion(HIDPPControl.gestureCapable)
        }
        return controls
    }

    public var managesAnything: Bool {
        mappings.enabled || wheelModeButton.enabled || thumbButton.managesAnything
    }
}

// MARK: - Per-device configuration

public struct DeviceConfiguration: Codable, Equatable, Sendable {
    /// Last known display name, kept so the UI can list a device that is
    /// currently unplugged.
    public var displayName: String?
    public var hardware: HardwareSettings
    public var pointer: PointerSettings
    public var scrolling: ScrollingSettings
    public var buttons: ButtonSettings

    public init(
        displayName: String? = nil,
        hardware: HardwareSettings = HardwareSettings(),
        pointer: PointerSettings = PointerSettings(),
        scrolling: ScrollingSettings = ScrollingSettings(),
        buttons: ButtonSettings = ButtonSettings()
    ) {
        self.displayName = displayName
        self.hardware = hardware
        self.pointer = pointer
        self.scrolling = scrolling
        self.buttons = buttons
    }

    public var managesAnything: Bool {
        hardware.managesAnything || pointer.managesAnything
            || scrolling.managesAnything || buttons.managesAnything
    }
}

// MARK: - Root

public struct Configuration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Keyed by `HIDPPDeviceDescriptor.stableKey`, which follows the physical
    /// device rather than how it happens to be connected today.
    public var devices: [String: DeviceConfiguration]
    /// Master switch. Turning it off stops the event tap and restores every
    /// hardware setting LoLiMouse changed, without losing the configuration.
    public var enabled: Bool

    public init(
        schemaVersion: Int = Configuration.currentSchemaVersion,
        devices: [String: DeviceConfiguration] = [:],
        enabled: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.devices = devices
        self.enabled = enabled
    }

    public func device(_ key: String) -> DeviceConfiguration {
        devices[key] ?? DeviceConfiguration()
    }

    public mutating func update(_ key: String, _ transform: (inout DeviceConfiguration) -> Void) {
        var configuration = devices[key] ?? DeviceConfiguration()
        transform(&configuration)
        devices[key] = configuration
    }
}

// `[GestureDirection: Action]` needs a keyed representation that survives JSON.
extension GestureDirection: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringCodingKey(rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

// Same for `[ModifierKey: ModifierKeyAction]`.
extension ModifierKey: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringCodingKey(rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }
}

struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}
