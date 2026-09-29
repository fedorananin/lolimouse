// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import AppKit
import LoLiCore
import SwiftUI
import UniformTypeIdentifiers

/// Picks whose settings the tabs below edit: the device's own, or one
/// application's profile. Also where profiles are added and removed.
struct ApplicationProfilesBar: View {
    @ObservedObject var device: ManagedDevice
    @Binding var selection: String?
    @EnvironmentObject private var store: ConfigurationStore

    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                picker
                addMenu
                if let selection, let profile = profiles[selection] {
                    Toggle("Use this profile", isOn: enabledBinding(selection))
                        .toggleStyle(.checkbox)
                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .confirmationDialog(
                        "Remove the profile for \(profile.name)?",
                        isPresented: $confirmingRemoval
                    ) {
                        Button("Remove", role: .destructive) { remove(selection) }
                    } message: {
                        Text("\(profile.name) will use the settings for all applications again.")
                    }
                }
                Spacer()
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var profiles: [String: AppProfile] {
        store.configuration.device(device.key).apps
    }

    private var sortedProfiles: [(bundleIdentifier: String, profile: AppProfile)] {
        profiles
            .map { (bundleIdentifier: $0.key, profile: $0.value) }
            .sorted { $0.profile.name.localizedStandardCompare($1.profile.name) == .orderedAscending }
    }

    private var caption: String {
        if let selection, let profile = profiles[selection] {
            return "Tick “Different in \(profile.name)” on a setting to change it here; everything "
                + "else follows All applications. Applies while the pointer is over \(profile.name)'s "
                + "windows, even when it is in the background."
        }
        return "Scrolling and buttons can be set differently for a single application. The "
            + "application under the pointer decides — that is where macOS sends the wheel."
    }

    private var picker: some View {
        Picker("Settings for", selection: $selection) {
            Text("All applications").tag(String?.none)
            if !profiles.isEmpty {
                Divider()
                ForEach(sortedProfiles, id: \.bundleIdentifier) { entry in
                    Label {
                        Text(entry.profile.enabled ? entry.profile.name : "\(entry.profile.name) (off)")
                    } icon: {
                        AppIcon(image: Self.icon(forBundleIdentifier: entry.bundleIdentifier))
                    }
                    .tag(Optional(entry.bundleIdentifier))
                }
            }
        }
        .fixedSize()
    }

    private var addMenu: some View {
        Menu {
            let running = runningApplications
            ForEach(running, id: \.bundleIdentifier) { application in
                Button {
                    add(application.bundleIdentifier, name: application.name)
                } label: {
                    Label {
                        Text(application.name)
                    } icon: {
                        AppIcon(image: application.icon)
                    }
                }
            }
            if !running.isEmpty { Divider() }
            Button("Choose Application…", action: chooseApplication)
        } label: {
            Label("Add Application", systemImage: "plus")
        }
        .fixedSize()
    }

    // MARK: - Applications

    private struct RunningApplication {
        let bundleIdentifier: String
        let name: String
        let icon: NSImage?
    }

    /// Applications with a Dock presence that have no profile yet. Background
    /// agents own no windows worth pointing at.
    private var runningApplications: [RunningApplication] {
        let ownIdentifier = Bundle.main.bundleIdentifier
        var seen = Set(profiles.keys)
        var result: [RunningApplication] = []
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            guard let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier != ownIdentifier,
                  seen.insert(bundleIdentifier).inserted
            else { continue }
            result.append(RunningApplication(
                bundleIdentifier: bundleIdentifier,
                name: application.localizedName ?? bundleIdentifier,
                icon: Self.menuSized(application.icon)
            ))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier
        else { return }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        add(bundleIdentifier, name: name)
    }

    private func add(_ bundleIdentifier: String, name: String) {
        if profiles[bundleIdentifier] == nil {
            store.updateDevice(device.key) { configuration in
                configuration.displayName = device.displayName
                configuration.apps[bundleIdentifier] = AppProfile(name: name)
            }
        }
        selection = bundleIdentifier
    }

    private func remove(_ bundleIdentifier: String) {
        selection = nil
        store.updateDevice(device.key) { $0.apps.removeValue(forKey: bundleIdentifier) }
    }

    private func enabledBinding(_ bundleIdentifier: String) -> Binding<Bool> {
        Binding(
            get: { profiles[bundleIdentifier]?.enabled ?? false },
            set: { newValue in
                store.updateDevice(device.key) { $0.apps[bundleIdentifier]?.enabled = newValue }
            }
        )
    }

    // MARK: - Icons

    private static func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return menuSized(NSWorkspace.shared.icon(forFile: url.path))
    }

    /// Menus draw an image at its own size, and application icons come in at
    /// 32 points or more. Copied first: `NSRunningApplication.icon` is shared.
    private static func menuSized(_ image: NSImage?) -> NSImage? {
        guard let copy = image?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

private struct AppIcon: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
        } else {
            Image(systemName: "app")
        }
    }
}
