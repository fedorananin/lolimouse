// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import LoLiCore
import SwiftUI
import UniformTypeIdentifiers

/// Copies another device's settings onto this one, or moves them through a
/// file. The rules for what a copy replaces live in SettingsTransfer.swift.
struct SettingsTransferMenu: View {
    @ObservedObject var device: ManagedDevice
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var registry: DeviceRegistry

    /// Settings waiting for the user to confirm they may replace this
    /// device's own.
    @State private var pending: PendingReplacement?
    @State private var failure: String?

    private struct PendingReplacement {
        let sourceName: String
        let settings: DeviceConfiguration
    }

    var body: some View {
        Menu {
            let sources = self.sources
            Section("Copy From") {
                if sources.isEmpty {
                    Text("No other device has settings yet")
                } else {
                    ForEach(sources, id: \.key) { source in
                        Button(source.name) { copy(from: source) }
                    }
                }
            }
            Divider()
            Button("Export to File…", action: export)
                .disabled(!store.configuration.device(device.key).hasAnythingToLose)
            Button("Import from File…", action: importFile)
        } label: {
            Label("Transfer Settings", systemImage: "arrow.left.arrow.right")
        }
        .fixedSize()
        .help("Copy settings from another device, or move them through a file")
        .alert(
            pending.map { "Replace the settings of \(device.displayName) with those of \($0.sourceName)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { replacement in
            Button("Replace") { apply(replacement) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Every setting and application profile of \(device.displayName) is replaced. Anything switched on now and not in the copied settings is switched off, and the original value is put back.")
        }
        .alert(
            "Settings could not be transferred",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    /// A trackpad's settings are gestures a mouse cannot make, and the other
    /// way round; while both devices are connected, offer only their own kind.
    /// A device that is not connected is offered regardless — the mouse being
    /// replaced is usually that one.
    private var sources: [SettingsSource] {
        store.configuration.settingsSources(for: device.key).filter { source in
            guard let other = registry.device(key: source.key) else { return true }
            return other.isTrackpad == device.isTrackpad
        }
    }

    private func copy(from source: SettingsSource) {
        guard let settings = store.configuration.devices[source.key] else { return }
        propose(PendingReplacement(sourceName: source.name, settings: settings))
    }

    /// Replaces straight away when there is nothing here to lose; asks first
    /// otherwise.
    private func propose(_ replacement: PendingReplacement) {
        if store.configuration.device(device.key).hasAnythingToLose {
            pending = replacement
        } else {
            apply(replacement)
        }
    }

    private func apply(_ replacement: PendingReplacement) {
        store.update { $0.replaceSettings(of: device.key, with: replacement.settings, name: device.displayName) }
    }

    // MARK: - Files

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = DeviceSettingsFile.suggestedFileName(for: device.displayName)
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let file = DeviceSettingsFile(
            deviceName: device.displayName,
            settings: store.configuration.device(device.key)
        )
        do {
            try file.encoded().write(to: url, options: .atomic)
        } catch {
            failure = "The file could not be saved: \(error.localizedDescription)"
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let file = try DeviceSettingsFile.decode(Data(contentsOf: url))
            let name = file.deviceName.map { "\($0) (\(url.lastPathComponent))" } ?? url.lastPathComponent
            propose(PendingReplacement(sourceName: name, settings: file.settings))
        } catch let error as DeviceSettingsFile.ReadError {
            failure = error.description
        } catch {
            failure = "The file could not be opened: \(error.localizedDescription)"
        }
    }
}
