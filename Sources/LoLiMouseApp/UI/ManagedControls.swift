// MIT License
// Copyright (c) 2026 LoLiMouse contributors

import LoLiCore
import SwiftUI

/// Editing surface for one device's configuration.
///
/// Every control in the app goes through this, which is what keeps the promise
/// that a setting is only ever written when its own switch is on.
@MainActor
final class DeviceSettingsModel: ObservableObject {
    let device: ManagedDevice
    /// The bundle identifier of the application profile being edited, or
    /// `nil` for the settings that apply everywhere.
    let application: String?
    private let store: ConfigurationStore

    init(device: ManagedDevice, store: ConfigurationStore, application: String? = nil) {
        self.device = device
        self.store = store
        self.application = application
    }

    /// The settings for all applications, whatever is being edited.
    var baseConfiguration: DeviceConfiguration {
        store.configuration.device(device.key)
    }

    /// The settings as they apply where this model is looking: everywhere, or
    /// inside one application.
    var configuration: DeviceConfiguration {
        let base = baseConfiguration
        guard let application, let profile = base.apps[application] else { return base }
        return base.applying(profile)
    }

    var profile: AppProfile? {
        application.flatMap { baseConfiguration.apps[$0] }
    }

    var isEditingProfile: Bool { application != nil }

    /// A binding into this device's configuration. While a profile is being
    /// edited, whatever a write changes becomes an override in that profile.
    func binding<Value>(_ path: WritableKeyPath<DeviceConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { self.configuration[keyPath: path] },
            set: { newValue in
                self.store.updateDevice(self.device.key) { configuration in
                    configuration.displayName = self.device.displayName
                    if let application = self.application {
                        configuration.editProfile(application) { $0[keyPath: path] = newValue }
                    } else {
                        configuration[keyPath: path] = newValue
                    }
                }
            }
        )
    }

    /// Whether a setting differs in the application being edited, or `nil`
    /// when no profile is being edited or the setting cannot differ per
    /// application.
    func override<Value>(_ path: WritableKeyPath<DeviceConfiguration, Setting<Value>>) -> ApplicationOverride? {
        guard let application, let profile, let setting = OverridableSetting(path: path) else { return nil }
        return ApplicationOverride(
            applicationName: profile.name,
            isAllowed: setting.isAllowed(over: baseConfiguration),
            isOverridden: Binding(
                get: { self.profile?.overrides(setting) == true },
                set: { newValue in
                    self.store.updateDevice(self.device.key) { configuration in
                        let base = configuration
                        if newValue {
                            configuration.apps[application]?.override(setting, from: base)
                        } else {
                            configuration.apps[application]?.inherit(setting)
                        }
                    }
                }
            )
        )
    }

    /// A binding to whether a setting is managed at all.
    func enabled<Value>(_ path: WritableKeyPath<DeviceConfiguration, Setting<Value>>) -> Binding<Bool> {
        binding(path.appending(path: \.enabled))
    }

    /// A binding to a setting's value.
    func value<Value>(_ path: WritableKeyPath<DeviceConfiguration, Setting<Value>>) -> Binding<Value> {
        binding(path.appending(path: \.value))
    }

    func isEnabled<Value>(_ path: WritableKeyPath<DeviceConfiguration, Setting<Value>>) -> Bool {
        configuration[keyPath: path].enabled
    }

    /// Whether the device's firmware implements a capability. Unknown means
    /// "show everything": a capability probe that failed because the device was
    /// asleep must not hide settings the mouse actually has.
    func supports(_ capability: KeyPath<DeviceCapabilities, Bool>) -> Bool {
        guard let capabilities = device.capabilities else { return true }
        return capabilities[keyPath: capability]
    }
}

/// A titled group of related settings.
struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Whether one setting differs inside the application profile being edited.
struct ApplicationOverride {
    let applicationName: String
    /// False for a diverted button that is not taken over for all
    /// applications — see `OverridableSetting.isAllowed(over:)`.
    let isAllowed: Bool
    @Binding var isOverridden: Bool
}

/// One switchable setting: a toggle that decides whether LoLiMouse manages it,
/// and the controls that configure it — greyed out while the switch is off.
///
/// With an `override`, it is shown as part of an application profile: a
/// checkbox decides whether the setting differs there, and until it is ticked
/// the setting shows, read-only, what it inherits.
struct ManagedSetting<Content: View>: View {
    let title: String
    var help: String?
    @Binding var isManaged: Bool
    var override: ApplicationOverride?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let override {
                overrideToggle(override)
            }
            setting
                .disabled(isInherited)
                .opacity(isInherited ? 0.55 : 1)
        }
    }

    private var isInherited: Bool {
        guard let override else { return false }
        return !override.isOverridden
    }

    @ViewBuilder
    private func overrideToggle(_ override: ApplicationOverride) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Different in \(override.applicationName)", isOn: override.$isOverridden)
                .toggleStyle(.checkbox)
                .disabled(!override.isAllowed && !override.isOverridden)
            if !override.isAllowed {
                Text("Take this button over under All applications first — whether the mouse "
                    + "hands it to LoLiMouse cannot change from one window to the next.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var setting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isManaged) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let help {
                        Text(help)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)

            content
                .disabled(!isManaged)
                .opacity(isManaged ? 1 : 0.4)
                .padding(.leading, 4)
        }
    }
}

/// A labelled slider with a live numeric readout.
struct LabelledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 110, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(format(value))
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}
