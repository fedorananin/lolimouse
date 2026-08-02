// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import Combine
import Foundation
import HIDKit
import os.log

/// Loads, publishes and persists the configuration.
///
/// Writes are debounced and atomic: the UI can update a slider on every frame
/// without hammering the disk, and a crash mid-save cannot leave a truncated
/// file behind.
public final class ConfigurationStore: ObservableObject {
    private static let log = LoLiLog.config

    @Published public private(set) var configuration: Configuration

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("config.json") }

    private let saveQueue = DispatchQueue(label: "\(LoLiLog.subsystem).config", qos: .utility)
    private var saveWorkItem: DispatchWorkItem?

    public init(directory: URL? = nil) {
        let resolved = directory ?? ConfigurationStore.defaultDirectory()
        self.directory = resolved
        configuration = ConfigurationStore.load(from: resolved.appendingPathComponent("config.json"))
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LoLiMouse", isDirectory: true)
    }

    private static func load(from url: URL) -> Configuration {
        guard let data = try? Data(contentsOf: url) else {
            return Configuration()
        }
        do {
            var loaded = try JSONDecoder().decode(Configuration.self, from: data)
            loaded.schemaVersion = Configuration.currentSchemaVersion
            return loaded
        } catch {
            os_log("could not read %{public}@ (%{public}@) — starting from defaults",
                   log: log, type: .error, url.path, String(describing: error))
            // Keep the unreadable file around so nothing is silently lost.
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("broken"))
            return Configuration()
        }
    }

    /// Mutates the configuration on the main thread and schedules a save.
    public func update(_ transform: (inout Configuration) -> Void) {
        var next = configuration
        transform(&next)
        guard next != configuration else { return }
        configuration = next
        scheduleSave(next)
    }

    /// Convenience for editing one device's settings.
    public func updateDevice(_ key: String, _ transform: (inout DeviceConfiguration) -> Void) {
        update { $0.update(key, transform) }
    }

    public func replace(with configuration: Configuration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        scheduleSave(configuration)
    }

    private func scheduleSave(_ configuration: Configuration) {
        saveWorkItem?.cancel()
        let directory = self.directory
        let url = fileURL
        let item = DispatchWorkItem {
            ConfigurationStore.write(configuration, to: url, creating: directory)
        }
        saveWorkItem = item
        saveQueue.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Flushes any pending save immediately. Called when the app is quitting.
    public func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let configuration = self.configuration
        let directory = self.directory
        let url = fileURL
        saveQueue.sync {
            ConfigurationStore.write(configuration, to: url, creating: directory)
        }
    }

    private static func write(_ configuration: Configuration, to url: URL, creating directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: .atomic)
        } catch {
            os_log("could not save configuration: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }
}
