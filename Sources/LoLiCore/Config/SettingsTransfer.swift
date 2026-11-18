// MIT License
// Copyright (c) 2026 LoLiMouse contributors
//
// Moving one device's settings onto another: copied straight across from a
// device LoLiMouse already knows, or carried in a file between Macs.
//
// Either way the target's settings are *replaced* whole, application profiles
// included. A setting the target had switched on and the source does not is
// therefore switched off, and the reconciler puts the original value back —
// the same path as switching it off by hand, so nothing new can go wrong.
// Settings the target's hardware lacks (a SmartShift wheel, a thumb button)
// are carried along and simply skipped by the reconciler, which already
// treats an unsupported feature as nothing to do.

import Foundation

// MARK: - Copying between devices

/// A device whose settings can be copied onto another.
public struct SettingsSource: Equatable, Sendable {
    public let key: String
    public let name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

extension Configuration {
    /// Devices with something worth copying onto `target`, by name. Read from
    /// the configuration rather than the registry: the mouse being replaced is
    /// usually the one that is no longer plugged in.
    public func settingsSources(for target: String) -> [SettingsSource] {
        let names = devices
            .filter { key, configuration in
                key != target && (configuration.managesAnything || !configuration.apps.isEmpty)
            }
            .map { key, configuration in (key: key, name: configuration.displayName ?? key) }
        var nameCounts: [String: Int] = [:]
        for entry in names { nameCounts[entry.name, default: 0] += 1 }

        return names
            .map { key, name in
                // Two mice of the same model share a name; the unit ID is what
                // tells them apart.
                let shown = nameCounts[name, default: 0] > 1 ? "\(name) (\(Self.shortIdentifier(key)))" : name
                return SettingsSource(key: key, name: shown)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Replaces `target`'s settings with `settings`, keeping the target's own
    /// name.
    public mutating func replaceSettings(of target: String, with settings: DeviceConfiguration, name: String?) {
        var copy = settings
        copy.displayName = name ?? devices[target]?.displayName
        devices[target] = copy
    }

    /// Copies `source`'s settings onto `target`. Does nothing when `source`
    /// has no settings at all.
    public mutating func copySettings(from source: String, to target: String, name: String?) {
        guard source != target, let settings = devices[source] else { return }
        replaceSettings(of: target, with: settings, name: name)
    }

    /// `unit:A91CDB35` → `A91CDB35`; `usb:046D:C52B` → `046D:C52B`.
    static func shortIdentifier(_ key: String) -> String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: colon)...])
    }
}

extension DeviceConfiguration {
    /// Whether replacing these settings would lose anything the user set up.
    public var hasAnythingToLose: Bool {
        managesAnything || !apps.isEmpty || showBatteryInMenuBar
    }
}

// MARK: - Settings files

/// One device's settings as written to a file.
///
/// A bare `DeviceConfiguration` would not do: every one of its fields is
/// optional on the wire, so any JSON object at all — `{}` included — would
/// decode as "a device with nothing switched on" and silently wipe the target.
/// The `format` marker is what tells a settings file from anything else.
public struct DeviceSettingsFile: Codable, Equatable, Sendable {
    public static let formatIdentifier = "me.fedorananin.LoLiMouse.device-settings"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    /// The name of the device the settings were exported from, for display.
    public var deviceName: String?
    public var settings: DeviceConfiguration

    public init(deviceName: String?, settings: DeviceConfiguration) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.deviceName = deviceName
        var settings = settings
        // The name belongs to the device, not to its settings; whichever
        // device imports them keeps its own.
        settings.displayName = nil
        self.settings = settings
    }

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notASettingsFile
        case newerVersion(Int)
        case damaged(String)

        public var description: String {
            switch self {
            case .notASettingsFile:
                return "This is not a LoLiMouse settings file."
            case let .newerVersion(version):
                return "This file was made by a newer version of LoLiMouse (format \(version)). Update LoLiMouse to import it."
            case let .damaged(reason):
                return "The settings file could not be read: \(reason)"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DeviceSettingsFile {
        // The marker is checked on its own first, so that a file that is not
        // ours says so instead of reporting whichever field it lacks.
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
              header.format == formatIdentifier
        else {
            throw ReadError.notASettingsFile
        }
        if let version = header.version, version > currentVersion {
            throw ReadError.newerVersion(version)
        }
        do {
            return try JSONDecoder().decode(DeviceSettingsFile.self, from: data)
        } catch {
            throw ReadError.damaged(String(describing: error))
        }
    }

    /// A file name for these settings, with anything a file system dislikes
    /// replaced.
    public static func suggestedFileName(for deviceName: String) -> String {
        let cleaned = deviceName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Device" : cleaned) — LoLiMouse settings.json"
    }
}
