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
    private let store: ConfigurationStore

    init(device: ManagedDevice, store: ConfigurationStore) {
        self.device = device
        self.store = store
    }

    var configuration: DeviceConfiguration {
        store.configuration.device(device.key)
    }

    /// A binding into this device's configuration.
    func binding<Value>(_ path: WritableKeyPath<DeviceConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { self.configuration[keyPath: path] },
            set: { newValue in
                self.store.updateDevice(self.device.key) { configuration in
                    configuration[keyPath: path] = newValue
                    configuration.displayName = self.device.displayName
                }
            }
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

/// One switchable setting: a toggle that decides whether LoLiMouse manages it,
/// and the controls that configure it — greyed out while the switch is off.
struct ManagedSetting<Content: View>: View {
    let title: String
    var help: String?
    @Binding var isManaged: Bool
    @ViewBuilder var content: Content

    var body: some View {
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

/// A picker over the actions a button or gesture can trigger.
struct ActionPicker: View {
    let label: String
    @Binding var action: Action

    var body: some View {
        Picker(label, selection: $action) {
            ForEach(Action.simpleChoices, id: \.self) { choice in
                Text(choice.displayName).tag(choice)
            }
            // Keep a configured shortcut selectable even though it is not one
            // of the fixed choices.
            if case .keyPress = action {
                Text(action.displayName).tag(action)
            }
            if case .mouseButton = action {
                Text(action.displayName).tag(action)
            }
        }
        .pickerStyle(.menu)
    }
}
