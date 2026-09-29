// MIT License
// Copyright (c) 2026 LoLiMouse contributors
//
// Per-application profiles: a device's settings, changed for the one
// application whose window is under the pointer.
//
// A profile is an overlay, not a copy. It lists only the settings the user
// chose to make different in that application, and each one it lists replaces
// the device's setting whole — switch included. That is what lets a profile
// turn a setting *off*: IINA reads macOS's "natural scrolling" flag and undoes
// it itself, so a reverse that is right everywhere else is wrong there twice.

import Foundation

/// A setting an application profile may change.
///
/// Only settings that act on events as they happen are offered. Anything
/// written into the mouse or into macOS — DPI, the ratchet, pointer speed —
/// would have to be rewritten every time the pointer crossed into another
/// window, which is slow over Bluetooth and pointless besides.
///
/// The raw value is the key in `config.json` and mirrors the setting's path in
/// `DeviceConfiguration`, so a hand-edited file reads the way the model does.
public enum OverridableSetting: String, CaseIterable, Codable, Hashable, Sendable {
    case normalizeHighResolutionWheel = "scrolling.normalizeHighResolutionWheel"
    case scrollModifiers = "scrolling.modifiers"
    case verticalReverse = "scrolling.vertical.reverse"
    case verticalDistance = "scrolling.vertical.distance"
    case verticalAcceleration = "scrolling.vertical.acceleration"
    case verticalSpeed = "scrolling.vertical.speed"
    case horizontalReverse = "scrolling.horizontal.reverse"
    case horizontalDistance = "scrolling.horizontal.distance"
    case horizontalAcceleration = "scrolling.horizontal.acceleration"
    case horizontalSpeed = "scrolling.horizontal.speed"
    case buttonMappings = "buttons.mappings"
    case wheelModeButton = "buttons.wheelModeButton"
    case thumbButtonTap = "buttons.thumbButton.tap"
    case thumbButtonGestures = "buttons.thumbButton.gestures"
    case threeFingerTap = "trackpad.threeFingerTap"
    case fourFingerTap = "trackpad.fourFingerTap"

    /// The setting a key path into `DeviceConfiguration` points at, if a
    /// profile may change it. Key paths compare by their components, so a path
    /// built with `appending(path:)` finds the same entry as a literal one.
    public init?(path: AnyKeyPath) {
        guard let setting = Self.byPath[path] else { return nil }
        self = setting
    }

    /// Whether a profile may change this setting on a device configured as
    /// `base`.
    ///
    /// Diverting the wheel-mode and thumb buttons is a property of the mouse,
    /// not of a window, so it follows the settings for all applications. A
    /// profile may change what such a button does, but cannot take over a
    /// button that is otherwise left to the firmware — the button would stop
    /// doing its factory job everywhere else.
    public func isAllowed(over base: DeviceConfiguration) -> Bool {
        switch self {
        case .wheelModeButton:
            return base.buttons.wheelModeButton.enabled
        case .thumbButtonTap, .thumbButtonGestures:
            return base.buttons.thumbButton.managesAnything
        default:
            return true
        }
    }

    var accessor: Accessor {
        switch self {
        case .normalizeHighResolutionWheel: return Accessor(\.scrolling.normalizeHighResolutionWheel)
        case .scrollModifiers: return Accessor(\.scrolling.modifiers)
        case .verticalReverse: return Accessor(\.scrolling.vertical.reverse)
        case .verticalDistance: return Accessor(\.scrolling.vertical.distance)
        case .verticalAcceleration: return Accessor(\.scrolling.vertical.acceleration)
        case .verticalSpeed: return Accessor(\.scrolling.vertical.speed)
        case .horizontalReverse: return Accessor(\.scrolling.horizontal.reverse)
        case .horizontalDistance: return Accessor(\.scrolling.horizontal.distance)
        case .horizontalAcceleration: return Accessor(\.scrolling.horizontal.acceleration)
        case .horizontalSpeed: return Accessor(\.scrolling.horizontal.speed)
        case .buttonMappings: return Accessor(\.buttons.mappings)
        case .wheelModeButton: return Accessor(\.buttons.wheelModeButton)
        case .thumbButtonTap: return Accessor(\.buttons.thumbButton.tap)
        case .thumbButtonGestures: return Accessor(\.buttons.thumbButton.gestures)
        case .threeFingerTap: return Accessor(\.trackpad.threeFingerTap)
        case .fourFingerTap: return Accessor(\.trackpad.fourFingerTap)
        }
    }

    private static let byPath: [AnyKeyPath: OverridableSetting] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.accessor.path, $0) }
    )

    /// Type-erased access to one `Setting` inside a `DeviceConfiguration`, so
    /// the list above can drive merging, diffing and coding without a switch
    /// in each of them.
    struct Accessor {
        let path: AnyKeyPath
        let copy: (DeviceConfiguration, inout DeviceConfiguration) -> Void
        let equal: (DeviceConfiguration, DeviceConfiguration) -> Bool
        let encode: (DeviceConfiguration, inout KeyedEncodingContainer<StringCodingKey>, StringCodingKey) throws -> Void
        /// Returns whether the key was present.
        let decode: (KeyedDecodingContainer<StringCodingKey>, StringCodingKey, inout DeviceConfiguration) throws -> Bool

        init<Value: Codable & Equatable>(_ path: WritableKeyPath<DeviceConfiguration, Setting<Value>>) {
            self.path = path
            copy = { source, target in target[keyPath: path] = source[keyPath: path] }
            equal = { $0[keyPath: path] == $1[keyPath: path] }
            encode = { configuration, container, key in
                try container.encode(configuration[keyPath: path], forKey: key)
            }
            decode = { container, key, configuration in
                guard let setting = try container.decodeIfPresent(Setting<Value>.self, forKey: key) else {
                    return false
                }
                configuration[keyPath: path] = setting
                return true
            }
        }
    }
}

