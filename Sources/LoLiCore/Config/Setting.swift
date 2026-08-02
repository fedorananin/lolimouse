// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Foundation

/// One individually switchable setting.
///
/// This type is the backbone of LoLiMouse's central promise: **nothing is
/// touched unless it is explicitly switched on.** A setting that is off is not
/// "set to the default" — it is not written at all, and if LoLiMouse had
/// previously written it, the original value is restored.
///
/// That distinction is what lets LoLiMouse coexist with other tools, and what
/// makes it safe to use only the one feature you actually want.
public struct Setting<Value: Codable & Equatable>: Codable, Equatable {
    /// Whether LoLiMouse manages this setting at all.
    public var enabled: Bool
    /// The value to apply while `enabled`. Retained while disabled so toggling
    /// the switch back on restores what the user had configured.
    public var value: Value

    public init(enabled: Bool = false, value: Value) {
        self.enabled = enabled
        self.value = value
    }

    /// The value to act on, or `nil` when this setting is not managed.
    public var effective: Value? {
        enabled ? value : nil
    }

    /// A copy with a new value, leaving the switch alone.
    public func with(_ newValue: Value) -> Setting {
        Setting(enabled: enabled, value: newValue)
    }

    /// A copy that is switched on and carries `newValue`.
    public static func on(_ newValue: Value) -> Setting {
        Setting(enabled: true, value: newValue)
    }

    /// A copy that is switched off but remembers `newValue`.
    public static func off(_ newValue: Value) -> Setting {
        Setting(enabled: false, value: newValue)
    }

    // Absent keys decode as "off", so a config file only needs to mention the
    // settings the user actually turned on.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        value = try container.decode(Value.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, value
    }
}

extension Setting: Sendable where Value: Sendable {}