/// What one application changes about one device.
public struct AppProfile: Codable, Equatable, Sendable {
    /// The application's name, kept for the UI so a profile for an app that
    /// has since been deleted still has a label.
    public var name: String
    /// Switches the whole profile off without losing it.
    public var enabled: Bool
    /// The settings this profile changes.
    public private(set) var overridden: Set<OverridableSetting>
    /// Where the overridden settings' values live. Only the entries named in
    /// `overridden` mean anything; the rest stay at their defaults.
    public private(set) var values: DeviceConfiguration

    public init(name: String, enabled: Bool = true) {
        self.name = name
        self.enabled = enabled
        overridden = []
        values = DeviceConfiguration()
    }

    public func overrides(_ setting: OverridableSetting) -> Bool {
        overridden.contains(setting)
    }

    /// Makes `setting` different in this application, starting from the value
    /// it has in `configuration` — normally the settings for all applications,
    /// so ticking the box changes nothing until the user edits something.
    public mutating func override(_ setting: OverridableSetting, from configuration: DeviceConfiguration) {
        setting.accessor.copy(configuration, &values)
        overridden.insert(setting)
    }

    /// Lets `setting` follow the settings for all applications again.
    public mutating func inherit(_ setting: OverridableSetting) {
        setting.accessor.copy(DeviceConfiguration(), &values)
        overridden.remove(setting)
    }

    /// Turns an edit made to this application's view of a device into
    /// overrides: every setting that differs between `old` and `new` becomes
    /// one. This is what lets the settings UI edit a profile through the very
    /// same key paths it uses for the device itself.
    public mutating func record(from old: DeviceConfiguration, to new: DeviceConfiguration, base: DeviceConfiguration) {
        for setting in OverridableSetting.allCases
            where setting.isAllowed(over: base) && !setting.accessor.equal(old, new)
        {
            override(setting, from: new)
        }
    }

    // The overridden settings are written as a flat map keyed by path, so the
    // file names exactly what the profile changes and nothing else:
    //
    //     "com.colliderli.iina": {
    //       "name": "IINA", "enabled": true,
    //       "settings": { "scrolling.vertical.reverse": { "enabled": false, "value": true } }
    //     }
    private enum CodingKeys: String, CodingKey {
        case name, enabled, settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        overridden = []
        values = DeviceConfiguration()
        guard container.contains(.settings) else { return }
        // Keys this version does not know — written by a newer one — are
        // skipped rather than failing the whole file.
        let settings = try container.nestedContainer(keyedBy: StringCodingKey.self, forKey: .settings)
        for setting in OverridableSetting.allCases {
            if try setting.accessor.decode(settings, StringCodingKey(setting.rawValue), &values) {
                overridden.insert(setting)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        var settings = container.nestedContainer(keyedBy: StringCodingKey.self, forKey: .settings)
        for setting in OverridableSetting.allCases where overridden.contains(setting) {
            try setting.accessor.encode(values, &settings, StringCodingKey(setting.rawValue))
        }
    }

    // Values of settings that are not overridden are not part of the profile.
    public static func == (lhs: AppProfile, rhs: AppProfile) -> Bool {
        lhs.name == rhs.name && lhs.enabled == rhs.enabled && lhs.overridden == rhs.overridden
            && lhs.overridden.allSatisfy { $0.accessor.equal(lhs.values, rhs.values) }
    }
}

public extension DeviceConfiguration {
    /// This device's settings as they apply inside the application `profile`
    /// belongs to. The result carries no profiles of its own.
    ///
    /// Ignores `profile.enabled`, so the settings window can show a profile
    /// that is switched off; the event pipeline asks
    /// `applicationConfigurations` instead, which leaves those out.
    func applying(_ profile: AppProfile) -> DeviceConfiguration {
        var result = self
        result.apps = [:]
        for setting in profile.overridden where setting.isAllowed(over: self) {
            setting.accessor.copy(profile.values, &result)
        }
        return result
    }

    /// The effective settings for each application with a profile that is
    /// switched on and changes something, keyed by bundle identifier.
    var applicationConfigurations: [String: DeviceConfiguration] {
        var result: [String: DeviceConfiguration] = [:]
        for (bundleIdentifier, profile) in apps where profile.enabled && !profile.overridden.isEmpty {
            result[bundleIdentifier] = applying(profile)
        }
        return result
    }

    /// Applies an edit to what the device looks like inside one application,
    /// recording whatever changed as overrides in that application's profile.
    /// Does nothing when there is no such profile.
    mutating func editProfile(_ bundleIdentifier: String, _ transform: (inout DeviceConfiguration) -> Void) {
        guard var profile = apps[bundleIdentifier] else { return }
        let before = applying(profile)
        var after = before
        transform(&after)
        profile.record(from: before, to: after, base: self)
        apps[bundleIdentifier] = profile
    }
}
